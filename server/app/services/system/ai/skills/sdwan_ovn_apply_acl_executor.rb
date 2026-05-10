# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composition skill — apply OVN ACLs (firewall rules) to a logical
      # switch. Composition shape:
      #
      #   Sdwan::OvnLogicalSwitch (existing) → N × Sdwan::OvnAcl.find_or_create_by(name)
      #     → mark_active!  → updated compiled_plan via OvnCompiler
      #
      # Idempotent on (switch, name): re-running with the same name
      # returns the existing ACL row without mutating its match/action/
      # priority. Mirrors the OVN compose topology skill's per-entity
      # idempotency convention.
      #
      # ACL semantics — quick reference for the AI agent:
      #   - direction: from-lport (egress from source pod/VM) | to-lport
      #                (ingress to destination pod/VM)
      #   - priority:  higher first; OVN range 0..32767; default 1000
      #   - match:     OVN match expression — `ip4.src == 10.0.0.0/8 &&
      #                tcp.dst == 5432` for "block all 5432 traffic from
      #                the 10.0/8 tenant"
      #   - action:    allow | drop | reject | allow-related
      #
      # Heavyweight-profile only in effect — ACLs only have meaning on
      # OVN-managed switches, which only exist in the heavyweight
      # profile. Lightweight hosts use kube-proxy NetworkPolicy for the
      # equivalent function.
      #
      # Phase O6 follow-up of the OVS+OVN dual-profile networking
      # roadmap. Bound to the System Topology Designer agent.
      class SdwanOvnApplyAclExecutor
        VALID_DIRECTIONS = ::Sdwan::OvnAcl::DIRECTIONS
        VALID_ACTIONS    = ::Sdwan::OvnAcl::ACTIONS
        DEFAULT_PRIORITY = ::Sdwan::OvnAcl::DEFAULT_PRIORITY
        PRIORITY_MIN     = ::Sdwan::OvnAcl::PRIORITY_MIN
        PRIORITY_MAX     = ::Sdwan::OvnAcl::PRIORITY_MAX
        MAX_ACLS         = 100

        def self.descriptor
          {
            name: "sdwan_ovn_apply_acl",
            description: "Apply OVN ACLs (firewall rules) to a logical switch — heavyweight-profile only. Composes Sdwan::OvnAcl entries scoped to one switch and re-compiles the deployment plan. Idempotent on (switch, acl_name).",
            category: "devops",
            inputs: {
              logical_switch_id: { type: "string", required: true,
                                   description: "Sdwan::OvnLogicalSwitch id the ACLs apply to (must belong to the executing account)" },
              acls: { type: "array", required: true,
                      description: "Array of {name, direction, priority?, match, action} (1-#{MAX_ACLS}). direction: #{VALID_DIRECTIONS.join(' | ')}. action: #{VALID_ACTIONS.join(' | ')}. priority: #{PRIORITY_MIN}-#{PRIORITY_MAX}, default #{DEFAULT_PRIORITY}." },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — no Sdwan::OvnAcl rows are persisted" }
            },
            outputs: {
              dry_run: :boolean,
              acl_count: :integer,
              planned_actions: [ :object ],
              outputs: {
                logical_switch_id: :string,
                ovn_acl_ids: [ :string ],
                allocations: [ :object ],
                compiled_plan: :object
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_sdwan_ovn_apply_acl,
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(logical_switch_id:, acls:, dry_run: false, **_extras)
          if (validation_error = validate_inputs(acls: acls))
            return validation_error
          end

          switch_id = logical_switch_id.to_s.strip
          return failure("logical_switch_id is required") if switch_id.empty?

          switch = lookup_switch(switch_id)
          return switch if switch.is_a?(Hash) && switch[:success] == false

          if dry_run
            return success(
              dry_run: true,
              acl_count: acls.size,
              planned_actions: build_plan(switch: switch, acls: acls),
              outputs: {
                logical_switch_id: switch.id,
                ovn_acl_ids: [],
                allocations: acls.map { |a| project_allocation(a) },
                compiled_plan: nil
              },
              failures: [],
              partial: false
            )
          end

          run_execute(switch: switch, acls: acls)
        rescue StandardError => e
          Rails.logger.error("[SdwanOvnApplyAclExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Rollback: destroy only ACLs this call newly created. Re-used
        # ACLs are left alone because other state (compiler emission,
        # operator-visible firewall coverage) may depend on them.
        def rollback_sdwan_ovn_apply_acl(allocations: [], **_extras)
          errors = []

          Array(allocations).each do |alloc|
            next if alloc[:reused] || alloc["reused"]

            acl_id = (alloc[:ovn_acl_id] || alloc["ovn_acl_id"]).to_s
            next if acl_id.empty?

            acl = ::Sdwan::OvnAcl.where(account_id: @account.id).find_by(id: acl_id)
            next unless acl

            begin
              acl.destroy!
            rescue StandardError => e
              errors << { resource: "ovn_acl", id: acl_id, error: e.message }
            end
          end

          { success: errors.empty?, errors: errors }
        end

        private

        # Returns nil on success, a failure-shaped hash on rejection.
        def validate_inputs(acls:)
          arr = Array(acls)
          return failure("acls must contain at least one entry") if arr.empty?
          return failure("acls must be <= #{MAX_ACLS}") if arr.size > MAX_ACLS

          arr.each_with_index do |a, idx|
            name = (a[:name] || a["name"]).to_s.strip
            return failure("acls[#{idx}].name is required") if name.empty?

            direction = (a[:direction] || a["direction"]).to_s
            unless VALID_DIRECTIONS.include?(direction)
              return failure("acls[#{idx}].direction must be one of: #{VALID_DIRECTIONS.join(', ')}")
            end

            action = (a[:action] || a["action"]).to_s
            unless VALID_ACTIONS.include?(action)
              return failure("acls[#{idx}].action must be one of: #{VALID_ACTIONS.join(', ')}")
            end

            match = (a[:match] || a["match"]).to_s.strip
            return failure("acls[#{idx}].match is required") if match.empty?

            priority = a[:priority] || a["priority"] || DEFAULT_PRIORITY
            unless priority.to_i.between?(PRIORITY_MIN, PRIORITY_MAX)
              return failure("acls[#{idx}].priority must be between #{PRIORITY_MIN} and #{PRIORITY_MAX}")
            end
          end

          nil
        end

        # Returns the switch (account-scoped) or a failure-shaped hash.
        def lookup_switch(switch_id)
          # Account scoping via the deployment join — switches don't
          # carry an account_id directly in the join, but they're
          # account-scoped at the model level via `belongs_to :account`.
          switch = ::Sdwan::OvnLogicalSwitch.where(account_id: @account.id).find_by(id: switch_id)
          return failure("logical_switch_id not found in account: #{switch_id}") unless switch

          switch
        end

        def run_execute(switch:, acls:)
          planned_actions = []
          failures = []
          ovn_acl_ids = []
          allocations = []

          Array(acls).each_with_index do |a_attrs, idx|
            name      = (a_attrs[:name] || a_attrs["name"]).to_s.strip
            direction = (a_attrs[:direction] || a_attrs["direction"]).to_s
            action    = (a_attrs[:action] || a_attrs["action"]).to_s
            match     = (a_attrs[:match] || a_attrs["match"]).to_s.strip
            priority  = (a_attrs[:priority] || a_attrs["priority"] || DEFAULT_PRIORITY).to_i

            existing = ::Sdwan::OvnAcl.where(
              sdwan_ovn_logical_switch_id: switch.id,
              name: name
            ).first

            if existing
              ovn_acl_ids << existing.id
              alloc = {
                ovn_acl_id: existing.id, name: existing.name,
                direction: existing.direction, priority: existing.priority,
                match: existing.match, action: existing.action,
                state: existing.state, reused: true
              }
              allocations << alloc
              planned_actions << { step: "reuse_acl", acl_id: existing.id,
                                   name: existing.name, index: idx }
              next
            end

            begin
              acl = ::Sdwan::OvnAcl.create!(
                account_id: @account.id,
                sdwan_ovn_logical_switch_id: switch.id,
                name: name,
                direction: direction,
                priority: priority,
                match: match,
                action: action
              )
              acl.mark_active!
              ovn_acl_ids << acl.id
              allocations << {
                ovn_acl_id: acl.id, name: acl.name,
                direction: acl.direction, priority: acl.priority,
                match: acl.match, action: acl.action,
                state: acl.state, reused: false
              }
              planned_actions << { step: "create_acl", acl_id: acl.id,
                                   name: acl.name, direction: acl.direction,
                                   priority: acl.priority, action: acl.action,
                                   index: idx }
            rescue StandardError => e
              failures << { step: "create_acl", name: name, index: idx, error: e.message }
            end
          end

          # Re-compile the deployment plan so the operator sees the new
          # acl-add commands surface immediately. The switch.deployment
          # association walks one belongs_to → cheap.
          compiled_plan =
            begin
              ::Sdwan::OvnCompiler.compile_for_deployment(switch.deployment)
            rescue StandardError => e
              failures << { step: "compile_topology", error: e.message }
              nil
            end
          planned_actions << { step: "compile_topology", acl_count: ovn_acl_ids.size }

          finalize(planned_actions: planned_actions, failures: failures,
                   logical_switch_id: switch.id, ovn_acl_ids: ovn_acl_ids,
                   allocations: allocations, compiled_plan: compiled_plan,
                   acl_count: ovn_acl_ids.size)
        end

        def finalize(planned_actions:, failures:, logical_switch_id:, ovn_acl_ids:,
                     allocations:, compiled_plan:, acl_count:)
          success(
            dry_run: false,
            acl_count: acl_count,
            planned_actions: planned_actions,
            outputs: {
              logical_switch_id: logical_switch_id,
              ovn_acl_ids: ovn_acl_ids,
              allocations: allocations,
              compiled_plan: compiled_plan
            },
            failures: failures,
            partial: failures.any? && ovn_acl_ids.any?
          )
        end

        def build_plan(switch:, acls:)
          steps = Array(acls).each_with_index.map do |a, idx|
            { step: "create_or_reuse_acl",
              switch_id: switch.id,
              name: (a[:name] || a["name"]).to_s,
              direction: (a[:direction] || a["direction"]).to_s,
              priority: (a[:priority] || a["priority"] || DEFAULT_PRIORITY).to_i,
              action: (a[:action] || a["action"]).to_s,
              index: idx }
        end
          steps + [ { step: "compile_topology" } ]
        end

        def project_allocation(a)
          {
            name: (a[:name] || a["name"]).to_s,
            direction: (a[:direction] || a["direction"]).to_s,
            priority: (a[:priority] || a["priority"] || DEFAULT_PRIORITY).to_i,
            match: (a[:match] || a["match"]).to_s,
            action: (a[:action] || a["action"]).to_s
          }
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
