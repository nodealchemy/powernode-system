# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — bring up an SDWAN overlay for an
      # existing project's instances. Composition shape:
      #
      #   Sdwan::Network.create!  →  N × Sdwan::PeerEnroller.call
      #     [+ Sdwan::VirtualIp.create! when with_vip]
      #     →  Sdwan::TopologyCompiler.compile_for_network  (dry-run preview)
      #
      # The compiler is invoked at the end of execute even on the live
      # path so the audit log captures the resulting topology view (peer
      # count + interface envelope) the agent will eventually pick up.
      # In dry_run mode we still compile against the un-persisted network
      # (M1 ProvisioningTool dry-run support added that affordance) so the
      # plan-review surface can show the projected peer fan-out.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
      class ConfigureSdwanForProjectExecutor
        TOPOLOGIES = %w[hub_and_spoke mesh].freeze
        MAX_PEERS  = 100

        def self.descriptor
          {
            name: "configure_sdwan_for_project",
            description: "Create an SDWAN network for a project, attach the supplied instances as peers, optionally provision a project VIP, and compile the topology preview. Composes Sdwan::Network + Sdwan::PeerEnroller + Sdwan::VirtualIp + Sdwan::TopologyCompiler.",
            category: "devops",
            inputs: {
              project_id: { type: "string", required: true,
                            description: "Ai::Mission id (the provisioning project receiving the overlay)" },
              instance_ids: { type: "array", required: true,
                              description: "System::NodeInstance ids to enroll as peers (1-#{MAX_PEERS})" },
              network_name: { type: "string", required: true,
                              description: "Display name for the new Sdwan::Network" },
              topology: { type: "string", required: true,
                          description: "One of: #{TOPOLOGIES.join(', ')}" },
              with_vip: { type: "boolean", required: false, default: false,
                          description: "When true, provision a project-level VirtualIp held by the first peer" },
              vip_name: { type: "string", required: false,
                          description: "Optional VIP name (defaults to '<network_name>-vip')" },
              vip_cidr: { type: "string", required: false,
                          description: "VIP CIDR — required when with_vip is true (operator must provide a /128 in the network's /64)" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — no Sdwan::Network/Peer/VirtualIp rows are persisted" }
            },
            outputs: {
              dry_run: :boolean,
              count: :integer,
              topology: :string,
              planned_actions: [ :object ],
              outputs: {
                sdwan_network_id: :string,
                sdwan_peer_ids: [ :string ],
                virtual_ip_id: :string,
                topology_preview: [ :object ]
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_configure_sdwan_for_project,
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(project_id:, instance_ids:, network_name:, topology:,
                    with_vip: false, vip_name: nil, vip_cidr: nil,
                    dry_run: false, **_extras)
          topo = topology.to_s
          return failure("topology must be one of: #{TOPOLOGIES.join(', ')}") unless TOPOLOGIES.include?(topo)

          ids = Array(instance_ids).map(&:to_s).reject(&:empty?)
          return failure("instance_ids must contain at least one id") if ids.empty?
          return failure("instance_ids count must be <= #{MAX_PEERS}") if ids.size > MAX_PEERS

          name = network_name.to_s.strip
          return failure("network_name is required") if name.empty?

          if with_vip && vip_cidr.to_s.strip.empty?
            return failure("vip_cidr is required when with_vip is true")
          end

          mission = ::Ai::Mission.where(account_id: @account.id).find_by(id: project_id)
          return failure("project not found: #{project_id}") unless mission

          # Verify all instance ids belong to this account up-front so we
          # don't half-create the network on a stranger.
          instances_relation = ::System::NodeInstance.joins(:node)
                                                      .where(system_nodes: { account_id: @account.id })
                                                      .where(id: ids)
          instances = instances_relation.to_a
          if instances.size != ids.size
            missing = ids - instances.map(&:id)
            return failure("instance(s) not found: #{missing.join(', ')}")
          end

          if dry_run
            return success(
              dry_run: true,
              count: ids.size,
              topology: topo,
              planned_actions: build_plan(name: name, topology: topo, instances: instances,
                                          with_vip: with_vip, vip_name: vip_name, vip_cidr: vip_cidr),
              outputs: {
                sdwan_network_id: nil,
                sdwan_peer_ids: [],
                virtual_ip_id: nil,
                topology_preview: dry_run_topology_preview(name: name, topology: topo, count: instances.size)
              },
              failures: [],
              partial: false
            )
          end

          run_execute(name: name, topology: topo, instances: instances,
                      with_vip: with_vip, vip_name: vip_name, vip_cidr: vip_cidr)
        rescue StandardError => e
          Rails.logger.error("[ConfigureSdwanForProjectExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Rollback: delete VIP, detach peers, delete network. Order matters:
        # destroying the network cascades to peers via dependent: :destroy,
        # so the explicit per-peer detach is a belt-and-braces measure that
        # preserves audit-trail granularity.
        def rollback_configure_sdwan_for_project(sdwan_network_id: nil, sdwan_peer_ids: [],
                                                 virtual_ip_id: nil, **_extras)
          errors = []

          if virtual_ip_id.present?
            vip = ::Sdwan::VirtualIp.where(account_id: @account.id).find_by(id: virtual_ip_id)
            if vip
              begin
                vip.destroy!
              rescue StandardError => e
                errors << { resource: "sdwan_virtual_ip", id: virtual_ip_id, error: e.message }
              end
            end
          end

          Array(sdwan_peer_ids).reverse_each do |peer_id|
            peer = ::Sdwan::Peer.where(account_id: @account.id).find_by(id: peer_id)
            next unless peer

            begin
              peer.destroy!
            rescue StandardError => e
              errors << { resource: "sdwan_peer", id: peer_id, error: e.message }
            end
          end

          if sdwan_network_id.present?
            network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: sdwan_network_id)
            if network
              begin
                network.destroy!
              rescue StandardError => e
                errors << { resource: "sdwan_network", id: sdwan_network_id, error: e.message }
              end
            end
          end

          { success: errors.empty?, errors: errors }
        end

        private

        def run_execute(name:, topology:, instances:, with_vip:, vip_name:, vip_cidr:)
          planned_actions = []
          failures = []
          peer_ids = []
          virtual_ip_id = nil
          network = nil

          begin
            network = ::Sdwan::Network.create!(
              account_id: @account.id,
              name: name,
              description: "Provisioned by configure_sdwan_for_project (#{topology})",
              settings: { "topology_strategy" => topology }
            )
            planned_actions << { step: "create_network", network_id: network.id, topology: topology }
          rescue StandardError => e
            failures << { step: "create_network", error: e.message }
            return finalize(planned_actions: planned_actions, failures: failures,
                            network_id: nil, peer_ids: [], virtual_ip_id: nil,
                            topology_preview: [], topology: topology)
          end

          instances.each_with_index do |instance, idx|
            peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
            peer_ids << peer.id
            planned_actions << { step: "attach_peer", network_id: network.id,
                                 instance_id: instance.id, peer_id: peer.id, index: idx }
          rescue StandardError => e
            failures << { step: "attach_peer", instance_id: instance.id, error: e.message }
          end

          if with_vip
            begin
              vip = ::Sdwan::VirtualIp.create!(
                account_id: @account.id,
                sdwan_network_id: network.id,
                name: vip_name.presence || "#{network.name}-vip",
                cidr: vip_cidr,
                holder_peer_ids: peer_ids.first(1),
                state: peer_ids.any? ? "active" : "pending"
              )
              virtual_ip_id = vip.id
              planned_actions << { step: "create_virtual_ip", virtual_ip_id: vip.id, cidr: vip_cidr }
            rescue StandardError => e
              failures << { step: "create_virtual_ip", error: e.message }
            end
          end

          topology_preview =
            begin
              ::Sdwan::TopologyCompiler.compile_for_network(network)
            rescue StandardError => e
              failures << { step: "compile_topology", error: e.message }
              []
            end
          planned_actions << { step: "compile_topology", peer_count: topology_preview.size }

          finalize(planned_actions: planned_actions, failures: failures,
                   network_id: network&.id, peer_ids: peer_ids, virtual_ip_id: virtual_ip_id,
                   topology_preview: topology_preview, topology: topology)
        end

        def finalize(planned_actions:, failures:, network_id:, peer_ids:, virtual_ip_id:,
                     topology_preview:, topology:)
          success(
            dry_run: false,
            count: peer_ids.size,
            topology: topology,
            planned_actions: planned_actions,
            outputs: {
              sdwan_network_id: network_id,
              sdwan_peer_ids: peer_ids,
              virtual_ip_id: virtual_ip_id,
              topology_preview: topology_preview
            },
            failures: failures,
            partial: failures.any? && (peer_ids.any? || network_id.present?)
          )
        end

        def build_plan(name:, topology:, instances:, with_vip:, vip_name:, vip_cidr:)
          steps = [ { step: "create_network", name: name, topology: topology } ]
          instances.each_with_index do |instance, idx|
            steps << { step: "attach_peer", instance_id: instance.id, index: idx }
          end
          if with_vip
            steps << { step: "create_virtual_ip",
                       name: vip_name.presence || "#{name}-vip", cidr: vip_cidr }
          end
          steps << { step: "compile_topology" }
          steps
        end

        def dry_run_topology_preview(name:, topology:, count:)
          [ { network_name: name, topology: topology, projected_peer_count: count } ]
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

# P3.3 discovery-based skill binding (dual-mode with existing seeds).
System::Ai::Skills::SkillBindings.register(
  System::Ai::Skills::ConfigureSdwanForProjectExecutor,
  agents: ["SDWAN Manager", "System Topology Designer"]
)
