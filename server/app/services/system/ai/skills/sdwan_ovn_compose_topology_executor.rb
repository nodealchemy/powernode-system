# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composition skill — bring up an OVN logical-network topology
      # (deployment + logical switches + ports) for a heavyweight-profile
      # account in one shot. Composition shape:
      #
      #   Sdwan::OvnDeployment.find_or_create  →  N × Sdwan::OvnLogicalSwitch.create!
      #     →  M × Sdwan::OvnLogicalSwitchPort.create!
      #     →  Sdwan::OvnCompiler.compile_for_deployment  (structured plan)
      #
      # Idempotent on the deployment level (OvnDeployment is per-account by
      # DB unique index — the executor reuses an existing one) and additive
      # on switches/ports (every call appends new rows; uniqueness within a
      # deployment is enforced at the model layer). New switches and ports
      # are created in `pending` and immediately activated so the compiler
      # emits them in the same call — otherwise the returned plan would be
      # empty even though the rows exist.
      #
      # Phase O6 of the OVS+OVN dual-profile networking roadmap.
      class SdwanOvnComposeTopologyExecutor
        VALID_PORT_KINDS    = ::Sdwan::OvnLogicalSwitchPort::KINDS
        MAX_SWITCHES        = 50
        MAX_PORTS_PER_SWITCH = 250

        def self.descriptor
          {
            name: "sdwan_ovn_compose_topology",
            description: "Compose an OVN logical-network topology (deployment + logical switches + ports) for a heavyweight-profile account, then compile the ovn-nbctl plan. Composes Sdwan::OvnDeployment + Sdwan::OvnLogicalSwitch + Sdwan::OvnLogicalSwitchPort + Sdwan::OvnCompiler.",
            category: "devops",
            inputs: {
              switches: { type: "array", required: true,
                          description: "Array of {name, cidr?, ports: [{name, kind, addresses?, host_node_instance_id?}]} (1-#{MAX_SWITCHES})" },
              nb_db_endpoint: { type: "string", required: false,
                                description: "OVN NB DB endpoint (e.g., tcp:127.0.0.1:6641) — required only when the account has no OvnDeployment yet" },
              sb_db_endpoint: { type: "string", required: false,
                                description: "OVN SB DB endpoint (e.g., tcp:127.0.0.1:6642) — required only when the account has no OvnDeployment yet" },
              northd_host: { type: "string", required: false,
                             description: "Advisory hint for which host runs ovn-northd — only used when creating a new deployment" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — no Sdwan rows are persisted" }
            },
            outputs: {
              dry_run: :boolean,
              switch_count: :integer,
              port_count: :integer,
              planned_actions: [ :object ],
              outputs: {
                ovn_deployment_id: :string,
                created_deployment: :boolean,
                logical_switch_ids: [ :string ],
                logical_switch_port_ids: [ :string ],
                compiled_plan: :object
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_sdwan_ovn_compose_topology,
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(switches:, nb_db_endpoint: nil, sb_db_endpoint: nil, northd_host: nil,
                    dry_run: false, **_extras)
          if (validation_error = validate_inputs(switches: switches))
            return validation_error
          end

          host_ids = collect_host_ids(switches)
          host_lookup = lookup_hosts_or_fail(host_ids)
          return host_lookup if host_lookup.is_a?(Hash) && host_lookup[:success] == false

          existing_deployment = ::Sdwan::OvnDeployment.for_account(@account).first

          if existing_deployment.nil? &&
             (nb_db_endpoint.to_s.strip.empty? || sb_db_endpoint.to_s.strip.empty?)
            return failure("nb_db_endpoint and sb_db_endpoint are required when no OvnDeployment exists for the account yet")
          end

          if dry_run
            return success(
              dry_run: true,
              switch_count: switches.size,
              port_count: switches.sum { |s| Array(s[:ports] || s["ports"]).size },
              planned_actions: build_plan(switches: switches,
                                          creating_deployment: existing_deployment.nil?),
              outputs: {
                ovn_deployment_id: existing_deployment&.id,
                created_deployment: existing_deployment.nil?,
                logical_switch_ids: [],
                logical_switch_port_ids: [],
                compiled_plan: nil
              },
              failures: [],
              partial: false
            )
          end

          run_execute(switches: switches,
                      nb_db_endpoint: nb_db_endpoint,
                      sb_db_endpoint: sb_db_endpoint,
                      northd_host: northd_host,
                      existing_deployment: existing_deployment,
                      host_lookup: host_lookup)
        rescue StandardError => e
          Rails.logger.error("[SdwanOvnComposeTopologyExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Rollback: tear down ports → switches → (only when this call
        # created it) deployment. Pre-existing deployments are left
        # untouched because other state may depend on them. Mirrors the
        # rollback-order pattern in ConfigureSdwanForProjectExecutor.
        def rollback_sdwan_ovn_compose_topology(ovn_deployment_id: nil,
                                                logical_switch_ids: [],
                                                logical_switch_port_ids: [],
                                                created_deployment: false,
                                                **_extras)
          errors = []

          Array(logical_switch_port_ids).reverse_each do |port_id|
            port = ::Sdwan::OvnLogicalSwitchPort.where(account_id: @account.id).find_by(id: port_id)
            next unless port

            begin
              port.destroy!
            rescue StandardError => e
              errors << { resource: "ovn_logical_switch_port", id: port_id, error: e.message }
            end
          end

          Array(logical_switch_ids).reverse_each do |switch_id|
            switch = ::Sdwan::OvnLogicalSwitch.where(account_id: @account.id).find_by(id: switch_id)
            next unless switch

            begin
              switch.destroy!
            rescue StandardError => e
              errors << { resource: "ovn_logical_switch", id: switch_id, error: e.message }
            end
          end

          if created_deployment && ovn_deployment_id.present?
            deployment = ::Sdwan::OvnDeployment.where(account_id: @account.id).find_by(id: ovn_deployment_id)
            if deployment
              begin
                deployment.destroy!
              rescue StandardError => e
                errors << { resource: "ovn_deployment", id: ovn_deployment_id, error: e.message }
              end
            end
          end

          { success: errors.empty?, errors: errors }
        end

        private

        # Returns nil on success, a failure-shaped hash on rejection.
        def validate_inputs(switches:)
          arr = Array(switches)
          return failure("switches must contain at least one entry") if arr.empty?
          return failure("switches must be <= #{MAX_SWITCHES}") if arr.size > MAX_SWITCHES

          arr.each_with_index do |s, idx|
            name = (s[:name] || s["name"]).to_s.strip
            return failure("switches[#{idx}].name is required") if name.empty?

            ports = Array(s[:ports] || s["ports"])
            if ports.size > MAX_PORTS_PER_SWITCH
              return failure("switches[#{idx}] (#{name}) has too many ports (max #{MAX_PORTS_PER_SWITCH})")
            end

            ports.each_with_index do |p, pidx|
              port_name = (p[:name] || p["name"]).to_s.strip
              return failure("switches[#{idx}].ports[#{pidx}].name is required") if port_name.empty?

              kind = (p[:kind] || p["kind"]).to_s
              unless VALID_PORT_KINDS.include?(kind)
                return failure("switches[#{idx}].ports[#{pidx}].kind must be one of: #{VALID_PORT_KINDS.join(', ')}")
              end

              host_id = (p[:host_node_instance_id] || p["host_node_instance_id"]).to_s.strip
              if %w[vm container].include?(kind) && host_id.empty?
                return failure("switches[#{idx}].ports[#{pidx}] (kind=#{kind}) requires host_node_instance_id")
              end
            end
          end

          nil
        end

        def collect_host_ids(switches)
          ids = []
          Array(switches).each do |s|
            Array(s[:ports] || s["ports"]).each do |p|
              h = (p[:host_node_instance_id] || p["host_node_instance_id"]).to_s.strip
              ids << h unless h.empty?
            end
          end
          ids.uniq
        end

        # Returns either a {id => instance} lookup hash, or a failure-shaped
        # hash when one or more ids don't belong to the executing account.
        def lookup_hosts_or_fail(host_ids)
          return {} if host_ids.empty?

          instances = ::System::NodeInstance.joins(:node)
                                            .where(system_nodes: { account_id: @account.id })
                                            .where(id: host_ids)
                                            .to_a
          if instances.size != host_ids.size
            missing = host_ids - instances.map(&:id)
            return failure("host_node_instance_id(s) not found in account: #{missing.join(', ')}")
          end

          instances.index_by(&:id)
        end

        def run_execute(switches:, nb_db_endpoint:, sb_db_endpoint:, northd_host:,
                        existing_deployment:, host_lookup:)
          planned_actions = []
          failures = []
          created_deployment = existing_deployment.nil?
          deployment = existing_deployment
          switch_ids = []
          port_ids = []

          if created_deployment
            begin
              deployment = ::Sdwan::OvnDeployment.create!(
                account_id: @account.id,
                nb_db_endpoint: nb_db_endpoint,
                sb_db_endpoint: sb_db_endpoint,
                northd_host: northd_host
              )
              planned_actions << { step: "create_deployment", deployment_id: deployment.id }
            rescue StandardError => e
              failures << { step: "create_deployment", error: e.message }
              return finalize(planned_actions: planned_actions, failures: failures,
                              deployment_id: nil, created_deployment: false,
                              switch_ids: [], port_ids: [], compiled_plan: nil,
                              switch_count: 0, port_count: 0)
            end
          end

          Array(switches).each_with_index do |s_attrs, sidx|
            switch_name = (s_attrs[:name] || s_attrs["name"]).to_s.strip
            switch_cidr = (s_attrs[:cidr] || s_attrs["cidr"]).to_s.presence

            switch = nil
            begin
              switch = ::Sdwan::OvnLogicalSwitch.create!(
                account_id: @account.id,
                sdwan_ovn_deployment_id: deployment.id,
                name: switch_name,
                cidr: switch_cidr
              )
              switch.mark_active!
              switch_ids << switch.id
              planned_actions << { step: "create_logical_switch",
                                   switch_id: switch.id, name: switch_name, index: sidx }
            rescue StandardError => e
              failures << { step: "create_logical_switch",
                            name: switch_name, index: sidx, error: e.message }
              next
            end

            Array(s_attrs[:ports] || s_attrs["ports"]).each_with_index do |p_attrs, pidx|
              port_name = (p_attrs[:name] || p_attrs["name"]).to_s.strip
              kind      = (p_attrs[:kind] || p_attrs["kind"]).to_s
              addresses = Array(p_attrs[:addresses] || p_attrs["addresses"]).map(&:to_s)
              host_id   = (p_attrs[:host_node_instance_id] || p_attrs["host_node_instance_id"]).to_s.strip
              host      = host_id.empty? ? nil : host_lookup[host_id]

              begin
                port = ::Sdwan::OvnLogicalSwitchPort.create!(
                  account_id: @account.id,
                  sdwan_ovn_logical_switch_id: switch.id,
                  name: port_name,
                  kind: kind,
                  addresses: addresses,
                  host_node_instance: host
                )
                port.mark_active!
                port_ids << port.id
                planned_actions << { step: "create_logical_switch_port",
                                     port_id: port.id, switch_id: switch.id,
                                     name: port_name, kind: kind, index: pidx }
              rescue StandardError => e
                failures << { step: "create_logical_switch_port",
                              switch_id: switch.id, name: port_name, kind: kind, index: pidx,
                              error: e.message }
              end
            end
          end

          compiled_plan =
            begin
              ::Sdwan::OvnCompiler.compile_for_deployment(deployment.reload)
            rescue StandardError => e
              failures << { step: "compile_topology", error: e.message }
              nil
            end
          planned_actions << { step: "compile_topology",
                               switch_count: switch_ids.size, port_count: port_ids.size }

          finalize(planned_actions: planned_actions, failures: failures,
                   deployment_id: deployment&.id, created_deployment: created_deployment,
                   switch_ids: switch_ids, port_ids: port_ids,
                   compiled_plan: compiled_plan,
                   switch_count: switch_ids.size, port_count: port_ids.size)
        end

        def finalize(planned_actions:, failures:, deployment_id:, created_deployment:,
                     switch_ids:, port_ids:, compiled_plan:, switch_count:, port_count:)
          success(
            dry_run: false,
            switch_count: switch_count,
            port_count: port_count,
            planned_actions: planned_actions,
            outputs: {
              ovn_deployment_id: deployment_id,
              created_deployment: created_deployment,
              logical_switch_ids: switch_ids,
              logical_switch_port_ids: port_ids,
              compiled_plan: compiled_plan
            },
            failures: failures,
            partial: failures.any? && (switch_ids.any? || port_ids.any? || deployment_id.present?)
          )
        end

        def build_plan(switches:, creating_deployment:)
          steps = []
          steps << { step: "create_deployment" } if creating_deployment
          Array(switches).each_with_index do |s, sidx|
            name = (s[:name] || s["name"]).to_s
            steps << { step: "create_logical_switch", name: name, index: sidx }
            Array(s[:ports] || s["ports"]).each_with_index do |p, pidx|
              port_name = (p[:name] || p["name"]).to_s
              kind      = (p[:kind] || p["kind"]).to_s
              steps << { step: "create_logical_switch_port",
                         switch_name: name, name: port_name, kind: kind, index: pidx }
            end
          end
          steps << { step: "compile_topology" }
          steps
        end

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
