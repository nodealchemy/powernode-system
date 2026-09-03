# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composer-of-composers — stands up a federation overlay topology by
      # threading the three SDWAN composition primitives in dependency order,
      # per peer, with inline data flow:
      #
      #   Sdwan::Network.create!(topology_strategy:)            (once)
      #     → N × Sdwan::PeerEnroller.call                      (one per member)
      #       → Sdwan::TopologyCompiler.compile_for_network     (per-peer WG view)
      #         → Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer (per-peer FRR)
      #
      # Two topology shapes, selected by `topology`:
      #   - "hub_and_spoke" — peers tagged role:"hub" enroll publicly_reachable
      #     (endpoint required); everything else is a spoke that funnels
      #     through the hub(s). Mirrors Sdwan::TopologyStrategies::HubAndSpoke.
      #   - "full_mesh"     — every peer connects directly to every other peer
      #     (no relay). Mirrors Sdwan::TopologyStrategies::FullMesh. Peers with
      #     an endpoint are dialable; the rest are reached outbound.
      #
      # The compilers run at the end of `execute` even on the live path so the
      # audit log + return payload capture the resulting per-peer topology
      # envelope (WireGuard peers + FRR route-policy blocks) the agent will
      # eventually pick up. In dry_run mode nothing is persisted — the plan is
      # rendered from the supplied peer set so the plan-review surface can show
      # the projected fan-out without touching the DB.
      #
      # Rollback is delegation + reverse-order teardown (mirrors
      # SdwanComposeFullTopologyExecutor + ConfigureSdwanForProjectExecutor):
      # destroy peers in reverse enrollment order, then the network. Destroying
      # the network cascades to peers via dependent: :destroy, so the explicit
      # per-peer detach is belt-and-braces for audit-trail granularity.
      #
      # Phase 3 (Federation & Multi-Site) — SDWAN-first federation composition.
      class SdwanFederationComposeExecutor < BaseSkillExecutor
        include SdwanCompositionPipeline

        TOPOLOGIES         = %w[hub_and_spoke full_mesh].freeze
        ROUTING_PROTOCOLS  = %w[static ibgp].freeze
        MAX_PEERS          = 200

        skill_descriptor(
          name: "sdwan_federation_compose",
          description: "Stand up a federation overlay topology (hub-and-spoke OR full-mesh) by composing per-peer Sdwan::PeerEnroller + Sdwan::TopologyCompiler + Sdwan::Bgp::RoutePolicyCompiler. Creates one Sdwan::Network, enrolls each member as a peer (hubs publicly_reachable), and compiles the per-peer WireGuard + FRR route-policy envelope.",
          category: "federation",
          inputs: {
            network_name: { type: "string", required: true,
                            description: "Display name for the new federation Sdwan::Network" },
            topology: { type: "string", required: true,
                        description: "One of: #{TOPOLOGIES.join(', ')}" },
            peers: { type: "array", required: true,
                     description: "Member descriptors (1-#{MAX_PEERS}). Each: {node_instance_id (required), role: 'hub'|'spoke' (hub_and_spoke only; default spoke), endpoint_host_v6, endpoint_host_v4, endpoint_port, listen_port, lan_subnets: [cidr], bgp_route_reflector_client: bool}" },
            routing_protocol: { type: "string", required: false, default: "static",
                                description: "One of: #{ROUTING_PROTOCOLS.join(', ')} — 'ibgp' enables FRR route-policy distribution" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no Sdwan::Network/Peer rows are persisted" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            topology: :string,
            routing_protocol: :string,
            planned_actions: [ :object ],
            outputs: {
              sdwan_network_id: :string,
              sdwan_peer_ids: [ :string ],
              hub_peer_ids: [ :string ],
              topology_preview: [ :object ],
              route_policy_preview: [ :object ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_sdwan_federation_compose,
          blast_radius: :high
        )

        binds_to "topology_designer"

        # Rollback: detach peers in reverse enrollment order, then delete the
        # network. Network destroy cascades to any surviving peers via
        # dependent: :destroy; the explicit per-peer pass preserves audit
        # granularity and tolerates rows already gone. Tolerates extra kwargs
        # (hub_peer_ids, topology_preview, route_policy_preview) so the caller
        # can splat the whole `outputs` hash back in.
        def rollback_sdwan_federation_compose(sdwan_network_id: nil, sdwan_peer_ids: [], **_extras)
          errors = teardown_peers_then_network(
            sdwan_network_id: sdwan_network_id,
            sdwan_peer_ids: sdwan_peer_ids,
            errors: []
          )

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(network_name:, topology:, peers:, routing_protocol: "static",
                    dry_run: false, **_extras)
          topo = topology.to_s
          return failure("topology must be one of: #{TOPOLOGIES.join(', ')}") unless TOPOLOGIES.include?(topo)

          protocol = routing_protocol.to_s
          return failure("routing_protocol must be one of: #{ROUTING_PROTOCOLS.join(', ')}") unless ROUTING_PROTOCOLS.include?(protocol)

          name = network_name.to_s.strip
          return failure("network_name is required") if name.empty?

          specs = normalize_peer_specs(peers)
          return failure("peers must contain at least one member") if specs.empty?
          return failure("peers count must be <= #{MAX_PEERS}") if specs.size > MAX_PEERS

          # Hub-and-spoke needs at least one hub or the network is isolated;
          # surface that as a hard validation error rather than silently
          # building an unreachable overlay.
          if topo == "hub_and_spoke" && specs.none? { |s| s[:role] == "hub" }
            return failure("hub_and_spoke topology requires at least one peer with role: 'hub'")
          end

          # Every hub MUST advertise an endpoint — Sdwan::Peer validation
          # rejects publicly_reachable peers without one, so we fail fast
          # with a clearer message before half-building the network.
          hubs_missing_endpoint = specs.select { |s| s[:role] == "hub" && !endpoint?(s) }.map { |s| s[:node_instance_id] }
          if hubs_missing_endpoint.any?
            return failure("hub peer(s) require an endpoint (endpoint_host_v6/v4 + endpoint_port): #{hubs_missing_endpoint.join(', ')}")
          end

          ids = specs.map { |s| s[:node_instance_id] }.uniq
          instances = account_scoped_instances(ids).index_by(&:id)
          if instances.size != ids.size
            missing = missing_instance_ids(ids, instances)
            return failure("instance(s) not found: #{missing.join(', ')}")
          end

          if dry_run
            return success(dry_run_payload(name: name, topology: topo, protocol: protocol, specs: specs))
          end

          run_execute(name: name, topology: topo, protocol: protocol, specs: specs, instances: instances)
        end

        private

        # ---- live path -------------------------------------------------

        def run_execute(name:, topology:, protocol:, specs:, instances:)
          planned_actions = []
          failures = []
          peer_ids = []
          hub_peer_ids = []
          network = nil

          begin
            network = ::Sdwan::Network.create!(
              account_id: @account.id,
              name: name,
              description: "Federation overlay composed by sdwan_federation_compose (#{topology})",
              routing_protocol: protocol,
              settings: { "topology_strategy" => topology }
            )
            planned_actions << { step: "create_network", network_id: network.id,
                                 topology: topology, routing_protocol: protocol }
          rescue StandardError => e
            failures << { step: "create_network", error: e.message }
            return finalize(network: nil, peer_ids: [], hub_peer_ids: [],
                            planned_actions: planned_actions, failures: failures,
                            topology: topology, protocol: protocol,
                            topology_preview: [], route_policy_preview: [])
          end

          specs.each_with_index do |spec, idx|
            instance = instances[spec[:node_instance_id]]
            is_hub = spec[:role] == "hub"
            begin
              peer = ::Sdwan::PeerEnroller.call(
                network: network,
                node_instance: instance,
                publicly_reachable: is_hub,
                endpoint_host_v6: spec[:endpoint_host_v6],
                endpoint_host_v4: spec[:endpoint_host_v4],
                endpoint_port: spec[:endpoint_port],
                listen_port: spec[:listen_port] || 51_820,
                lan_subnets: spec[:lan_subnets],
                bgp_route_reflector_client: spec[:bgp_route_reflector_client]
              )
              peer_ids << peer.id
              hub_peer_ids << peer.id if is_hub
              planned_actions << { step: "attach_peer", network_id: network.id,
                                   instance_id: instance.id, peer_id: peer.id,
                                   role: spec[:role], index: idx }
            rescue StandardError => e
              failures << { step: "attach_peer", instance_id: instance.id, role: spec[:role], error: e.message }
            end
          end

          topology_preview = compile_topology(network, failures)
          planned_actions << { step: "compile_topology", peer_count: topology_preview.size }

          route_policy_preview = compile_route_policies(network, failures)
          planned_actions << { step: "compile_route_policies",
                               routing_protocol: protocol,
                               policy_peer_count: route_policy_preview.size }

          finalize(network: network, peer_ids: peer_ids, hub_peer_ids: hub_peer_ids,
                   planned_actions: planned_actions, failures: failures,
                   topology: topology, protocol: protocol,
                   topology_preview: topology_preview, route_policy_preview: route_policy_preview)
        end

        # Per-peer WireGuard view. compile_for_network dispatches to the
        # topology strategy named in settings["topology_strategy"] — so a
        # "full_mesh" network resolves Sdwan::TopologyStrategies::FullMesh,
        # "hub_and_spoke" resolves HubAndSpoke.
        def compile_topology(network, failures)
          ::Sdwan::TopologyCompiler.compile_for_network(network)
        rescue StandardError => e
          failures << { step: "compile_topology", error: e.message }
          []
        end

        # Per-peer FRR route-policy view — only meaningful for ibgp networks.
        # Static networks carry no FRR daemon (declarative AllowedIPs only), so
        # we skip the RoutePolicyCompiler entirely and return an empty preview
        # rather than running a full per-peer compile that would yield nothing.
        # For ibgp networks the compiler folds any applicable Sdwan::RoutePolicy
        # rows into route-maps/prefix-lists, one envelope per peer. Reads
        # network.ibgp_routing? (set from routing_protocol at create_network).
        def compile_route_policies(network, failures)
          return [] unless network.ibgp_routing?

          network.peers.includes(:keys).filter_map do |peer|
            compiled = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(peer)
            { peer_id: peer.id,
              route_maps: compiled[:route_maps],
              neighbor_assignments: compiled[:neighbor_assignments] }
          rescue StandardError => e
            failures << { step: "compile_route_policies", peer_id: peer.id, error: e.message }
            nil
          end
        end

        def finalize(network:, peer_ids:, hub_peer_ids:, planned_actions:, failures:,
                     topology:, protocol:, topology_preview:, route_policy_preview:)
          success(
            dry_run: false,
            count: peer_ids.size,
            topology: topology,
            routing_protocol: protocol,
            planned_actions: planned_actions,
            outputs: {
              sdwan_network_id: network&.id,
              sdwan_peer_ids: peer_ids,
              hub_peer_ids: hub_peer_ids,
              topology_preview: topology_preview,
              route_policy_preview: route_policy_preview
            },
            failures: failures,
            partial: partial_run?(failures: failures, peer_ids: peer_ids, network_id: network&.id)
          )
        end

        # ---- dry-run path ----------------------------------------------

        def dry_run_payload(name:, topology:, protocol:, specs:)
          {
            dry_run: true,
            count: specs.size,
            topology: topology,
            routing_protocol: protocol,
            planned_actions: build_plan(name: name, topology: topology, protocol: protocol, specs: specs),
            outputs: {
              sdwan_network_id: nil,
              sdwan_peer_ids: [],
              hub_peer_ids: [],
              topology_preview: dry_run_topology_preview(name: name, topology: topology, specs: specs),
              route_policy_preview: []
            },
            failures: [],
            partial: false
          }
        end

        def build_plan(name:, topology:, protocol:, specs:)
          steps = [ { step: "create_network", name: name, topology: topology, routing_protocol: protocol } ]
          specs.each_with_index do |spec, idx|
            steps << { step: "attach_peer", instance_id: spec[:node_instance_id], role: spec[:role], index: idx }
          end
          steps << { step: "compile_topology" }
          steps << { step: "compile_route_policies", routing_protocol: protocol }
          steps
        end

        def dry_run_topology_preview(name:, topology:, specs:)
          hub_count = specs.count { |s| s[:role] == "hub" }
          [ { network_name: name, topology: topology,
              projected_peer_count: specs.size, projected_hub_count: hub_count } ]
        end

        # ---- helpers ---------------------------------------------------

        # AI tool-call payloads arrive string-keyed from the MCP transport;
        # normalize each peer descriptor into a symbol-keyed spec with a
        # defaulted role. full_mesh has no hub/spoke distinction, so any
        # non-"hub" role (including the default) is treated as a plain
        # member there; in hub_and_spoke it's a spoke.
        def normalize_peer_specs(peers)
          Array(peers).filter_map do |raw|
            h = symbolize(raw)
            iid = h[:node_instance_id].to_s
            next if iid.empty?

            {
              node_instance_id: iid,
              role: h[:role].to_s == "hub" ? "hub" : "spoke",
              endpoint_host_v6: presence(h[:endpoint_host_v6]),
              endpoint_host_v4: presence(h[:endpoint_host_v4]),
              endpoint_port: h[:endpoint_port],
              listen_port: h[:listen_port],
              lan_subnets: Array(h[:lan_subnets]).map(&:to_s).reject(&:empty?),
              bgp_route_reflector_client: h[:bgp_route_reflector_client] ? true : false
            }
          end
        end

        def endpoint?(spec)
          spec[:endpoint_host_v6].present? || spec[:endpoint_host_v4].present?
        end

        def symbolize(h)
          return {} unless h.is_a?(Hash)

          h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
        end

        def presence(val)
          val.to_s.strip.empty? ? nil : val
        end
      end
    end
  end
end
