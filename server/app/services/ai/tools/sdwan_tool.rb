# frozen_string_literal: true

# MCP tool surface for SDWAN. Mirrors SystemFleetTool's shape (REQUIRED_PERMISSION
# floor + per-action permission map + action switch). Slice 1 actions cover
# network CRUD + peer attach/detach + topology preview; user-device and
# federation actions ship in slices 4 and 6.
#
# Slice 1 of the SDWAN plan.
module Ai
  module Tools
    class SdwanTool < BaseTool
      REQUIRED_PERMISSION = "system.sdwan.networks.read"

      # AUTONOMY ACTION CATEGORIES — declared on the EXECUTORS, not here.
      #
      # This class used to hold thirteen `*_CATEGORY` constants while the REST
      # twins passed the identical strings as bare literals, so a rename was a
      # hand-edit across both surfaces with typo protection on only one of them
      # (IMP-249e01a804e5). Each gated arm below now passes
      # `::Sdwan::Executors::<X>::ACTION_CATEGORY`, exactly as its REST twin
      # does — the executor is the sole writer on the GATED path, so it is the
      # right place for the action's name to live. (Sole on the gated path, not
      # in the platform: the autonomous VIP failover reaches the same row
      # through System::Ai::Skills::SdwanVipFailoverExecutor, which is why
      # system.sdwan_vip_failover is shared rather than owned — see below.)
      #
      # What that constant reference buys, and what it does not: the two GATING
      # surfaces can no longer disagree. The seeded policy row
      # (db/seeds/system_sdwan_manager_agent.rb — except user-device revoke and
      # VIP failover, which are seeded in db/seeds/fleet_autonomy_agent.rb) and
      # the engine's registration allowlist (lib/powernode_system/engine.rb)
      # still carry their own literal, and are held to the declaration by
      # spec/services/sdwan/executors/action_category_coherence_spec.rb.
      #
      # The parity claim the shared category makes is that an agent refused on
      # one surface cannot reach for the other. Three notes on what "the same
      # category" means where an MCP arm and its REST twin are not congruent:
      #
      #   * sdwan.peer_update covers BOTH slice-9a peer arms
      #     (update_peer_lan_subnets, set_peer_tags): lan_subnets and tags ride
      #     the same REST permit list (peer_update_params).
      #   * sdwan.network_update covers BOTH network arms —
      #     update_network_routing_mode (routing_protocol) and the general
      #     update_network (name/description/status/settings, IMP-2ff1980f7813).
      #     Those five fields are a SUBSET of the network_params permit list
      #     NetworksController#update gates as a whole: slug, tags,
      #     advertise_overlay_subnet and route_reflector_redundancy have no MCP
      #     arm at all, so MCP reaches strictly less of the category than REST
      #     does — never more, which is what the parity claim has to mean.
      #   * sdwan.port_mapping_{create,update} used to be the counterexample to
      #     that "never more" claim, in both directions at once: this surface
      #     alone reached rate_limit/max_connections/source_cidrs, the REST
      #     twin alone reached the hub column (IMP-2c531ddb5a0c). Neither arm
      #     carries its own list any more — both read
      #     Sdwan::PortMapping::WRITABLE_ATTRIBUTES, which is why the schema
      #     text and the no-op refusal message below are interpolated rather
      #     than written out.
      #   * system.sdwan_vip_failover (IMP-7c911ca26585) is shared with the
      #     fleet autonomy remediation path (SdwanVipReachabilitySensor →
      #     FleetAutonomyService) as well as VirtualIpsController#failover. The
      #     category STRING is the parity contract; the resolved policy row
      #     differs by audience: the seeded require_approval row is scoped to
      #     the Fleet Autonomy agent (the sensor path), so this tool's arms
      #     (calling agent / nil) and the agent-less REST twin both fall
      #     through to InterventionPolicyService#default_policy — also
      #     require_approval — and per-audience operator rows tune each surface
      #     independently.
      #
      # Historical: the create arms are IMP-6c482005db87, the update arms
      # IMP-c9798d9d5671, and the DESTROY family IMP-800b25c1cc45 — until then
      # delete_network / detach_peer / delete_firewall_rule / delete_virtual_ip
      # / delete_port_mapping / delete_route_policy and create_route_policy
      # called destroy!/save inline while their REST twins were gated, which is
      # the one direction the parity claim above cannot survive: an agent
      # refused at the console reached the same row through this tool. Every
      # executor, category, engine registration and seeded policy row already
      # existed; only the call did not. Held by
      # spec/services/ai/tools/sdwan_mcp_destroy_gate_parity_spec.rb.
      #
      # IMP-2795453255c3 closed the last two — the FEDERATION pair,
      # propose_federation_peer and revoke_federation_peer, which crossed an
      # INSTANCE boundary while calling create!/revoke! inline. The revoke arm
      # was the sharper of the two: the bypass needed no second surface at all,
      # since update_federation_peer's status → "revoked" leg had gated on the
      # identical category since IMP-ca3440a11a9a. Held by
      # spec/services/ai/tools/sdwan_mcp_federation_gate_parity_spec.rb. As of
      # that change every destructive and trust-boundary arm on this tool
      # routes through #gated_result below; a new one must too.

      ACTION_PERMISSIONS = {
        "system_sdwan_list_networks"   => "system.sdwan.networks.read",
        "system_sdwan_get_network"     => "system.sdwan.networks.read",
        "system_sdwan_create_network"  => "system.sdwan.networks.manage",
        "system_sdwan_update_network"  => "system.sdwan.networks.manage",
        "system_sdwan_delete_network"  => "system.sdwan.networks.manage",
        "system_sdwan_list_peers"      => "system.sdwan.peers.read",
        "system_sdwan_get_peer"        => "system.sdwan.peers.read",
        "system_sdwan_attach_peer"     => "system.sdwan.peers.manage",
        "system_sdwan_update_peer"     => "system.sdwan.peers.manage",
        "system_sdwan_detach_peer"     => "system.sdwan.peers.manage",
        "system_sdwan_get_topology"    => "system.sdwan.peers.read",
        # Slice 2: firewall
        "system_sdwan_list_firewall_rules"  => "system.sdwan.firewall.read",
        "system_sdwan_get_firewall_rule"    => "system.sdwan.firewall.read",
        "system_sdwan_create_firewall_rule" => "system.sdwan.firewall.manage",
        "system_sdwan_update_firewall_rule" => "system.sdwan.firewall.manage",
        "system_sdwan_delete_firewall_rule" => "system.sdwan.firewall.manage",
        # Slice 4: user VPN
        "system_sdwan_list_access_grants"   => "system.sdwan.user_devices.manage",
        "system_sdwan_create_access_grant"  => "system.sdwan.user_devices.manage",
        "system_sdwan_revoke_access_grant"  => "system.sdwan.user_devices.manage",
        "system_sdwan_list_user_devices"    => "system.sdwan.user_devices.manage",
        "system_sdwan_issue_user_device"    => "system.sdwan.user_devices.manage",
        "system_sdwan_revoke_user_device"   => "system.sdwan.user_devices.manage",
        # Slice 6: federation scaffold
        "system_sdwan_list_federation_peers"   => "system.sdwan.federation.read",
        "system_sdwan_get_federation_peer"     => "system.sdwan.federation.read",
        "system_sdwan_propose_federation_peer" => "system.sdwan.federation.manage",
        "system_sdwan_accept_federation_peer"  => "system.sdwan.federation.manage",
        "system_sdwan_revoke_federation_peer"  => "system.sdwan.federation.manage",
        "system_sdwan_federation_scan"         => "system.sdwan.federation.read",
        "system_sdwan_update_federation_peer"  => "system.sdwan.federation.manage",
        "system_sdwan_set_data_residency"      => "system.sdwan.federation.manage",
        "system_sdwan_get_audit_log"           => "system.sdwan.federation.read",
        # Phase 3 (Federation & Multi-Site) — SDWAN-first composer skills.
        # Each dispatches to its skill executor (composition-of-services);
        # gated by sdwan.federation.manage since all three stand up
        # federation/multi-site overlay topology.
        "system_sdwan_federation_compose"      => "system.sdwan.federation.manage",
        "system_multi_tenant_isolation"        => "system.sdwan.federation.manage",
        "system_service_discovery_compose"     => "system.sdwan.federation.manage",
        # Slice 9a: routing layer (static subnet routing)
        "system_sdwan_update_peer_lan_subnets"        => "system.sdwan.routing.manage",
        "system_sdwan_set_peer_tags"                  => "system.sdwan.peers.manage",
        "system_sdwan_update_network_routing_mode"    => "system.sdwan.routing.manage",
        "system_sdwan_list_subnet_advertisements"  => "system.sdwan.routing.read",
        "system_sdwan_get_routing_summary"         => "system.sdwan.routing.read",
        # Slice 9b: virtual IPs
        "system_sdwan_create_virtual_ip"           => "system.sdwan.vips.manage",
        "system_sdwan_list_virtual_ips"            => "system.sdwan.vips.read",
        "system_sdwan_get_virtual_ip"              => "system.sdwan.vips.read",
        "system_sdwan_update_virtual_ip"           => "system.sdwan.vips.manage",
        "system_sdwan_delete_virtual_ip"           => "system.sdwan.vips.manage",
        "system_sdwan_failover_virtual_ip"         => "system.sdwan.vips.manage",
        "system_sdwan_list_vip_assignments"        => "system.sdwan.vips.read",
        # Slice 9c: iBGP / FRR control plane
        "system_sdwan_get_account_bgp"             => "system.sdwan.routing.read",
        "system_sdwan_update_account_as_number"       => "system.sdwan.routing.manage",
        "system_sdwan_get_bgp_sessions"            => "system.sdwan.routing.read",
        "system_sdwan_get_bgp_config_for_peer"     => "system.sdwan.routing.read",
        # Slice 9e: route policies
        "system_sdwan_list_route_policies"         => "system.sdwan.route_policies.read",
        "system_sdwan_get_route_policy"            => "system.sdwan.route_policies.read",
        "system_sdwan_create_route_policy"         => "system.sdwan.route_policies.manage",
        "system_sdwan_update_route_policy"         => "system.sdwan.route_policies.manage",
        "system_sdwan_delete_route_policy"         => "system.sdwan.route_policies.manage",
        "system_sdwan_compile_route_policy"        => "system.sdwan.route_policies.read",
        # Slice 7b: hub port mappings (DNAT for v4-only clients)
        "system_sdwan_list_port_mappings"          => "system.sdwan.port_mappings.read",
        "system_sdwan_get_port_mapping"            => "system.sdwan.port_mappings.read",
        "system_sdwan_create_port_mapping"         => "system.sdwan.port_mappings.manage",
        "system_sdwan_update_port_mapping"         => "system.sdwan.port_mappings.manage",
        "system_sdwan_delete_port_mapping"         => "system.sdwan.port_mappings.manage",
        # Phase O6 — host bridges (O1) + OVN deployment/switches/ports (O3) + IPFIX (O5)
        "system_sdwan_create_host_bridge"          => "system.sdwan.host_bridges.manage",
        "system_sdwan_list_host_bridges"           => "system.sdwan.host_bridges.read",
        "system_sdwan_get_host_bridge"             => "system.sdwan.host_bridges.read",
        "system_sdwan_activate_host_bridge"        => "system.sdwan.host_bridges.manage",
        "system_sdwan_release_host_bridge"         => "system.sdwan.host_bridges.manage",
        "system_sdwan_create_ovn_deployment"       => "system.sdwan.ovn.manage",
        "system_sdwan_create_ovn_logical_switch"   => "system.sdwan.ovn.manage",
        "system_sdwan_create_ovn_logical_switch_port" => "system.sdwan.ovn.manage",
        "system_sdwan_activate_ovn_logical_switch"      => "system.sdwan.ovn.manage",
        "system_sdwan_activate_ovn_logical_switch_port" => "system.sdwan.ovn.manage",
        "system_sdwan_compile_ovn_plan"            => "system.sdwan.ovn.read",
        "system_sdwan_create_ipfix_collector"      => "system.sdwan.ipfix.manage",
        "system_sdwan_list_ipfix_collectors"       => "system.sdwan.ipfix.read",
        "system_sdwan_get_ipfix_collector"         => "system.sdwan.ipfix.read",
        "system_sdwan_update_ipfix_collector"      => "system.sdwan.ipfix.manage",
        "system_sdwan_delete_ipfix_collector"      => "system.sdwan.ipfix.manage",
        # Phase O6 follow-up — OVN ACLs (multi-tenant isolation)
        "system_sdwan_create_ovn_acl"              => "system.sdwan.ovn.manage",
        "system_sdwan_list_ovn_acls"               => "system.sdwan.ovn.read",
        "system_sdwan_delete_ovn_acl"              => "system.sdwan.ovn.manage",
        "system_sdwan_delete_ovn_logical_switch"   => "system.sdwan.ovn.manage",
        "system_sdwan_delete_ovn_deployment"       => "system.sdwan.ovn.manage",
        # F8-06 — read/prune symmetry for the OVN topology surface.
        "system_sdwan_list_ovn_deployments"        => "system.sdwan.ovn.read",
        "system_sdwan_get_ovn_deployment"          => "system.sdwan.ovn.read",
        "system_sdwan_list_ovn_logical_switches"   => "system.sdwan.ovn.read",
        "system_sdwan_delete_ovn_logical_switch_port" => "system.sdwan.ovn.manage"
      }.freeze

      # APO-1a (IMP-1e58753b3b6c) — governance declarations for every action
      # this tool advertises. NON-ENFORCING: `mutating:` alone leaves
      # BaseTool#gated_action? false, so #execute still routes to #call and
      # behaviour is unchanged. Gate wiring (categories/executors) is APO-1e.
      declare_action "system_multi_tenant_isolation", mutating: true
      declare_action "system_sdwan_accept_federation_peer", mutating: true
      declare_action "system_sdwan_activate_host_bridge", mutating: true
      declare_action "system_sdwan_activate_ovn_logical_switch", mutating: true
      declare_action "system_sdwan_activate_ovn_logical_switch_port", mutating: true
      declare_action "system_sdwan_attach_peer", mutating: true
      declare_action "system_sdwan_compile_ovn_plan", mutating: false
      declare_action "system_sdwan_compile_route_policy", mutating: false
      declare_action "system_sdwan_create_access_grant", mutating: true
      declare_action "system_sdwan_create_firewall_rule", mutating: true
      declare_action "system_sdwan_create_host_bridge", mutating: true
      declare_action "system_sdwan_create_ipfix_collector", mutating: true
      declare_action "system_sdwan_create_network", mutating: true
      declare_action "system_sdwan_create_ovn_acl", mutating: true
      declare_action "system_sdwan_create_ovn_deployment", mutating: true
      declare_action "system_sdwan_create_ovn_logical_switch", mutating: true
      declare_action "system_sdwan_create_ovn_logical_switch_port", mutating: true
      declare_action "system_sdwan_create_port_mapping", mutating: true
      declare_action "system_sdwan_create_route_policy", mutating: true
      declare_action "system_sdwan_create_virtual_ip", mutating: true
      declare_action "system_sdwan_delete_firewall_rule", mutating: true
      declare_action "system_sdwan_delete_ipfix_collector", mutating: true
      declare_action "system_sdwan_delete_network", mutating: true
      declare_action "system_sdwan_delete_ovn_acl", mutating: true
      declare_action "system_sdwan_delete_ovn_deployment", mutating: true
      declare_action "system_sdwan_delete_ovn_logical_switch", mutating: true
      declare_action "system_sdwan_delete_ovn_logical_switch_port", mutating: true
      declare_action "system_sdwan_delete_port_mapping", mutating: true
      declare_action "system_sdwan_delete_route_policy", mutating: true
      declare_action "system_sdwan_delete_virtual_ip", mutating: true
      declare_action "system_sdwan_detach_peer", mutating: true
      declare_action "system_sdwan_failover_virtual_ip", mutating: true
      declare_action "system_sdwan_federation_compose", mutating: true
      declare_action "system_sdwan_federation_scan", mutating: false
      declare_action "system_sdwan_get_account_bgp", mutating: false
      declare_action "system_sdwan_get_audit_log", mutating: false
      declare_action "system_sdwan_get_bgp_config_for_peer", mutating: false
      declare_action "system_sdwan_get_bgp_sessions", mutating: false
      declare_action "system_sdwan_get_federation_peer", mutating: false
      declare_action "system_sdwan_get_firewall_rule", mutating: false
      declare_action "system_sdwan_get_host_bridge", mutating: false
      declare_action "system_sdwan_get_ipfix_collector", mutating: false
      declare_action "system_sdwan_get_network", mutating: false
      declare_action "system_sdwan_get_ovn_deployment", mutating: false
      declare_action "system_sdwan_get_peer", mutating: false
      declare_action "system_sdwan_get_port_mapping", mutating: false
      declare_action "system_sdwan_get_route_policy", mutating: false
      declare_action "system_sdwan_get_routing_summary", mutating: false
      declare_action "system_sdwan_get_topology", mutating: false
      declare_action "system_sdwan_get_virtual_ip", mutating: false
      declare_action "system_sdwan_issue_user_device", mutating: true
      declare_action "system_sdwan_list_access_grants", mutating: false
      declare_action "system_sdwan_list_federation_peers", mutating: false
      declare_action "system_sdwan_list_firewall_rules", mutating: false
      declare_action "system_sdwan_list_host_bridges", mutating: false
      declare_action "system_sdwan_list_ipfix_collectors", mutating: false
      declare_action "system_sdwan_list_networks", mutating: false
      declare_action "system_sdwan_list_ovn_acls", mutating: false
      declare_action "system_sdwan_list_ovn_deployments", mutating: false
      declare_action "system_sdwan_list_ovn_logical_switches", mutating: false
      declare_action "system_sdwan_list_peers", mutating: false
      declare_action "system_sdwan_list_port_mappings", mutating: false
      declare_action "system_sdwan_list_route_policies", mutating: false
      declare_action "system_sdwan_list_subnet_advertisements", mutating: false
      declare_action "system_sdwan_list_user_devices", mutating: false
      declare_action "system_sdwan_list_vip_assignments", mutating: false
      declare_action "system_sdwan_list_virtual_ips", mutating: false
      declare_action "system_sdwan_propose_federation_peer", mutating: true
      declare_action "system_sdwan_release_host_bridge", mutating: true
      declare_action "system_sdwan_revoke_access_grant", mutating: true
      declare_action "system_sdwan_revoke_federation_peer", mutating: true
      declare_action "system_sdwan_revoke_user_device", mutating: true
      declare_action "system_sdwan_set_data_residency", mutating: true
      declare_action "system_sdwan_set_peer_tags", mutating: true
      declare_action "system_sdwan_update_account_as_number", mutating: true
      declare_action "system_sdwan_update_federation_peer", mutating: true
      declare_action "system_sdwan_update_firewall_rule", mutating: true
      declare_action "system_sdwan_update_ipfix_collector", mutating: true
      declare_action "system_sdwan_update_network", mutating: true
      declare_action "system_sdwan_update_network_routing_mode", mutating: true
      declare_action "system_sdwan_update_peer", mutating: true
      declare_action "system_sdwan_update_peer_lan_subnets", mutating: true
      declare_action "system_sdwan_update_port_mapping", mutating: true
      declare_action "system_sdwan_update_route_policy", mutating: true
      declare_action "system_sdwan_update_virtual_ip", mutating: true
      declare_action "system_service_discovery_compose", mutating: true

      def self.definition
        {
          name: "sdwan",
          description: "SDWAN overlay operations: networks, peers, topology compilation, firewall rules, key rotation",
          parameters: {
            action: { type: "string", required: true, enum: action_definitions.keys, description: "Action to perform" },
            id: { type: "string", required: false, description: "Resource ID (context-dependent)" },
            network_id: { type: "string", required: false },
            peer_id: { type: "string", required: false },
            firewall_rule_id: { type: "string", required: false },
            node_instance_id: { type: "string", required: false },
            name: { type: "string", required: false },
            description: { type: "string", required: false },
            publicly_reachable: { type: "boolean", required: false },
            endpoint_host: { type: "string", required: false },
            endpoint_port: { type: "integer", required: false },
            listen_port: { type: "integer", required: false },
            priority: { type: "integer", required: false },
            firewall_action: { type: "string", required: false, enum: ::Sdwan::FirewallRule::ACTIONS,
                              description: "accept | drop | reject" },
            direction: { type: "string", required: false, enum: ::Sdwan::FirewallRule::DIRECTIONS,
                        description: "ingress | egress | both" },
            protocol: { type: "string", required: false, enum: ::Sdwan::FirewallRule::PROTOCOLS,
                       description: "any | tcp | udp | icmp6" },
            src_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                     cidr: { type: "string" }, all: { type: "boolean" } } },
            dst_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                     cidr: { type: "string" }, all: { type: "boolean" } } },
            port_from: { type: "integer", required: false },
            port_to: { type: "integer", required: false },
            enabled: { type: "boolean", required: false },
            options: { type: "object", required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_sdwan_list_networks" => {
            description: "List SDWAN networks for the current account",
            parameters: {
              options: { type: "object", required: false, description: "Reserved options hash (currently unused; pass {} or omit)" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_network" => {
            description: "Fetch an SDWAN network by id",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to fetch" } }
          },
          "system_sdwan_create_network" => {
            description: "Create a new SDWAN overlay network. CIDR (/64) is allocated automatically. Approval-gated (sdwan.network_create) — under require_approval this returns pending: true with a deferred_operation_id and the network is created only once an operator approves.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new network" },
              description: { type: "string", required: false, description: "Free-form description of the network's purpose" },
              options: { type: "object", required: false, description: "settings hash (mtu, topology_strategy, ...)" }
            }
          },
          "system_sdwan_update_network" => {
            description: "Update an SDWAN network's name/description/status/settings. Approval-gated (sdwan.network_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network to update" },
              options: { type: "object", required: false, description: "Hash of fields to update: name, description, status, settings (settings must itself be a hash)" }
            }
          },
          "system_sdwan_delete_network" => {
            description: "Delete an SDWAN network and all its peers + keys (destructive) Approval-gated (sdwan.network_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to delete" } }
          },
          "system_sdwan_list_peers" => {
            description: "List peers in an SDWAN network",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose peers to list" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_peer" => {
            description: "Fetch a single peer with its current key + endpoint",
            parameters: { peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to fetch" } }
          },
          "system_sdwan_attach_peer" => {
            description: "Attach a NodeInstance to an SDWAN network (allocates address, generates keypair). Slice 7a: prefer endpoint_host_v6/v4 over the legacy endpoint_host for new hubs.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network to attach the node to" },
              node_instance_id: { type: "string", required: true, description: "UUID of the System::NodeInstance to enroll as a peer" },
              publicly_reachable: { type: "boolean", required: false, description: "Mark this peer as a hub other peers can dial (default false)" },
              endpoint_host: { type: "string", required: false, description: "Legacy single-endpoint field; prefer endpoint_host_v6/v4 for new hubs" },
              endpoint_host_v6: { type: "string", required: false, description: "IPv6 literal or hostname (slice 7a). v6-preferred when both this and endpoint_host_v4 are set." },
              endpoint_host_v4: { type: "string", required: false, description: "IPv4 literal or hostname (slice 7a). Used as fallback if v6 dial fails." },
              endpoint_port: { type: "integer", required: false, description: "UDP port other peers dial this hub on" },
              listen_port: { type: "integer", required: false, description: "WireGuard listen port for this peer (default 51820)" }
            }
          },
          "system_sdwan_update_peer" => {
            description: "Update an existing peer's endpoint, reachability, routing or labels — the same field set PATCH /sdwan/networks/:id/peers/:id accepts. Routed through the autonomy gate as sdwan.peer_update, which is seeded notify_and_proceed: the change applies immediately and notifies, and returns pending: true with a deferred_operation_id only where an operator has tiered the category up to require_approval. NOTE: `publicly_reachable` is the HUB-ELECTION flag — a peer carrying it becomes a hub other peers dial, whose compiled view carries their user devices, and which acts as a BGP route reflector. Setting it on an already-enrolled peer is a topology change, not a label.",
            parameters: {
              peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to update" },
              # Field list derived from the one writable set
              # (Sdwan::Peer::UPDATE_ATTRIBUTES) so the advertised schema, the
              # refusal message, this arm and the REST twin cannot disagree
              # about what is accepted.
              options: { type: "object", required: true, description: "Hash of fields to update: #{peer_update_option_names.join(', ')}. lan_subnets/tags are arrays (empty array clears); capabilities is an object. Omitted fields are left unchanged." }
            }
          },
          "system_sdwan_detach_peer" => {
            description: "Detach a peer (revokes key, removes membership) Approval-gated (sdwan.peer_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to detach" } }
          },
          "system_sdwan_get_topology" => {
            description: "Return the compiled per-peer view for an SDWAN network — what each peer would receive on its next config pull",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to compile topology for" } }
          },
          "system_sdwan_list_firewall_rules" => {
            description: "List firewall rules in an SDWAN network (priority-ordered)",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose firewall rules to list" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_firewall_rule" => {
            description: "Fetch a single firewall rule, including its compiled nft preview",
            parameters: { firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to fetch" } }
          },
          "system_sdwan_create_firewall_rule" => {
            description: "Create a firewall rule. Selectors accept {peer_id|tag|cidr|all} primitives. Port range is optional and only applies to tcp/udp. Approval-gated (sdwan.firewall_rule_create) — under require_approval this returns pending: true with a deferred_operation_id and the rule is written only once an operator approves.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network this rule belongs to" },
              name: { type: "string", required: true, description: "Display name for the firewall rule" },
              firewall_action: { type: "string", required: false, enum: ::Sdwan::FirewallRule::ACTIONS,
                                description: "accept (default) | drop | reject" },
              direction: { type: "string", required: false, enum: ::Sdwan::FirewallRule::DIRECTIONS,
                          description: "ingress | egress | both (default)" },
              protocol: { type: "string", required: false, enum: ::Sdwan::FirewallRule::PROTOCOLS,
                         description: "any (default) | tcp | udp | icmp6" },
              priority: { type: "integer", required: false, description: "Evaluation priority (lower runs first); defaults to the model's default" },
              src_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                             cidr: { type: "string" }, all: { type: "boolean" } },
                              description: "Source match: exactly one of {peer_id|tag|cidr|all}" },
              dst_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                             cidr: { type: "string" }, all: { type: "boolean" } },
                              description: "Destination match: exactly one of {peer_id|tag|cidr|all}" },
              port_from: { type: "integer", required: false, description: "Start of the port range (tcp/udp only; pair with port_to)" },
              port_to:   { type: "integer", required: false, description: "End of the port range (tcp/udp only; pair with port_from)" }
            }
          },
          "system_sdwan_update_firewall_rule" => {
            description: "Update a firewall rule (any field). Pass port_from/port_to as null to clear the port range. Approval-gated (sdwan.firewall_rule_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to update" },
              name: { type: "string", required: false, description: "New display name for the rule" },
              firewall_action: { type: "string", required: false, enum: ::Sdwan::FirewallRule::ACTIONS,
                                description: "accept | drop | reject" },
              direction: { type: "string", required: false, enum: ::Sdwan::FirewallRule::DIRECTIONS,
                          description: "ingress | egress | both" },
              protocol: { type: "string", required: false, enum: ::Sdwan::FirewallRule::PROTOCOLS,
                         description: "any | tcp | udp | icmp6" },
              priority: { type: "integer", required: false, description: "Evaluation priority (lower runs first)" },
              src_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                             cidr: { type: "string" }, all: { type: "boolean" } },
                              description: "Source match: exactly one of {peer_id|tag|cidr|all}" },
              dst_selector: { type: "object", required: false, properties: { peer_id: { type: "string" }, tag: { type: "string" },
                                             cidr: { type: "string" }, all: { type: "boolean" } },
                              description: "Destination match: exactly one of {peer_id|tag|cidr|all}" },
              port_from: { type: "integer", required: false, description: "Start of the port range (tcp/udp only)" },
              port_to:   { type: "integer", required: false, description: "End of the port range (tcp/udp only)" },
              enabled:   { type: "boolean", required: false, description: "Whether the rule is active" }
            }
          },
          "system_sdwan_delete_firewall_rule" => {
            description: "Delete a firewall rule (immediate; takes effect on next agent reconcile) Approval-gated (sdwan.firewall_rule_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to delete" } }
          },
          # Slice 4: user VPN
          "system_sdwan_list_access_grants" => {
            description: "List user access grants on an SDWAN network",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose access grants to list" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_create_access_grant" => {
            description: "Grant a user access to an SDWAN network (precondition for issuing them VPN devices)",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network to grant access to" },
              user_id:    { type: "string", required: true,  description: "UUID of the User (in this account) being granted access" },
              tags:       { type: "array",  required: false, items: { type: "string" },
                                            description: "Optional list of tag strings applied to the grant (used for firewall tag selectors)" }
            }
          },
          "system_sdwan_revoke_access_grant" => {
            description: "Revoke an access grant — cascades to revoke ALL the user's devices on this network. Approval-gated (sdwan.access_grant_revoke) — under require_approval this returns pending: true with a deferred_operation_id and nothing is cut until an operator approves. One-way in practice: access must be re-granted and every device re-issued. To cut a single device instead, use system_sdwan_revoke_user_device.",
            parameters: {
              access_grant_id: { type: "string", required: true, description: "UUID of the SDWAN access grant to revoke" },
              reason:          { type: "string", required: false, description: "Optional human-readable revocation reason (recorded on the grant)" }
            }
          },
          "system_sdwan_list_user_devices" => {
            description: "List a user's VPN devices on an SDWAN network (per access grant)",
            parameters: {
              access_grant_id: { type: "string", required: true, description: "UUID of the SDWAN access grant whose devices to list" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_issue_user_device" => {
            description: "Issue a fresh WireGuard config for a user. Returns a one-shot bootstrap_url (15-min expiry, single-use) — copy it to the user out-of-band. Approval-gated (sdwan.user_device_create) — under require_approval this returns pending: true with a deferred_operation_id; the keypair + token are minted only at approval, and the token is then revealed once in the approval decision response, not here.",
            parameters: {
              access_grant_id: { type: "string", required: true, description: "UUID of the SDWAN access grant the device is issued under" },
              label:           { type: "string", required: true, description: "Operator-supplied device label, e.g. 'phone' or 'work-laptop'" }
            }
          },
          "system_sdwan_revoke_user_device" => {
            description: "Revoke a user device. Approval-gated (system.sdwan_user_device_revoke) — under require_approval this returns pending: true with a deferred_operation_id and the device is cut only once an operator approves. Scoped to the ONE named device: the user's other devices and the access grant are untouched. The hub PULLS its config, so the cut takes effect at its next pull rather than instantly.",
            parameters: {
              user_device_id: { type: "string", required: true, description: "UUID of the SDWAN user device to revoke" },
              reason:         { type: "string", required: false, description: "Optional human-readable revocation reason (recorded on the device)" }
            }
          },
          # Slice 6: federation scaffold (data-only in v1)
          "system_sdwan_list_federation_peers" => {
            description: "List federation peer records (proposed cross-Powernode-instance overlay peerings)",
            parameters: {
              options: { type: "object", required: false, description: "Reserved options hash (currently unused; pass {} or omit)" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_federation_peer" => {
            description: "Fetch a federation peer with its v1-allowed transitions",
            parameters: { federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to fetch" } }
          },
          "system_sdwan_propose_federation_peer" => {
            description: "Propose a new federation peer. Status starts at 'proposed'. Approval-gated (sdwan.federation_peer_propose) — under require_approval this returns pending: true with a deferred_operation_id and no peer row exists until an operator approves. Acceptance-token minting is NOT available on this surface — a tool result reaches the model provider, so the plaintext cannot be delivered here. To obtain the single-use acceptance token for the Phase 11b handshake, the operator proposes over the REST API (POST /api/v1/system/sdwan/federation_peers), which mints by default and reveals the plaintext once in the approval decision response.",
            parameters: {
              remote_instance_url: { type: "string", required: true, description: "Base URL of the remote Powernode instance to peer with" },
              remote_instance_id: { type: "string", required: false, description: "Optional identifier of the remote Powernode instance" },
              remote_account_id: { type: "string", required: false, description: "Optional identifier of the remote account on the peer instance" },
              remote_prefix_advertisement: { type: "string", required: false, description: "/48|/56|/64 ULA prefix the remote instance claims" },
              generate_token: { type: "boolean", required: false, description: "Not supported on this surface — passing true is refused with the operator path to use instead. Omit it to propose the peer." }
            }
          },
          "system_sdwan_accept_federation_peer" => {
            description: "Transition a proposed federation peer to accepted. Approval-gated (sdwan.federation_peer_accept) — under require_approval this returns pending: true with a deferred_operation_id and the peer is accepted only once an operator approves. When the proposing operator generated a single-use acceptance token, pass it as acceptance_token — it is verified (digest match + not expired + single-use) before the request is gated, and again before the transition is written. Performs the status transition only (sets signed_at + audit metadata); it does NOT run the enroll / node-enrollment / SDWAN-attach chain — that is the federation_acceptance skill.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to accept (must be in 'proposed' status)" },
              acceptance_token:   { type: "string", required: false, description: "Single-use token supplied by the proposing-account operator, who obtains it over the REST propose path (POST /api/v1/system/sdwan/federation_peers) — it cannot be minted on this MCP surface. Verified against the stored digest; consumed on success." }
            }
          },
          "system_sdwan_revoke_federation_peer" => {
            description: "Revoke a federation peer (terminal in v1) — cuts cross-instance routing, and federated traffic stops immediately. Approval-gated (sdwan.federation_peer_revoke) — under require_approval this returns pending: true with a deferred_operation_id and nothing is cut until an operator approves. Same category and executor as system_sdwan_update_federation_peer with status 'revoked', so one approval policy covers both routes to a revoked peer on this tool.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to revoke" },
              reason: { type: "string", required: false, description: "Optional human-readable revocation reason (recorded on the peer)" }
            }
          },
          "system_sdwan_federation_scan" => {
            description: "Run the federation governance scanner — flags prefix overlaps and stale-accepted rows",
            parameters: {}
          },
          "system_sdwan_update_federation_peer" => {
            description: "Update a federation peer's mutable fields. When `status` is supplied it is gated by the v1 transition matrix (FederationPeer#can_transition_to?) — disallowed transitions return an error. The two trust-boundary transitions are approval-gated exactly as on the REST surface: status 'accepted' routes through sdwan.federation_peer_accept (a peer carrying an acceptance token digest requires acceptance_token, verified up front) and status 'revoked' routes through sdwan.federation_peer_revoke (reason recorded on the peer); under require_approval these return pending: true with a deferred_operation_id and nothing changes until an operator approves. Other transitions apply inline. Mirrors the FederationPeersController#update permitted keys.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to update" },
              status: { type: "string", required: false, description: "Target status — must be an allowed v1 transition from the current status. 'accepted' and 'revoked' are approval-gated; other transitions apply inline" },
              acceptance_token: { type: "string", required: false, description: "Single-use token from the proposing-account operator — required when transitioning to 'accepted' on a peer that carries an acceptance token digest. Verified before the request is gated; consumed on success." },
              reason: { type: "string", required: false, description: "Human-readable revocation reason, recorded on the peer when transitioning to 'revoked'" },
              remote_instance_url: { type: "string", required: false, description: "Base URL of the remote Powernode instance" },
              remote_instance_id: { type: "string", required: false, description: "Identifier of the remote Powernode instance" },
              remote_account_id: { type: "string", required: false, description: "Identifier of the remote account on the peer instance" },
              remote_prefix_advertisement: { type: "string", required: false, description: "/48|/56|/64 ULA prefix the remote instance claims" },
              signed_at: { type: "string", required: false, description: "ISO8601 timestamp marking when the peering was signed" },
              expires_at: { type: "string", required: false, description: "ISO8601 timestamp marking when the peering expires" },
              metadata: { type: "object", required: false, description: "Free-form metadata hash stored on the peer" }
            }
          },
          "system_sdwan_set_data_residency" => {
            description: "Set a federation peer's data residency region tag (the system_federation_peers.data_residency column, a scalar string ≤64 chars). Used by the residency enforcer to gate which peers may home a given record, so this is a compliance declaration rather than a label. Approval-gated (sdwan.federation_peer_data_residency, seeded require_approval like the propose/accept/revoke trust-boundary verbs) — under require_approval this returns pending: true with a deferred_operation_id and the tag is rewritten only once an operator approves. The applied change is recorded on the peer's own audit trail as a federation.peer.data_residency_changed event, readable through system_sdwan_get_audit_log. Also writable by an operator through PATCH /sdwan/federation_peers/:id, under the same gate.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to tag" },
              data_residency: { type: "string", required: true, description: "Region/residency tag, e.g. 'us-east' or 'eu'" }
            }
          },
          "system_sdwan_get_audit_log" => {
            description: "Read-only audit trail for a federation peer: WORM audit shipments (P9.2 sealed FleetEvent batches) plus recent federation.* FleetEvents pertaining to this peer. The events list is a FILTERED operator view (kind federation.* only); the sealed WORM archive captures ALL events referencing the peer regardless of kind and is the complete compliance record. Secret fields (sealed_path, error_message) are not surfaced.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer whose audit trail to read" },
              limit: { type: "integer", required: false, description: "Max rows per collection (default 50)" }
            }
          },
          # Phase 3 (Federation & Multi-Site) — SDWAN-first composer skills.
          # Each action dispatches to its skill executor (composition of
          # existing SDWAN production services) — see
          # System::Ai::Skills::{SdwanFederationCompose,MultiTenantIsolation,
          # ServiceDiscoveryComposer}Executor.
          "system_sdwan_federation_compose" => {
            description: "Stand up a federation overlay topology (hub-and-spoke OR full-mesh) across instances. Creates one Sdwan::Network, enrolls each member as a peer (hubs publicly_reachable), and compiles the per-peer WireGuard + FRR route-policy envelope (Sdwan::PeerEnroller + TopologyCompiler + RoutePolicyCompiler). Failures are collected, not short-circuited.",
            parameters: {
              network_name: { type: "string", required: true, description: "Display name for the new federation Sdwan::Network" },
              topology: { type: "string", required: true, enum: ::System::Ai::Skills::SdwanFederationComposeExecutor::TOPOLOGIES,
                         description: "hub_and_spoke | full_mesh" },
              peers: { type: "array", required: true, items: { type: "object" },
                      description: "Member descriptors (1-200). Each: {node_instance_id (required), role: 'hub'|'spoke' (hub_and_spoke only; default spoke), endpoint_host_v6, endpoint_host_v4, endpoint_port, listen_port, lan_subnets: [cidr], bgp_route_reflector_client: bool}" },
              routing_protocol: { type: "string", required: false, enum: ::Sdwan::Network::ROUTING_PROTOCOLS,
                                 description: "static (default) | ibgp — 'ibgp' enables FRR route-policy distribution" },
              dry_run: { type: "boolean", required: false, description: "Plan only — no rows persisted" }
            }
          },
          "system_multi_tenant_isolation" => {
            description: "Provision a fully-isolated SDWAN network slice for a single tenant: a dedicated overlay network with its own VRF + isolated iBGP RIB, a non-overlapping /64, default-deny nftables rules scoped to the tenant CIDR, an OVN logical switch, and tenant-CIDR OVN ACLs. SDWAN-native — no k8s NetworkPolicy, no VLAN. Approval-gated.",
            parameters: {
              tenant_key: { type: "string", required: true, description: "Stable slug-safe tenant identifier within the account (names the network/rules/switch/ACLs)" },
              network_name: { type: "string", required: false, description: "Display name for the tenant's Sdwan::Network (defaults to 'tenant-<tenant_key>')" },
              tenant_cidr: { type: "string", required: false, description: "Explicit tenant CIDR; when omitted the auto-allocated /64 is used (recommended)" },
              nb_db_endpoint: { type: "string", required: false, description: "OVN NB DB endpoint (e.g. tcp:127.0.0.1:6641) — required only when the account has no Sdwan::OvnDeployment yet" },
              sb_db_endpoint: { type: "string", required: false, description: "OVN SB DB endpoint (e.g. tcp:127.0.0.1:6642) — required only when the account has no Sdwan::OvnDeployment yet" },
              ovn_switch_name: { type: "string", required: false, description: "Override the OVN logical switch name (defaults to 'ls-tenant-<tenant_key>')" },
              dry_run: { type: "boolean", required: false, description: "Plan only — no rows persisted" }
            }
          },
          "system_service_discovery_compose" => {
            description: "Make a backend service discoverable across the fleet over the SDWAN overlay — provisions a Virtual IP (auto-advertised via iBGP for in-overlay discovery), publishes a VIP-backed federation service-catalog offering, regenerates local Traefik routes, and OPTIONALLY publishes a public DNS record (A/AAAA/CNAME) for internet-facing names. Approval-gated.",
            parameters: {
              service_name: { type: "string", required: true, description: "Human-readable catalog display name" },
              service_slug: { type: "string", required: true, description: "Lowercase-alphanumeric-hyphen slug — the catalog's natural key (also names the VIP)" },
              sdwan_network_id: { type: "string", required: true, description: "SDWAN network the VIP lives in" },
              backend_peer_id: { type: "string", required: true, description: "Sdwan::Peer hosting the service; seated as the VIP's primary holder (iBGP advertiser)" },
              backend_port: { type: "integer", required: true, description: "Port the backend service listens on (advertised in the catalog offering)" },
              vip_cidr: { type: "string", required: true, description: "Operator-supplied host CIDR for the VIP (a /128 v6 or /32 v4) within the network's /64" },
              protocol: { type: "string", required: false, enum: ::System::Federation::ServiceOffering::PROTOCOLS,
                         description: "Service protocol advertised in the catalog: https (default) | http | tcp | tls" },
              grant_scopes: { type: "array", required: false,
                             items: { type: "string", enum: ::System::FederationGrant::SCOPES },
                             description: "Default FederationGrant scopes subscribers receive (subset of read, write, admin, migrate). Defaults to ['read']" },
              grant_ttl_days: { type: "integer", required: false, description: "Default grant TTL in days (>= 7)" },
              traefik_dynamic_dir: { type: "string", required: false, description: "Override for the Traefik dynamic-config directory" },
              public_dns: { type: "object", required: false,
                           properties: {
                             dns_credential_id: { type: "string" },
                             record_name:       { type: "string" },
                             record_type:       { type: "string", enum: ::System::Ai::Skills::ServiceDiscoveryComposerExecutor::DNS_RECORD_TYPES },
                             record_content:    { type: "string" },
                             ttl:               { type: "integer" }
                           },
                           description: "INTERNET-FACING name only: { dns_credential_id, record_name, record_type? (A|AAAA|CNAME), record_content?, ttl? }. Omit for overlay-only discovery." }
            }
          },
          # Slice 9a — routing layer (static subnet routing baseline)
          "system_sdwan_update_peer_lan_subnets" => {
            description: "Declare the external LAN prefixes a peer can route to. In static mode, the topology compiler folds these into AllowedIPs so other peers route across the SDWAN to reach them. CIDR strings (v4 or v6). Approval-gated (sdwan.peer_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer whose LAN subnets to declare" },
              lan_subnets: { type: "array", required: true, items: { type: "string" },
                            description: "Array of CIDR strings. Empty array clears." }
            }
          },
          "system_sdwan_set_peer_tags" => {
            description: "Set the firewall tag labels on a peer. A FirewallRule whose src/dst selector is { \"tag\": \"<label>\" } matches every peer carrying that label (Sdwan::SelectorResolver compiles it to an nft set of their addresses). Replaces the peer's whole tag set; empty array clears it. Approval-gated (sdwan.peer_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to label" },
              tags: { type: "array", required: true, items: { type: "string" },
                     description: "Array of tag label strings (whitespace-trimmed, de-duped). Empty array clears all tags." }
            }
          },
          "system_sdwan_update_network_routing_mode" => {
            description: "Set a network's routing protocol: 'static' (declarative AllowedIPs, no daemon) or 'ibgp' (slice 9c FRR + dynamic distribution). Until slice 9c lands, only 'static' is fully functional. Approval-gated (sdwan.network_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose routing mode to set" },
              routing_protocol: { type: "string", required: true, enum: ::Sdwan::Network::ROUTING_PROTOCOLS,
                                 description: "static | ibgp" }
            }
          },
          "system_sdwan_list_subnet_advertisements" => {
            description: "List route advertisements for a network — declared lan_subnets, VIP announcements (slice 9b), and BGP-learned routes (slice 9c) unified. Filterable by source.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose advertisements to list" },
              source: { type: "string", required: false, enum: ::Sdwan::SubnetAdvertisement::SOURCES,
                       description: "Filter: declared_lan_subnet | virtual_ip | learned_via_bgp | pod_subnet" },
              include_withdrawn: { type: "boolean", required: false, description: "Include withdrawn (inactive) advertisements (default false = active only)" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_routing_summary" => {
            description: "Routing-layer summary for a network: protocol, peer count, advertised prefixes, hub redundancy, BGP session count. Cheap; safe to poll.",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to summarize" } }
          },
          # Slice 9b — Virtual IPs
          "system_sdwan_create_virtual_ip" => {
            description: "Create a Virtual IP. Static mode (anycast=false) = single primary holder + ordered failover. Anycast mode (slice 9c iBGP) = all holders advertise simultaneously. CIDR is typically /32 (v4) or /128 (v6). Approval-gated (sdwan.virtual_ip_create) — under require_approval this returns pending: true with a deferred_operation_id and the VIP is allocated only once an operator approves.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network the Virtual IP lives in" },
              name: { type: "string", required: true, description: "Display name for the Virtual IP" },
              cidr: { type: "string", required: true, description: "Host CIDR for the VIP (typically /32 for v4, /128 for v6) within the network's /64" },
              holder_peer_ids: { type: "array", required: true, items: { type: "string" },
                                description: "Ordered: first entry is primary holder when anycast=false." },
              failover_holder_peer_ids: { type: "array", required: false, items: { type: "string" },
                                         description: "Ordered failover candidates (non-anycast); head is promoted on failover" },
              anycast: { type: "boolean", required: false, description: "When true, all holders advertise simultaneously (slice 9c iBGP); default false" },
              description: { type: "string", required: false, description: "Free-form description of the VIP's purpose" },
              tags: { type: "array", required: false, items: { type: "string" },
                     description: "Optional list of tag strings applied to the VIP" },
              advertised_med: { type: "integer", required: false, description: "BGP MULTI_EXIT_DISC advertised for this VIP (default 0)" },
              advertised_local_pref: { type: "integer", required: false, description: "BGP LOCAL_PREF advertised for this VIP (default 100)" }
            }
          },
          "system_sdwan_list_virtual_ips" => {
            description: "List Virtual IPs in an SDWAN network",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose Virtual IPs to list" },
              state: { type: "string", required: false, enum: ::Sdwan::VirtualIp::STATES,
                      description: "Filter: pending | active | failing_over | unassigned | error" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_virtual_ip" => {
            description: "Fetch a Virtual IP with its assignment history (last 20 transitions)",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to fetch" } }
          },
          "system_sdwan_update_virtual_ip" => {
            description: "Update a Virtual IP's holders, failover candidates, anycast mode, advertised_med/local_pref, etc. Holder changes are recorded as 'holder_changed' assignment rows. Approval-gated (sdwan.virtual_ip_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to update" },
              holder_peer_ids: { type: "array", required: false, items: { type: "string" },
                                description: "Ordered holder peer UUIDs; first is primary when anycast=false" },
              failover_holder_peer_ids: { type: "array", required: false, items: { type: "string" },
                                         description: "Ordered failover candidate peer UUIDs (non-anycast)" },
              anycast: { type: "boolean", required: false, description: "When true, all holders advertise simultaneously (slice 9c iBGP)" },
              description: { type: "string", required: false, description: "Free-form description of the VIP's purpose" },
              tags: { type: "array", required: false, items: { type: "string" },
                     description: "Optional list of tag strings applied to the VIP" },
              advertised_med: { type: "integer", required: false, description: "BGP MULTI_EXIT_DISC advertised for this VIP" },
              advertised_local_pref: { type: "integer", required: false, description: "BGP LOCAL_PREF advertised for this VIP" }
            }
          },
          "system_sdwan_delete_virtual_ip" => {
            description: "Delete a Virtual IP. Destroys the row and, through the association cascade, its holder-assignment history. Approval-gated (sdwan.virtual_ip_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to delete" } }
          },
          "system_sdwan_failover_virtual_ip" => {
            description: "Manual failover for a non-anycast VIP — promotes the head of failover_holder_peer_ids to holder. Anycast VIPs don't fail over (all holders are active simultaneously). Approval-gated (system.sdwan_vip_failover, the same category as the REST surface) — under require_approval this returns pending: true with a deferred_operation_id and the standby is promoted only once an operator approves.",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to fail over" } }
          },
          "system_sdwan_list_vip_assignments" => {
            description: "Audit-grade history of VIP holder transitions for a Virtual IP",
            parameters: {
              virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP whose assignment history to list" },
              **PAGINATION_PARAMETERS
            }
          },
          # ─── Slice 9c: iBGP routing control plane ──────────────────────
          "system_sdwan_get_account_bgp" => {
            description: "Read the account's iBGP config (AS number, router-id strategy, default local-pref). Returns null if AS not yet allocated.",
            parameters: {}
          },
          "system_sdwan_update_account_as_number" => {
            description: "Allocate the account's private AS number (RFC 6996 4-byte private range). Idempotent — returns existing AccountBgp if already allocated.",
            parameters: {}
          },
          "system_sdwan_get_bgp_sessions" => {
            description: "Live BGP session matrix across all networks (or filtered to one network). Returns observed sessions reported by agents — not desired state.",
            parameters: {
              network_id: { type: "string", required: false, description: "Filter to one network" },
              state: { type: "string", required: false, enum: ::Sdwan::BgpSession::STATES,
                      description: "idle | connect | active | opensent | openconfirm | established" }
            }
          },
          "system_sdwan_get_bgp_config_for_peer" => {
            description: "Compile the full BGP config for one peer including frr.conf text. Useful for debugging routing issues.",
            parameters: { peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to compile BGP config for" } }
          },
          # ─── Slice 9e: route policies ──────────────────────────────────
          "system_sdwan_list_route_policies" => {
            description: "List SDWAN route policies for the current account, optionally filtered by scope/direction.",
            parameters: {
              scope: { type: "string", required: false, enum: ::Sdwan::RoutePolicy::SCOPES,
                      description: "account | network | peer" },
              direction: { type: "string", required: false, enum: ::Sdwan::RoutePolicy::DIRECTIONS,
                          description: "import | export" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_route_policy" => {
            description: "Fetch a route policy by id, including its full statement list.",
            parameters: { route_policy_id: { type: "string", required: true, description: "UUID of the SDWAN route policy to fetch" } }
          },
          "system_sdwan_create_route_policy" => {
            description: "Create a route policy. statements is an ordered list of {match: {...}, action: {...}} objects. Compile output appears in TopologyCompiler#bgp.policies. Approval-gated (sdwan.route_policy_create) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the route policy" },
              scope: { type: "string", required: true, enum: ::Sdwan::RoutePolicy::SCOPES,
                      description: "account | network | peer" },
              direction: { type: "string", required: true, enum: ::Sdwan::RoutePolicy::DIRECTIONS,
                          description: "import | export" },
              statements: { type: "array", required: true, items: { type: "object" },
                           description: "Ordered list of {match,action} hashes" },
              scope_resource_id: { type: "string", required: false, description: "UUID of the scoped resource (network or peer) when scope is 'network' or 'peer'" },
              description: { type: "string", required: false, description: "Free-form description of the policy's intent" },
              enabled: { type: "boolean", required: false, description: "Whether the policy is active and compiled into frr.conf" }
            }
          },
          "system_sdwan_update_route_policy" => {
            description: "Update a route policy's name, scope, statements, or enabled state. Approval-gated (sdwan.route_policy_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              route_policy_id: { type: "string", required: true, description: "UUID of the SDWAN route policy to update" },
              options: { type: "object", required: true, description: "Hash of fields to update: name, description, scope, scope_resource_id, direction, enabled, statements, metadata" }
            }
          },
          "system_sdwan_delete_route_policy" => {
            description: "Delete a route policy. The next agent reconcile removes the corresponding route-map from frr.conf. Approval-gated (sdwan.route_policy_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { route_policy_id: { type: "string", required: true, description: "UUID of the SDWAN route policy to delete" } }
          },
          "system_sdwan_compile_route_policy" => {
            description: "Compile policies in the context of one peer; returns the FRR fragment (prefix-lists, route-maps, neighbor assignments) that would land in that peer's frr.conf. Useful for 'show me what this policy will do' previews.",
            parameters: { peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to compile route policies for" } }
          },
          # ─── Slice 7b: hub port mappings ──────────────────────────────────
          "system_sdwan_list_port_mappings" => {
            description: "List hub DNAT port mappings for a network. Optionally filter by hub_peer_id.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose port mappings to list" },
              hub_peer_id: { type: "string", required: false, description: "Optional UUID of the hub peer to filter mappings by" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_port_mapping" => {
            description: "Fetch a port mapping by id.",
            parameters: { port_mapping_id: { type: "string", required: true, description: "UUID of the SDWAN port mapping to fetch" } }
          },
          "system_sdwan_create_port_mapping" => {
            description: "Create a hub DNAT mapping. Exactly one of target_peer_id or target_virtual_ip_id must be set. The hub peer must be in the same network as the target.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network the mapping belongs to" },
              hub_peer_id: { type: "string", required: true, description: "UUID of the hub peer that listens for and DNATs the traffic" },
              name: { type: "string", required: true, description: "Display name for the port mapping" },
              listen_port: { type: "integer", required: true, description: "Port the hub listens on for inbound traffic" },
              protocol: { type: "string", required: true, enum: ::Sdwan::PortMapping::PROTOCOLS,
                         description: "tcp | udp" },
              target_peer_id: { type: "string", required: false, description: "UUID of the target peer to DNAT to (mutually exclusive with target_virtual_ip_id)" },
              target_virtual_ip_id: { type: "string", required: false, description: "UUID of the target virtual IP to DNAT to (mutually exclusive with target_peer_id)" },
              target_port: { type: "integer", required: false, description: "Defaults to listen_port if omitted" },
              description: { type: "string", required: false, description: "Free-form description of the mapping" },
              enabled: { type: "boolean", required: false, description: "Whether the mapping is active (default true)" },
              metadata: { type: "object", required: false, description: "Free-form operator metadata stored on the mapping" },
              rate_limit: { type: "integer", required: false, description: "Hardened DNAT tier (increment 6): max NEW CONNECTIONS per second (conntrack flows — the nat chain only sees each connection's first packet, so this throttles connection-establishment rate, not request/packet throughput). Omit for unrestricted (default)." },
              max_connections: { type: "integer", required: false, description: "Hardened DNAT tier (increment 6): max concurrent connections before excess are dropped. Omit for unrestricted (default)." },
              source_cidrs: { type: "array", required: false, items: { type: "string" },
                             description: "Hardened DNAT tier (increment 6): allow-list of source CIDR strings (v4 and/or v6). Traffic from any other source is dropped. Omit/empty for unrestricted (default)." }
            }
          },
          "system_sdwan_update_port_mapping" => {
            description: "Update a port mapping's name, target, hub peer, ports, protocol, enabled state, or hardening (rate_limit/max_connections/source_cidrs). Approval-gated (sdwan.port_mapping_update) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: {
              port_mapping_id: { type: "string", required: true, description: "UUID of the SDWAN port mapping to update" },
              # Field list derived from the one writable set (IMP-2c531ddb5a0c)
              # so the advertised schema, the refusal message and the arm's
              # own slice cannot disagree about what is accepted.
              options: { type: "object", required: true, description: "Hash of fields to update: #{port_mapping_option_names.join(', ')}. Pass rate_limit/max_connections as null or source_cidrs as [] to clear back to unrestricted." }
            }
          },
          "system_sdwan_delete_port_mapping" => {
            description: "Delete a port mapping. Agent removes the corresponding nft DNAT rule on next reconcile. Approval-gated (sdwan.port_mapping_delete) — under require_approval this returns pending: true with a deferred_operation_id and the change is applied only once an operator approves.",
            parameters: { port_mapping_id: { type: "string", required: true, description: "UUID of the SDWAN port mapping to delete" } }
          },
          # ─── Phase O6 — host bridges (O1) ──────────────────────────────────
          "system_sdwan_create_host_bridge" => {
            description: "Allocate a HostBridge for a NodeInstance via Sdwan::HostBridgeAllocator. Idempotent — returns the existing bridge of the requested kind on this host if one already exists. When `kind` is omitted the allocator picks 'ovs' for heavyweight hosts and 'linux' for lightweight hosts based on the host's network_profile.",
            parameters: {
              node_instance_id: { type: "string", required: true, description: "UUID of the System::NodeInstance (host) to allocate a bridge on" },
              kind: { type: "string", required: false, enum: ::Sdwan::HostBridge::KINDS,
                     description: "linux | ovs (defaults to host's network_profile mapping)" }
            }
          },
          "system_sdwan_activate_host_bridge" => {
            description: "Mark a HostBridge as `active` so the topology compiler picks it up. Newly allocated bridges land in `pending`; the resolver only sees active bridges. Use this after create_host_bridge when the agent isn't yet reporting back its applied state.",
            parameters: {
              id: { type: "string", required: true, description: "Sdwan::HostBridge id" }
            }
          },
          "system_sdwan_release_host_bridge" => {
            description: "Release a HostBridge via Sdwan::HostBridgeAllocator.release!. DEFAULTS TO DRAINING: the bridge moves to `draining`, stays in the compiler's `compilable` set and keeps its short_id reserved so in-flight taps finish cleanly. Pass `force: true` to skip that grace window and mark the bridge `removed` immediately — the compiler stops emitting it at once and anything mid-provision against it loses its bridge name. The REST twin (DELETE /api/v1/system/sdwan/host_bridges/:id) carries the same default and the same opt-in. Approval-gated (sdwan.host_bridge_delete) — under require_approval this returns pending: true with a deferred_operation_id and the release happens only once an operator approves.",
            parameters: {
              id: { type: "string", required: true, description: "Sdwan::HostBridge id" },
              force: { type: "boolean", required: false, description: "When true, skip the draining grace window and mark removed immediately (default false)" }
            }
          },
          "system_sdwan_list_host_bridges" => {
            description: "List HostBridges for the current account. Optionally filter by node_instance_id.",
            parameters: {
              node_instance_id: { type: "string", required: false, description: "Optional UUID of the System::NodeInstance (host) to filter bridges by" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_host_bridge" => {
            description: "Fetch a single HostBridge by id, including its lifecycle timestamps. Use this before activate/release rather than paging the whole account list — `state` is what those two verbs turn on (`pending` is invisible to the compiler; `draining` is already on its way out).",
            parameters: {
              id: { type: "string", required: true, description: "Sdwan::HostBridge id" }
            }
          },
          # ─── Phase O6 — OVN deployment + switches + ports + plan (O3) ──────
          "system_sdwan_create_ovn_deployment" => {
            description: "Create the per-account OVN control-plane deployment. One OvnDeployment per account (DB-enforced). Endpoints use OVN's standard `tcp:HOST:PORT` / `ssl:HOST:PORT` / `unix:PATH` form (defaults: NB 6641, SB 6642).",
            parameters: {
              nb_db_endpoint: { type: "string", required: true, description: "OVN Northbound DB endpoint, e.g. tcp:nb.example:6641" },
              sb_db_endpoint: { type: "string", required: true, description: "OVN Southbound DB endpoint, e.g. tcp:sb.example:6642" },
              northd_host: { type: "string", required: false, description: "Hostname (advisory) of the host running ovn-northd" },
              settings: { type: "object", required: false, description: "Free-form settings hash" }
            }
          },
          "system_sdwan_create_ovn_logical_switch" => {
            description: "Create an OVN logical L2 switch under a deployment. Name is unique per deployment, max 63 chars, [letters/digits/_/-/.] only.",
            parameters: {
              deployment_id: { type: "string", required: true, description: "UUID of the Sdwan::OvnDeployment this switch belongs to" },
              name: { type: "string", required: true, description: "Switch name (unique per deployment, max 63 chars, [letters/digits/_/-/.] only)" },
              cidr: { type: "string", required: false, description: "Optional subnet CIDR (sets up DHCP on the switch when present)" },
              description: { type: "string", required: false, description: "Free-form description of the logical switch" },
              settings: { type: "object", required: false, description: "Free-form settings hash for the logical switch" }
            }
          },
          "system_sdwan_create_ovn_logical_switch_port" => {
            description: "Create an OVN logical switch port. `kind` drives compiler choices: vm | container = host-backed (host_node_instance_id required for proper placement); external = uplink/transit (no host required, gets lsp-set-type localnet by default). MAC is auto-generated (locally-administered `02:` prefix) when blank.",
            parameters: {
              logical_switch_id: { type: "string", required: true, description: "UUID of the Sdwan::OvnLogicalSwitch this port attaches to" },
              name: { type: "string", required: true, description: "Port name (unique per switch)" },
              kind: { type: "string", required: true, enum: ::Sdwan::OvnLogicalSwitchPort::KINDS,
                     description: "vm | container | external" },
              host_node_instance_id: { type: "string", required: false, description: "Required for vm/container ports; ignored for external" },
              addresses: { type: "array", required: false, items: { type: "string" },
                          description: "Array of IPv4/IPv6 strings; appended to the OVN `addresses=` line" },
              mac: { type: "string", required: false, description: "MAC in `xx:xx:xx:xx:xx:xx` form; auto-generated when blank" }
            }
          },
          "system_sdwan_activate_ovn_logical_switch" => {
            description: "Mark an OvnLogicalSwitch as `active` so the compiler's `compilable` scope picks it up. Newly created switches land in `pending`; without activation `system_sdwan_compile_ovn_plan` silently omits them (and their ports/ACLs) with zero errors. Use this after create_ovn_logical_switch when the agent isn't yet reporting back its applied state.",
            parameters: {
              logical_switch_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitch id" }
            }
          },
          "system_sdwan_activate_ovn_logical_switch_port" => {
            description: "Mark an OvnLogicalSwitchPort as `active` so the compiler's `compilable` scope picks it up. Newly created ports land in `pending`; without activation they're excluded from the compiled plan even when their parent switch is active. Use this after create_ovn_logical_switch_port when the agent isn't yet reporting back its applied state.",
            parameters: {
              port_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitchPort id" }
            }
          },
          "system_sdwan_compile_ovn_plan" => {
            description: "Compile the structured ovn-nbctl command plan for an OvnDeployment via Sdwan::OvnCompiler. Returns the full plan (deployment_id, plan: array of {cmd, args}, compiled_at). The compiler does NOT execute — it returns the plan as data for an executor or operator to replay against the NB DB.",
            parameters: {
              deployment_id: { type: "string", required: true, description: "UUID of the Sdwan::OvnDeployment to compile a plan for" }
            }
          },
          # ─── Phase O6 — IPFIX collectors (O5) ──────────────────────────────
          "system_sdwan_create_ipfix_collector" => {
            description: "Create an IPFIX collector for the current account. When an active collector exists, the topology compiler stamps an `ipfix:` block on every ovs-kind HostBridge in the per-host payload. Linux-bridge hosts ignore IPFIX (no native OVS support).",
            parameters: {
              name: { type: "string", required: true, description: "Operator-chosen label (unique per account)" },
              host: { type: "string", required: true, description: "Hostname or IP literal of the IPFIX collector" },
              port: { type: "integer", required: false, description: "UDP port (default 4739, the IANA-assigned IPFIX port)" },
              sampling_rate: { type: "integer", required: false, description: "1-in-N packet sampling (default 1 = sample every packet)" }
            }
          },
          "system_sdwan_list_ipfix_collectors" => {
            description: "List IPFIX collectors for the current account.",
            parameters: { **PAGINATION_PARAMETERS }
          },
          "system_sdwan_get_ipfix_collector" => {
            description: "Fetch one IPFIX collector, including `is_winning_collector` — the compiler stamps only ONE collector onto the account's OVS bridges (the oldest active row), so a fleet may hold several while exactly one exports.",
            parameters: {
              collector_id: { type: "string", required: true, description: "Sdwan::IpfixCollector id" }
            }
          },
          "system_sdwan_update_ipfix_collector" => {
            description: "Enable or disable an IPFIX collector. THIS is how you stop a collector exporting — use it rather than system_sdwan_delete_ipfix_collector, which additionally destroys every flow sample recorded against the collector. Disabling keeps the row and its samples and only drops the ipfix: block from the next topology compile. Approval-gated (sdwan.ipfix_collector_update) — under require_approval this returns pending: true with a deferred_operation_id and the transition is applied only once an operator approves.",
            parameters: {
              collector_id: { type: "string", required: true, description: "Sdwan::IpfixCollector id" },
              state: { type: "string", required: true, enum: ::Sdwan::IpfixCollector::STATES,
                      description: "active | disabled" }
            }
          },
          # ─── Phase O6 follow-up — OVN ACLs ──────────────────────────────
          "system_sdwan_create_ovn_acl" => {
            description: "Create an OVN ACL (firewall rule) on a logical switch. ACLs operate at the intra-host / logical-network scope (compiled to OVS OpenFlow via OVN's logical-flow translation) — distinct from SDWAN nftables firewall rules which operate at inter-peer scope. Heavyweight-profile only in effect.",
            parameters: {
              logical_switch_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitch id this ACL applies to" },
              name: { type: "string", required: true, description: "Operator-chosen name (unique per switch, max 63 chars, [letters/digits/_/-/.] only)" },
              direction: { type: "string", required: true, enum: ::Sdwan::OvnAcl::DIRECTIONS,
                          description: "from-lport (egress from source pod/VM) | to-lport (ingress to destination)" },
              priority: { type: "integer", required: false, description: "0-32767, higher first; default 1000. Ties broken by lexicographic match-string order." },
              match: { type: "string", required: true, description: "OVN match expression, e.g. `ip4.src == 10.0.0.0/8 && tcp.dst == 5432`. Raw OVN syntax — OVN's parser rejects bad values at apply time." },
              acl_action: { type: "string", required: true, enum: ::Sdwan::OvnAcl::ACTIONS,
                           description: "allow | drop | reject | allow-related" }
            }
          },
          "system_sdwan_list_ovn_acls" => {
            description: "List OVN ACLs for the current account, one page at a time, highest priority first. Optionally filter by logical_switch_id (per-switch scope) or sdwan_ovn_deployment_id (per-deployment scope). With no filter, pages through ACLs across every switch in every deployment; read count and has_more to tell a complete answer from a truncated one. ACLs of every state are listed, and at equal priority this order is the UUIDv7 id, NOT the compiler's name tiebreak — use system_sdwan_compile_ovn_plan for OVN evaluation order.",
            parameters: {
              logical_switch_id: { type: "string", required: false, description: "Restrict to ACLs on this switch" },
              sdwan_ovn_deployment_id: { type: "string", required: false, description: "Restrict to ACLs on switches under this deployment" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_delete_ovn_acl" => {
            description: "Delete an OVN ACL. Effect: ACL row destroyed and excluded from next OVN compile; northbound database reapplies on next reconcile.",
            parameters: { acl_id: { type: "string", required: true, description: "Sdwan::OvnAcl id" } }
          },
          "system_sdwan_delete_ovn_logical_switch" => {
            description: "Delete an OVN logical switch. Cascades attached logical switch ports and ACLs scoped to the switch.",
            parameters: { logical_switch_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitch id" } }
          },
          "system_sdwan_delete_ovn_deployment" => {
            description: "Decommission an OVN deployment. Cascades logical switches, ports, and ACLs under it. Irreversible.",
            parameters: { deployment_id: { type: "string", required: true, description: "Sdwan::OvnDeployment id" } }
          },
          # F8-06 — read/prune symmetry: rediscover deployment ids after a
          # session restart, and prune a single logical-switch port without
          # tearing down the whole switch.
          "system_sdwan_list_ovn_deployments" => {
            description: "List the account's OVN deployments (id, endpoints, status). Use to rediscover a deployment id when the create response was lost or a session restarted.",
            parameters: {
              status: { type: "string", required: false, enum: ::Sdwan::OvnDeployment::STATES,
                        description: "Optional status filter: pending | bootstrapping | active | degraded" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_get_ovn_deployment" => {
            description: "Fetch one OVN deployment with its logical switches (each switch includes its ports), so an agent can rediscover the full topology and the ids it needs for compile/delete.",
            parameters: { deployment_id: { type: "string", required: true, description: "Sdwan::OvnDeployment id" } }
          },
          "system_sdwan_list_ovn_logical_switches" => {
            description: "List OVN logical switches (optionally scoped to a deployment), each with its ports so port ids are discoverable for system_sdwan_delete_ovn_logical_switch_port.",
            parameters: {
              deployment_id: { type: "string", required: false, description: "Restrict to switches under this Sdwan::OvnDeployment" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_sdwan_delete_ovn_logical_switch_port" => {
            description: "Delete a single OVN logical switch port (prune). Removes the port row + excludes it from the next OVN compile, leaving the switch and its other ports intact.",
            parameters: { port_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitchPort id" } }
          },
          "system_sdwan_delete_ipfix_collector" => {
            description: "Delete an IPFIX collector. Next topology compile drops the ipfix: block from per-host payloads.",
            parameters: { collector_id: { type: "string", required: true, description: "Sdwan::IpfixCollector id" } }
          }
        }
      end

      def self.permitted?(agent:)
        return false unless defined?(::Sdwan)
        super
      end

      protected

      def call(params)
        return error_result("permission denied: #{required_perm_for(params[:action])} required") unless action_permitted?(params[:action])

        case params[:action]
        when "system_sdwan_list_networks"  then list_networks(params)
        when "system_sdwan_get_network"    then get_network(params)
        when "system_sdwan_create_network" then create_network(params)
        when "system_sdwan_update_network" then update_network(params)
        when "system_sdwan_delete_network" then delete_network(params)
        when "system_sdwan_list_peers"     then list_peers(params)
        when "system_sdwan_get_peer"       then get_peer(params)
        when "system_sdwan_attach_peer"    then attach_peer(params)
        when "system_sdwan_update_peer"    then update_peer(params)
        when "system_sdwan_detach_peer"    then detach_peer(params)
        when "system_sdwan_get_topology"   then get_topology(params)
        # Slice 2 firewall actions
        when "system_sdwan_list_firewall_rules"  then list_firewall_rules(params)
        when "system_sdwan_get_firewall_rule"    then get_firewall_rule(params)
        when "system_sdwan_create_firewall_rule" then create_firewall_rule(params)
        when "system_sdwan_update_firewall_rule" then update_firewall_rule(params)
        when "system_sdwan_delete_firewall_rule" then delete_firewall_rule(params)
        # Slice 4 user VPN actions
        when "system_sdwan_list_access_grants"   then list_access_grants(params)
        when "system_sdwan_create_access_grant"  then create_access_grant(params)
        when "system_sdwan_revoke_access_grant"  then revoke_access_grant(params)
        when "system_sdwan_list_user_devices"    then list_user_devices(params)
        when "system_sdwan_issue_user_device"    then issue_user_device(params)
        when "system_sdwan_revoke_user_device"   then revoke_user_device(params)
        # Slice 6 federation actions
        when "system_sdwan_list_federation_peers"   then list_federation_peers(params)
        when "system_sdwan_get_federation_peer"     then get_federation_peer(params)
        when "system_sdwan_propose_federation_peer" then propose_federation_peer(params)
        when "system_sdwan_accept_federation_peer"  then accept_federation_peer(params)
        when "system_sdwan_revoke_federation_peer"  then revoke_federation_peer(params)
        when "system_sdwan_federation_scan"         then federation_scan(params)
        when "system_sdwan_update_federation_peer"  then update_federation_peer(params)
        when "system_sdwan_set_data_residency"      then set_data_residency(params)
        when "system_sdwan_get_audit_log"           then get_audit_log(params)
        # Phase 3 (Federation & Multi-Site) — SDWAN-first composer skills
        when "system_sdwan_federation_compose"      then federation_compose(params)
        when "system_multi_tenant_isolation"        then multi_tenant_isolation(params)
        when "system_service_discovery_compose"     then service_discovery_compose(params)
        # Slice 9a routing actions
        when "system_sdwan_update_peer_lan_subnets"       then set_peer_lan_subnets(params)
        when "system_sdwan_set_peer_tags"                 then set_peer_tags(params)
        when "system_sdwan_update_network_routing_mode"   then set_network_routing_mode(params)
        when "system_sdwan_list_subnet_advertisements" then list_subnet_advertisements(params)
        when "system_sdwan_get_routing_summary"        then get_routing_summary(params)
        # Slice 9c iBGP actions
        when "system_sdwan_get_account_bgp"            then get_account_bgp(params)
        when "system_sdwan_update_account_as_number"     then set_account_as_number(params)
        when "system_sdwan_get_bgp_sessions"           then get_bgp_sessions(params)
        when "system_sdwan_get_bgp_config_for_peer"   then get_bgp_config_for_peer(params)
        # Slice 9e route policies
        when "system_sdwan_list_route_policies"       then list_route_policies(params)
        when "system_sdwan_get_route_policy"          then get_route_policy(params)
        when "system_sdwan_create_route_policy"       then create_route_policy(params)
        when "system_sdwan_update_route_policy"       then update_route_policy(params)
        when "system_sdwan_delete_route_policy"       then delete_route_policy(params)
        when "system_sdwan_compile_route_policy"      then compile_route_policy(params)
        # Slice 7b port mappings
        when "system_sdwan_list_port_mappings"        then list_port_mappings(params)
        when "system_sdwan_get_port_mapping"          then get_port_mapping(params)
        when "system_sdwan_create_port_mapping"       then create_port_mapping(params)
        when "system_sdwan_update_port_mapping"       then update_port_mapping(params)
        when "system_sdwan_delete_port_mapping"       then delete_port_mapping(params)
        # Slice 9b VIP actions
        when "system_sdwan_create_virtual_ip"          then create_virtual_ip(params)
        when "system_sdwan_list_virtual_ips"           then list_virtual_ips(params)
        when "system_sdwan_get_virtual_ip"             then get_virtual_ip(params)
        when "system_sdwan_update_virtual_ip"          then update_virtual_ip(params)
        when "system_sdwan_delete_virtual_ip"          then delete_virtual_ip(params)
        when "system_sdwan_failover_virtual_ip"        then failover_virtual_ip(params)
        when "system_sdwan_list_vip_assignments"       then list_vip_assignments(params)
        # Phase O6 — host bridges (O1) + OVN (O3) + IPFIX (O5)
        when "system_sdwan_create_host_bridge"             then create_host_bridge(params)
        when "system_sdwan_list_host_bridges"              then list_host_bridges(params)
        when "system_sdwan_get_host_bridge"                then get_host_bridge(params)
        when "system_sdwan_activate_host_bridge"           then activate_host_bridge(params)
        when "system_sdwan_release_host_bridge"            then release_host_bridge(params)
        when "system_sdwan_create_ovn_deployment"          then create_ovn_deployment(params)
        when "system_sdwan_create_ovn_logical_switch"      then create_ovn_logical_switch(params)
        when "system_sdwan_create_ovn_logical_switch_port" then create_ovn_logical_switch_port(params)
        when "system_sdwan_activate_ovn_logical_switch"      then activate_ovn_logical_switch(params)
        when "system_sdwan_activate_ovn_logical_switch_port" then activate_ovn_logical_switch_port(params)
        when "system_sdwan_compile_ovn_plan"               then compile_ovn_plan(params)
        when "system_sdwan_create_ovn_acl"                 then create_ovn_acl(params)
        when "system_sdwan_list_ovn_acls"                  then list_ovn_acls(params)
        when "system_sdwan_delete_ovn_acl"                 then delete_ovn_acl(params)
        when "system_sdwan_delete_ovn_logical_switch"      then delete_ovn_logical_switch(params)
        when "system_sdwan_delete_ovn_deployment"          then delete_ovn_deployment(params)
        when "system_sdwan_list_ovn_deployments"           then list_ovn_deployments(params)
        when "system_sdwan_get_ovn_deployment"             then get_ovn_deployment(params)
        when "system_sdwan_list_ovn_logical_switches"      then list_ovn_logical_switches(params)
        when "system_sdwan_delete_ovn_logical_switch_port" then delete_ovn_logical_switch_port(params)
        when "system_sdwan_delete_ipfix_collector"         then delete_ipfix_collector(params)
        when "system_sdwan_create_ipfix_collector"         then create_ipfix_collector(params)
        when "system_sdwan_list_ipfix_collectors"          then list_ipfix_collectors(params)
        when "system_sdwan_get_ipfix_collector"            then get_ipfix_collector(params)
        when "system_sdwan_update_ipfix_collector"         then update_ipfix_collector(params)
        else error_result("Unknown action: #{params[:action]}")
        end
      rescue ::Sdwan::UserDeviceIssuer::GrantError => e
        error_result(e.message)
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      rescue ::Sdwan::PeerEnroller::CrossAccountError => e
        error_result(e.message)
      rescue ::Sdwan::HostBridgeAllocator::CapacityExhausted,
             ::Sdwan::HostBridgeAllocator::InvalidArguments => e
        error_result(e.message)
      end

      private

      # === Permission gating ===
      # Two bypasses, both EXPLICIT (IMP-54bf2643f542, sibling of the
      # SystemFleetTool fix IMP-9030413bc292 — its ladder carries the full note):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — that per-tool grant
      #                        stands in for authorization. It is NAME-scoped
      #                        while this tool runs the action the caller
      #                        supplies, so treat it as provenance, not a fence.
      #
      # This used to be one implicit `@user.nil?` bypass, whose premise — that
      # MCP callers always carry a user — predates instance principals and is
      # false for them, so an instance skipped all 82 per-action permissions.
      # A nil user with neither flag now fails CLOSED.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      # === Approval gate seam ===
      #
      # The one shape every destructive verb on this tool routes through —
      # the MCP twin of ::System::GatedActions#gate! on the REST controllers.
      # Never hand-copy the AutonomyGate plumbing into an action; call this.
      #
      # Contract (mirrors the REST gate! semantics, IMP-322999495307):
      #
      #   * Validate BEFORE calling — account scoping (account_* finders),
      #     transition matrices, and token checks all run first, so a request
      #     that can only ever fail parks no approval an operator has to
      #     dispose of. None of that is enforcement: the executor re-runs the
      #     checks that count when the deferred operation executes.
      #   * The EXECUTOR is the sole writer. On :pending the gate never calls
      #     the proceed block — the action itself must mutate NOTHING, so the
      #     operation survives the approval window and is performed
      #     server-side (constantized at approval) with `executor_params`
      #     replayed verbatim. Key names are each executor's contract.
      #   * `pending_extra` carries the resource serialization for the 202-
      #     shaped response; the block builds the :proceed payload and is only
      #     called after the executor ran synchronously (auto-approve /
      #     notify_and_proceed / core mode), receiving the gate Result — an
      #     executor that mints material revealed exactly once (federation
      #     propose) surfaces it from result.result there.
      #
      # Agent AND user are both forwarded: a seeded agent-scoped
      # require_approval row only matches when the agent is passed
      # (Ai::InterventionPolicy#agent_matches? rejects a scoped row against a
      # nil agent), every other caller falls through to
      # InterventionPolicyService#default_policy (also require_approval), and
      # @agent additionally buys attribution — AutonomyGate#resolve_chain
      # routes to "<agent name> Actions" and to "Manual Operations" when nil.
      # Attribution for the requesting user lands on the DeferredOperation.
      #
      # Ai::AutonomyGate copies executor_params into the ApprovalRequest's
      # request_data through Ai::SensitiveParams.filter, so secret-named keys
      # (acceptance_token, …) reach the approval audience masked while the
      # operation's own params keep the plaintext the executor replays.
      def gated_result(action_category:, executor_class:, executor_params:,
                       description:, source_type: nil, source_id: nil,
                       pending_extra: {})
        result = ::Ai::AutonomyGate.evaluate(
          action_category: action_category,
          executor_class: executor_class,
          params: executor_params,
          account: @account,
          agent: @agent,
          requested_by: @user,
          source_type: source_type,
          source_id: source_id,
          description: description
        )

        case result.decision
        when :proceed
          success_result(**yield(result))
        when :pending
          # THE SHARED BUILDER, not a second spelling of the same body. Two
          # spellings of the pending envelope are what let one parked category
          # answer "pending" through this door and "failed" through the skill
          # executors' (APO-1f, IMP-117b34656921), and only a shared builder
          # keeps a key added to Ai::Tools::BaseTool::PENDING_RESULT_PROPERTIES
          # from silently missing here. `pending_extra` still rides alongside —
          # this is the floor, not the ceiling.
          success_result(
            ::Ai::Tools::BaseTool.pending_payload(
              action_category: action_category,
              deferred_operation: result.deferred_operation,
              approval_request: result.approval_request
            ).merge(pending_extra || {})
          )
        else
          error_result(gate_failure_message(result, action_category))
        end
      end

      # Ai::AutonomyGate rescues StandardError into a :blocked Result, so once
      # an arm's write moves inside its executor EVERY failure the write can
      # raise arrives here flattened to "Gate evaluation failed: <message>" —
      # losing the field-level errors and the FK wording the inline arms used
      # to return. Result carries the original `exception` for exactly this
      # reason; Ai::GatedActions#gate_update! already unwraps it on the REST
      # side, and this is the MCP twin of that, so one wording serves both.
      #
      # A genuine POLICY block carries no exception and falls through to
      # result.error unchanged.
      def gate_failure_message(result, action_category)
        case result.exception
        when ActiveRecord::RecordInvalid
          result.exception.record.errors.full_messages.join("; ")
        when ActiveRecord::InvalidForeignKey
          "FK blocks destroy: #{result.exception.message}"
        when ::Sdwan::HostBridgeAllocator::CapacityExhausted,
             ::Sdwan::HostBridgeAllocator::InvalidArguments,
             ::Sdwan::UserDeviceIssuer::GrantError
          result.exception.message
        else
          result.error || "Action #{action_category} is blocked by policy"
        end
      end

      # Validate-before-gate ceremony shared by every gated update arm
      # (IMP-c9798d9d5671): assign the caller's attributes so the MODEL
      # produces the field errors (one wording with the REST twin), surface
      # them immediately when the update could only ever fail — a doomed
      # change must not park an approval an operator has to dispose of —
      # then restore_attributes (the zero-query equivalent of reload,
      # ActiveModel::Dirty) so nothing reaches the row except through the
      # executor. Returns the error_result to bubble, or nil when the
      # update is gateable. The optional block runs on the VALID path only,
      # before restore — the one window where normalization callbacks
      # (before_validation) have run but the row is untouched, for callers
      # that answer the normalized value without re-reading it later.
      def validation_error_before_gate(record, attrs)
        record.assign_attributes(attrs)
        return error_result(record.errors.full_messages.join("; ")) unless record.valid?

        yield record if block_given?
        record.restore_attributes
        nil
      end

      # === Networks ===

      def list_networks(params)
        scope = ::Sdwan::Network.where(account_id: @account.id)
        paginated_result(:networks, scope, params, sort: :name, direction: :asc) { |n| serialize_network(n) }
      end

      def get_network(params)
        network = account_networks.find(params[:network_id])
        success_result(network: serialize_network_full(network))
      end

      # IMP-051f3811ac60 — routed through Ai::AutonomyGate as
      # sdwan.network_create, matching NetworksController#create. The category
      # was seeded and registered from the start but no gate site named it, so
      # an agent could stand up a new overlay with no policy evaluation while
      # update/delete on the same resource were gated. The candidate is
      # validated BEFORE the gate (a doomed payload parks no approval) and
      # never saved — Sdwan::Executors::CreateNetwork is the sole writer.
      #
      # Internal composition (the provisioning/federation/multi-tenant
      # composers) creates networks directly and stays ungated — the same
      # caller split attach_peer pins in peers_create_gating_spec.
      def create_network(params)
        opts = params[:options]
        attributes = {
          name: params[:name],
          description: params[:description],
          settings: opts.is_a?(Hash) ? opts : {}
        }

        candidate = ::Sdwan::Network.new(attributes.merge(account_id: @account.id))
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateNetwork::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateNetwork",
          executor_params: { attributes: attributes },
          description: "Create SDWAN network '#{params[:name]}'"
        ) do |result|
          network = account_networks.find(result.result&.dig(:data, :network_id))
          { network: serialize_network_full(network) }
        end
      end

      # IMP-2ff1980f7813 — routed through Ai::AutonomyGate as
      # sdwan.network_update, the category NetworksController#update gates over
      # its WHOLE payload (3e0b0a60). This was the last ungated status write on
      # the MCP surface: `status` moves a network between compilable and
      # deny-all for every peer (Sdwan::Network::STATUSES /
      # TopologyCompiler), so an agent refused on the HTTP surface could apply
      # the identical flip here with no DeferredOperation row. The sibling arm
      # set_network_routing_mode already gates on this category; together the
      # two reach a subset of the REST permit list (see the action-category
      # header above for the four fields no MCP arm exposes).
      #
      # No re-parent anchor is needed (NetworksController#update carries the
      # same note): Sdwan::Network is the top of the SDWAN tenancy tree and
      # holds no re-pointable tenancy-bearing FK — account_id is its only
      # tenancy key, and Executors::Base#attrs strips it.
      #
      # `options` is read string-keyed because that is the only live caller
      # shape: McpPlatformToolRegistrar hands the tool a
      # HashWithIndifferentAccess (mcp_platform_tool_registrar.rb).
      def update_network(params)
        network = account_networks.find(params[:network_id])
        opts = params[:options]
        opts = {} unless opts.is_a?(Hash)
        update_attrs = {}
        update_attrs[:name]        = opts["name"]        if opts["name"]
        update_attrs[:description] = opts["description"] if opts["description"]
        update_attrs[:status]      = opts["status"]      if opts["status"]
        update_attrs[:settings]    = opts["settings"]    if opts["settings"].is_a?(Hash)

        # Requested-but-unusable fails LOUD rather than parking a no-op
        # approval (see update_firewall_rule). Replaces the old silent
        # success-over-nothing: an unrecognized payload used to answer 200
        # with the untouched network, which reads as "applied".
        if update_attrs.empty?
          return error_result("no recognized fields to update — permitted (options): name, description, status, settings")
        end

        error = validation_error_before_gate(network, update_attrs)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdateNetwork::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateNetwork",
          executor_params: { network_id: network.id, attributes: update_attrs },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Matches NetworksController#update's gate description.
          description: "Update SDWAN network '#{network.name}'"
        ) { |_result| { network: serialize_network_full(network.reload) } }
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.network_delete, matching NetworksController#destroy. The category,
      # the executor and the seeded policy row all pre-dated this call site;
      # only the call was missing, so an operator who set the tier got it from
      # the console and an unreviewed cascade destroy from the agent.
      def delete_network(params)
        network = account_networks.find(params[:network_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteNetwork::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteNetwork",
          executor_params: { network_id: network.id },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Matches Sdwan::Executors::DeleteNetwork#summarize so the request and
          # the approval card speak one sentence.
          description: "Delete SDWAN network '#{network.name}'"
        ) do |_result|
          { deleted: true, id: network.id }
        end
      end

      # === Peers ===

      def list_peers(params)
        network = account_networks.find(params[:network_id])
        paginated_result(:peers, network.peers.includes(:keys), params, direction: :asc) { |p| serialize_peer(p) }
      end

      def get_peer(params)
        peer = account_peers.find(params[:peer_id])
        success_result(peer: serialize_peer_full(peer))
      end

      # IMP-cf285f21f3a9: routed through Ai::AutonomyGate, matching
      # PeersController#create. This was the second of the two ungated peer
      # creation surfaces — the seeded sdwan.peer_create policy matched no gate
      # call site anywhere, so an agent could attach a node to an overlay
      # without the operator's configured policy being consulted at all, while
      # detach_peer's REST twin has been gated since slice 1.
      #
      # Internal composition (provision_full_stack, federation acceptance,
      # storage auto-enroll, the compose skills) keeps calling
      # Sdwan::PeerEnroller directly and is deliberately NOT gated here.
      def attach_peer(params)
        network = account_networks.find(params[:network_id])
        node_instance = ::System::NodeInstance.joins(:node)
                                              .where(system_nodes: { account_id: @account.id })
                                              .find(params[:node_instance_id])

        attributes = {
          node_instance_id: node_instance.id,
          publicly_reachable: params[:publicly_reachable] || false,
          endpoint_host: params[:endpoint_host],
          endpoint_host_v6: params[:endpoint_host_v6],
          endpoint_host_v4: params[:endpoint_host_v4],
          endpoint_port: params[:endpoint_port],
          listen_port: params[:listen_port] || 51820
        }.compact

        gated_result(
          action_category: ::Sdwan::Executors::CreatePeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreatePeer",
          executor_params: { network_id: network.id, attributes: attributes },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Matches PeersController#create's gate description and
          # CreatePeer#summarize, so all three speak one sentence.
          description: "Add SDWAN peer #{::Sdwan::Peer.operator_label_for(
            node_instance: node_instance,
            network_name: network.name,
            endpoint_display: nil,
            fallback: node_instance.id
          )}"
        ) do |result|
          peer = ::Sdwan::Peer.find(result.result&.dig(:data, :peer_id))
          { attached: true, peer: serialize_peer_full(peer) }
        end
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as sdwan.peer_delete,
      # matching PeersController#destroy. Detaching drops the node off the
      # overlay until it is re-attached; that has been approval-gated on the
      # REST twin since slice 1.
      def detach_peer(params)
        peer = account_peers.find(params[:peer_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeletePeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeletePeer",
          executor_params: { peer_id: peer.id },
          source_type: "Sdwan::Peer",
          source_id: peer.id,
          description: "Delete SDWAN peer #{peer.operator_label}"
        ) do |_result|
          { detached: true, id: peer.id }
        end
      end

      def get_topology(params)
        network = account_networks.find(params[:network_id])
        views = ::Sdwan::TopologyCompiler.compile_for_network(network)
        success_result(
          network_id: network.id,
          cidr_64: network.cidr_64,
          peer_count: views.size,
          peers: views
        )
      end

      # === Firewall Rules ===

      def list_firewall_rules(params)
        network = account_networks.find(params[:network_id])
        paginated_result(:firewall_rules, network.firewall_rules, params,
                         sort: :priority, direction: :asc,
                         network_id: network.id,
                         default_policy: ::Sdwan::FirewallCompiler.new(network).default_policy) { |r| serialize_rule(r) }
      end

      def get_firewall_rule(params)
        rule = account_firewall_rules.find(params[:firewall_rule_id])
        compiler = ::Sdwan::FirewallCompiler.new(rule.network)
        success_result(
          firewall_rule: serialize_rule(rule).merge(
            compiled_preview: compiler.send(:emit_rule, rule)
          )
        )
      end

      # IMP-6c482005db87 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (FirewallRulesController#create): the executor existed with
      # no caller, so the seeded sdwan.firewall_rule_create policy matched
      # nothing this tool did. Sdwan::Executors::CreateFirewallRule performs
      # the write server-side, so it survives the :pending path; this method
      # mutates nothing on either branch.
      #
      # The candidate is validated BEFORE the gate (like
      # accept_federation_peer's up-front checks): a doomed create fails with
      # its field errors immediately rather than parking an approval that can
      # only ever fail. Never saved — the executor's create! stays the
      # authority. Account ownership is enforced HERE by account_networks,
      # the same split the HTTP path uses (set_network guard, executor
      # re-anchors through resolve_scoped).
      def create_firewall_rule(params)
        network = account_networks.find(params[:network_id])
        # IMP-4a5094b22df0: no account_id merge. It existed ONLY to give the
        # approval card an account to scope its network label by, back when
        # Base.preview ran with deferred_operation: nil; the card now anchors on
        # the operation's own account. Sdwan::FirewallRule derives account_id
        # from its network in a before_validation, so the candidate below still
        # validates identically.
        attrs = firewall_rule_attrs(params)

        candidate = network.firewall_rules.new(attrs)
        unless candidate.valid?
          return error_result(candidate.errors.full_messages.join("; "))
        end

        gated_result(
          action_category: ::Sdwan::Executors::CreateFirewallRule::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateFirewallRule",
          executor_params: { network_id: network.id, attributes: attrs },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Matches CreateFirewallRule#summarize so both surfaces of the
          # approval speak one sentence (IMP-3a563becb7d7).
          description: "Add firewall rule '#{candidate.name}' to SDWAN network #{network.name}"
        ) { |result| { firewall_rule: serialize_rule(network.firewall_rules.find(result.result&.dig(:data, :rule_id))) } }
      end

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (FirewallRulesController#update): the update executor
      # gained its REST caller in IMP-0e44cf2fc80b while this arm kept
      # writing inline, so an agent refused on the HTTP surface could apply
      # the identical mutation here. The executor's update! stays the only
      # writer (validation_error_before_gate ceremony). The parked
      # attributes carry :port_range_hash (the model's mass-assignable
      # accessor), same shape the create arm parks.
      def update_firewall_rule(params)
        rule = account_firewall_rules.find(params[:firewall_rule_id])
        attrs = firewall_rule_attrs(params)
        # Requested-but-unusable fails LOUD: a typo'd payload maps to an
        # empty attrs hash, and parking it would open a no-op approval an
        # operator has to dispose of while the caller's intent vanishes.
        if attrs.empty?
          return error_result("no recognized fields to update — permitted: name, priority, firewall_action, direction, protocol, src_selector, dst_selector, enabled, port_from+port_to")
        end
        error = validation_error_before_gate(rule, attrs)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdateFirewallRule::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateFirewallRule",
          executor_params: { rule_id: rule.id, attributes: attrs },
          source_type: "Sdwan::FirewallRule",
          source_id: rule.id,
          # Matches UpdateFirewallRule#summarize so both surfaces of the
          # approval speak one sentence (IMP-3a563becb7d7).
          description: "Update firewall rule '#{rule.name}' on SDWAN network #{rule.network.name}"
        ) { |_result| { firewall_rule: serialize_rule(rule.reload) } }
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.firewall_rule_delete, matching FirewallRulesController#destroy.
      # Create and update on this resource were already gated here; only the
      # destroy — the one that widens what traffic is allowed — was not.
      def delete_firewall_rule(params)
        rule = account_firewall_rules.find(params[:firewall_rule_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteFirewallRule::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteFirewallRule",
          executor_params: { rule_id: rule.id },
          source_type: "Sdwan::FirewallRule",
          source_id: rule.id,
          # Verbatim the REST twin (FirewallRulesController#destroy).
          description: "Delete firewall rule #{rule.try(:name) || rule.id}"
        ) do |_result|
          { deleted: true, id: rule.id }
        end
      end

      # === Helpers ===

      # The ONE params→attributes mapping for firewall rules — update assigns
      # it (assign_attributes), create parks it on the gate for
      # Sdwan::Executors::CreateFirewallRule to replay into create!
      # (IMP-6c482005db87). Guard style is per-key presence: an omitted key
      # leaves the column untouched on update and takes the model default on
      # create. port_from/port_to are re-keyed to :port_range_hash (the
      # model's mass-assignable accessor — the raw column is an int4range a
      # Hash cannot set).
      def firewall_rule_attrs(params)
        attrs = {}
        attrs[:name]         = params[:name]            if params.key?(:name) && params[:name]
        attrs[:priority]     = params[:priority].to_i   if params.key?(:priority) && params[:priority]
        attrs[:action]       = params[:firewall_action] if params.key?(:firewall_action) && params[:firewall_action]
        attrs[:direction]    = params[:direction]       if params.key?(:direction) && params[:direction]
        attrs[:protocol]     = params[:protocol]        if params.key?(:protocol) && params[:protocol]
        attrs[:src_selector] = params[:src_selector]    if params.key?(:src_selector) && !params[:src_selector].nil?
        attrs[:dst_selector] = params[:dst_selector]    if params.key?(:dst_selector) && !params[:dst_selector].nil?
        attrs[:enabled]      = params[:enabled]         if params.key?(:enabled) && !params[:enabled].nil?
        if params[:port_from] && params[:port_to]
          attrs[:port_range_hash] = { from: params[:port_from].to_i, to: params[:port_to].to_i }
        end
        attrs
      end

      def account_firewall_rules
        ::Sdwan::FirewallRule.where(account_id: @account.id)
      end

      # === Access Grants ===

      def list_access_grants(params)
        network = account_networks.find(params[:network_id])
        paginated_result(:grants, network.access_grants.includes(:user, :user_devices), params) { |g| serialize_grant(g) }
      end

      # IMP-343163bf37a4: gated on `sdwan.access_grant_create`, matching
      # AccessGrantsController#create. A grant is unique per (network, user),
      # so this reuses a revoked user's row and clears its revocation — the
      # exact inverse of revoke_access_grant below, which is gated. Both map to
      # the same permission (system.sdwan.user_devices.manage), so leaving this
      # ungated let an agent refused the revoke reach its inverse instead.
      def create_access_grant(params)
        network = account_networks.find(params[:network_id])
        user = ::User.where(account_id: @account.id).find(params[:user_id])

        # A property of the STORED row, not of the request: reusing a revoked
        # grant is the inverse of the approval-gated revoke below, while a
        # fresh grant is additive. Same write either way — only the category,
        # and so the operator's policy tier, differs.
        existing = network.access_grants.find_by(user_id: user.id)
        reactivating = existing&.revoked?
        network_label = network.name.presence || network.id
        common = {
          executor_params: { network_id: network.id, user_id: user.id, tags: params[:tags] },
          source_type: "Sdwan::Network",
          source_id: network.id
        }
        # Spelled out rather than selected into a variable: the coherence guard
        # pairs a literal executor_class: with the category beside it.
        gate = if reactivating
                 {
                   action_category: ::Sdwan::Executors::ReactivateAccessGrant::ACTION_CATEGORY,
                   executor_class: "Sdwan::Executors::ReactivateAccessGrant",
                   description: "Reinstate SDWAN access for #{user.email} on #{network_label}"
                 }
               else
                 {
                   action_category: ::Sdwan::Executors::CreateAccessGrant::ACTION_CATEGORY,
                   executor_class: "Sdwan::Executors::CreateAccessGrant",
                   # Matches the controller's gate description and the
                   # executor's #summarize, so all three speak one sentence.
                   description: "Grant SDWAN access to #{user.email} on #{network_label}"
                 }
               end

        gated_result(**common, **gate) do |result|
          grant = ::Sdwan::AccessGrant.find(result.result&.dig(:data, :grant_id))
          { grant: serialize_grant(grant) }
        end
      end

      # Revoking a grant cuts a user's VPN access AND cascades to every device
      # on it (AccessGrant#revoke! soft-revokes each non-revoked device), so it
      # goes through Ai::AutonomyGate (`sdwan.access_grant_revoke`, seeded
      # require_approval) exactly as AccessGrantsController#revoke does. Both
      # this action and the device-scoped one map to the same required
      # permission (system.sdwan.user_devices.manage), so leaving this ungated
      # would have let an agent refused the narrow device revoke reach for the
      # wide one instead — unapproved, and with no Ai::DeferredOperation row.
      #
      # Sdwan::Executors::RevokeAccessGrant performs the revoke server-side —
      # this method mutates nothing on either branch, so the revoke survives the
      # :pending path. Account ownership is enforced HERE, before the gate, by
      # account_access_grants — the same split the HTTP path uses
      # (set_network/set_grant guard, executor re-resolves from the stored id).
      #
      # The params hash is GRANT-scoped on purpose: the executor's
      # reject_device_scoped_params! guard raises on any device_id, because a
      # grant revoke cascading out of a device-scoped verb would cut a user's
      # whole access. Passing only grant_id/reason keeps this the guard's one
      # legitimate shape, alongside the HTTP caller.
      #
      # No up-front doomed-action check: the one refusable condition inducible
      # from the request — an already-revoked grant — is idempotent
      # (AccessGrant#revoke! is `return if revoked?`), so it cannot park an
      # approval that can only fail. A grant DELETED inside the approval window
      # still raises out of the executor's bang find (reachable via an approved
      # HTTP #destroy under sdwan.access_grant_delete), but that happens AFTER
      # parking, so no pre-check reaches it, and it is recorded:
      # DeferredOperation#execute_now! calls fail!(e) before re-raising.
      def revoke_access_grant(params)
        grant = account_access_grants.find(params[:access_grant_id])

        gated_result(
          action_category: ::Sdwan::Executors::RevokeAccessGrant::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeAccessGrant",
          # grant_id and reason, shared verbatim with
          # AccessGrantsController#revoke. `reason` replaces the `by_user:`
          # this method used to pass to AccessGrant#revoke!, which the model
          # accepts and never persists (there is no revoked_by column) —
          # requester attribution lands on the DeferredOperation instead,
          # where the approver can see it.
          executor_params: { grant_id: grant.id, reason: params[:reason] },
          source_type: "Sdwan::AccessGrant",
          source_id: grant.id,
          description: "Revoke SDWAN access for #{grant.user&.email || grant.id}",
          pending_extra: { grant: serialize_grant(grant) }
        ) { { grant: serialize_grant(grant.reload), revoked: true } }
      end

      # === User Devices ===

      def list_user_devices(params)
        grant = account_access_grants.find(params[:access_grant_id])
        paginated_result(:devices, grant.user_devices, params) { |d| serialize_user_device(d) }
      end

      # IMP-051f3811ac60 — routed through Ai::AutonomyGate as
      # sdwan.user_device_create, matching UserDevicesController#create.
      # Issuing mints a WireGuard keypair + a one-shot bootstrap token serving
      # the full client config, so it is at least as material as the device
      # revoke below, which has been gated all along.
      # Sdwan::Executors::CreateUserDevice delegates to the same
      # UserDeviceIssuer this arm used to call inline; on :proceed the token
      # rides the executor's raw return, so the response shape (bootstrap_url
      # embedding the token) is unchanged. The persisted operation row masks
      # it (SensitiveParams "token" pattern); on the :pending path the mint
      # happens at approval time and the token reaches the approver through
      # the reveal-once slot, exactly as federation propose does.
      #
      # Pre-checks run in front of the gate — an inactive grant or an invalid
      # label refuses fast and parks nothing. Only label errors are read off
      # the candidate: public_key/assigned_address are legitimately absent
      # until the issuer mints them. The issuer re-runs both checks inside the
      # executor, which is the enforcement.
      def issue_user_device(params)
        grant = account_access_grants.find(params[:access_grant_id])
        unless grant.active?
          return error_result("grant #{grant.id} is not active (status=#{grant.status}) — devices can only be issued under an active grant")
        end
        candidate = grant.user_devices.new(label: params[:label])
        candidate.valid?
        if candidate.errors[:label].any?
          return error_result(candidate.errors.full_messages_for(:label).join("; "))
        end

        gated_result(
          action_category: ::Sdwan::Executors::CreateUserDevice::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateUserDevice",
          executor_params: { grant_id: grant.id, label: params[:label] },
          source_type: "Sdwan::AccessGrant",
          source_id: grant.id,
          description: "Issue SDWAN VPN device '#{params[:label]}' for #{grant.user&.email || grant.id}",
          pending_extra: { grant_id: grant.id }
        ) do |result|
          data = result.result&.dig(:data) || {}
          device = grant.user_devices.find(data[:device_id])
          {
            device: serialize_user_device(device),
            bootstrap_url: "/api/v1/system/sdwan/bootstrap/#{data[:bootstrap_token]}",
            expires_at: data[:expires_at]
          }
        end
      end

      # Revoking a device cuts one user's VPN access, so it goes through
      # Ai::AutonomyGate (`system.sdwan_user_device_revoke`, seeded
      # require_approval) exactly as UserDevicesController#revoke does —
      # otherwise an agent holding this tool has a strictly wider capability
      # than the operator performing the same revoke over HTTP, and leaves no
      # Ai::DeferredOperation audit row.
      #
      # Sdwan::Executors::RevokeUserDevice performs the revoke server-side —
      # this method mutates nothing on either branch, so the revoke survives the
      # :pending path. The executor re-resolves the device from the stored
      # grant/device id pair; account ownership is enforced HERE, before the
      # gate, by account_user_devices — the same split the HTTP path uses
      # (set_network/set_grant/set_device guard, executor re-validates pairing).
      #
      # No up-front doomed-action check, unlike accept_federation_peer: the one
      # refusable condition inducible from the request — an already-revoked
      # device — is idempotent (UserDevice#revoke! returns early), so it cannot
      # park an approval that can only fail. A row DELETED during the approval
      # window does still raise out of the executor's two bang finds (reachable
      # via Sdwan::Executors::DeleteAccessGrant's `dependent: :destroy` cascade,
      # or an approved HTTP #destroy under this same category) — but that
      # happens AFTER parking, so no pre-check reaches it, and it is recorded:
      # DeferredOperation#execute_now! calls fail!(e) before re-raising, so the
      # row lands `failed` with the error message. Shared verbatim with the two
      # HTTP device verbs, which dispatch the same executor on the same params.
      def revoke_user_device(params)
        device = account_user_devices.find(params[:user_device_id])

        gated_result(
          action_category: ::Sdwan::Executors::RevokeUserDevice::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeUserDevice",
          # grant_id/device_id, shared with the two HTTP device verbs.
          executor_params: { grant_id: device.sdwan_access_grant_id, device_id: device.id, reason: params[:reason] },
          source_type: "Sdwan::UserDevice",
          source_id: device.id,
          description: "Revoke SDWAN device #{device.label || device.id}",
          pending_extra: { device: serialize_user_device(device) }
        ) { { device: serialize_user_device(device.reload), revoked: true } }
      end

      def account_access_grants
        ::Sdwan::AccessGrant.where(account_id: @account.id)
      end

      def account_user_devices
        ::Sdwan::UserDevice.joins(access_grant: :network)
                           .where(system_sdwan_networks: { account_id: @account.id })
      end

      def serialize_grant(g)
        {
          id: g.id,
          network_id: g.sdwan_network_id,
          user_id: g.user_id,
          user_email: g.user&.email,
          status: g.status,
          tags: g.tags,
          device_count: g.user_devices.size,
          granted_at: g.granted_at&.iso8601,
          revoked_at: g.revoked_at&.iso8601
        }
      end

      def serialize_user_device(d)
        {
          id: d.id,
          access_grant_id: d.sdwan_access_grant_id,
          label: d.label,
          public_key: d.public_key,
          assigned_address: d.assigned_address,
          downloadable: d.downloadable?,
          last_downloaded_at: d.last_downloaded_at&.iso8601,
          last_seen_at: d.last_seen_at&.iso8601,
          revoked_at: d.revoked_at&.iso8601
        }
      end

      # === Federation (Slice 6) ===

      def list_federation_peers(params)
        peers = ::System::FederationPeer.where(account_id: @account.id)
        paginated_result(:federation_peers, peers, params) { |p| serialize_federation_peer(p) }
      end

      def get_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        success_result(federation_peer: serialize_federation_peer(peer))
      end

      # Phase 11b token minting is NOT available on this surface (IMP-3a32dc649043).
      #
      # A tool result does not stop at its caller. Ai::AgentToolBridgeService
      # appends the full result JSON to the conversation as a `role: "tool"`
      # message, which is sent to the model provider on the next iteration of
      # the agent loop; a truncated preview is also carried in tool_calls_log.
      # Ai::SensitiveParams cannot intervene on either (the preview is a String,
      # and #filter returns non-Hash input unchanged). So returning the plaintext
      # acceptance token here transmits signing material off-platform — the
      # absolute prohibition in CLAUDE.md.
      #
      # The refusal is up front, before the row is created, and deliberately not
      # a silent omission: minting the token and withholding it would leave a
      # peer whose only means of acceptance is a secret nobody ever saw.
      # Proposing WITHOUT a token stays fully supported here; the token round
      # trip belongs to the operator API, which renders to an HTTP response
      # rather than into an agent's context.
      #
      # The predicate casts rather than comparing to `true`: MCP arguments arrive
      # from JSON with no boolean coercion anywhere on the path (the bridge
      # parses and stringifies keys; BaseTool only checks required-key presence),
      # and models routinely serialize a boolean argument as the string "true".
      # `== true` would let that through silently — and silently is the one thing
      # this refusal must never be.
      #
      # IMP-2795453255c3 — routed through Ai::AutonomyGate as
      # sdwan.federation_peer_propose, matching FederationPeersController#create.
      # Proposing opens a cross-INSTANCE trust relationship, which is why the
      # REST twin has gated it from the start; this arm called create! inline,
      # so an agent refused at the console stood the same peer up here.
      #
      # The candidate is validated BEFORE the gate and never saved —
      # Sdwan::Executors::ProposeFederationPeer stays the sole writer, so the
      # proposal survives the approval window and is performed server-side.
      #
      # `generate_token: false` is passed EXPLICITLY rather than omitted. The
      # executor mints by default (`attrs[:generate_token] != false`), so
      # forwarding the caller's attributes untouched would start minting a
      # token this surface has already refused to deliver — stranding the peer
      # behind a secret nobody ever saw, which is precisely what the refusal
      # above exists to prevent. It is a CONTROL FLAG, not a column
      # (ProposeFederationPeer::CONTROL_FLAG_KEYS), so it rides in the replayed
      # attributes and never reaches the candidate built here.
      def propose_federation_peer(params)
        if ::ActiveModel::Type::Boolean.new.cast(params[:generate_token])
          return error_result(
            "generate_token is not available over the MCP tool surface: a tool result is forwarded " \
            "to the model provider and persisted with the conversation, so the plaintext acceptance " \
            "token cannot be delivered here without disclosing signing material. Propose the peer " \
            "over the operator API instead — POST /api/v1/system/sdwan/federation_peers mints the " \
            "token by default (Sdwan::Executors::ProposeFederationPeer) and reveals the plaintext " \
            "exactly once in the approval decision response. Proposing without generate_token is " \
            "supported here."
          )
        end

        attributes = {
          remote_instance_url: params[:remote_instance_url],
          remote_instance_id: params[:remote_instance_id],
          remote_account_id: params[:remote_account_id],
          remote_prefix_advertisement: params[:remote_prefix_advertisement]
        }

        candidate = ::System::FederationPeer.new(
          attributes.merge(account_id: @account.id, status: "proposed")
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::ProposeFederationPeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::ProposeFederationPeer",
          executor_params: { attributes: attributes.merge(generate_token: false) },
          # Provenance only, and inert as enforcement: the peer row does not
          # exist yet, so there is nothing to anchor on, and
          # GatedActions#assert_source_within_account! no-ops on an "Account"
          # source (Account answers neither #account_id nor #account). The
          # tenancy that counts comes from the deferred operation, whose
          # account the executor merges. create_route_policy passes the same
          # pair for the same reason; create_network passes none at all.
          source_type: "Account",
          source_id: @account.id,
          description: "Propose federation with #{params[:remote_instance_url]}"
        ) do |result|
          peer = account_federation_peers.find(result.result&.dig(:data, :federation_peer_id))
          { federation_peer: serialize_federation_peer(peer) }
        end
      end

      # IMP-2795453255c3 — routed through Ai::AutonomyGate as
      # sdwan.federation_peer_revoke, matching FederationPeersController#revoke,
      # #destroy and #update(status: "revoked"). This arm called
      # FederationPeer#revoke! inline, and the bypass did not even require
      # leaving this tool: #update_federation_peer with status "revoked" has
      # gated on this exact category since IMP-ca3440a11a9a, so an agent
      # refused there reached the identical terminal state one action name
      # over, with no DeferredOperation and no gate row naming the cause.
      #
      # Sdwan::Executors::RevokeFederationPeer performs the revocation
      # server-side — this method mutates nothing on either branch, so the
      # revocation survives the :pending path. `reason` rides in the replayed
      # params rather than being applied here: the executor is what threads it
      # into revoke!, which stores it as metadata["revocation_reason"], and an
      # audited cause recorded at REQUEST time would outlive a refused
      # approval.
      #
      # No transition check precedes the gate, matching the REST twin: neither
      # #revoke nor #destroy consults V1_TRANSITIONS, and the only refusable
      # condition inducible from the request — an already-revoked peer — is
      # idempotent (FederationPeer#revoke! is `return if status == "revoked"`),
      # so it cannot park a doomed approval. #update_federation_peer keeps its
      # own matrix check because PATCH gates the whole transition table.
      def revoke_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])

        gated_result(
          action_category: ::Sdwan::Executors::RevokeFederationPeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeFederationPeer",
          executor_params: { federation_peer_id: peer.id, reason: params[:reason] },
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Revoke federation peer #{peer.remote_instance_url}",
          pending_extra: { federation_peer: serialize_federation_peer(peer) }
        ) { { federation_peer: serialize_federation_peer(peer.reload), revoked: true } }
      end

      # Accepting completes the cross-instance handshake and starts mutual route
      # advertisement — the same trust weight as the revoke this tool exposes —
      # so it goes through Ai::AutonomyGate (`sdwan.federation_peer_accept`,
      # seeded require_approval for the SDWAN Manager) exactly as
      # FederationPeersController#update does. Sdwan::Executors::AcceptFederationPeer
      # performs the acceptance server-side, so it survives the :pending path.
      #
      # The transition matrix and the token are checked BEFORE the gate so an
      # unacceptable request fails immediately rather than parking an approval
      # request that can only ever fail. Neither check is the enforcement — the
      # executor re-runs both when the deferred operation executes.
      def accept_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])

        unless peer.can_transition_to?("accepted")
          return error_result(
            "peer #{peer.id} is in status=#{peer.status.inspect}; only 'proposed' peers can be accepted (transition matrix: #{::System::FederationPeer::V1_TRANSITIONS[peer.status].inspect})"
          )
        end

        if (token_error = peer.acceptance_token_error(params[:acceptance_token]))
          return error_result(token_error)
        end

        gated_result(
          action_category: ::Sdwan::Executors::AcceptFederationPeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::AcceptFederationPeer",
          # The single-use token has to outlive the approval window to be
          # verified and consumed by the executor, so it is carried on the
          # deferred operation (whose params stay plaintext for the replay);
          # the ApprovalRequest's request_data copy reaches the approval
          # audience with the token masked (Ai::SensitiveParams).
          executor_params: { federation_peer_id: peer.id, acceptance_token: params[:acceptance_token] },
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Accept federation peer #{peer.remote_instance_url}",
          pending_extra: { federation_peer: serialize_federation_peer(peer) }
        ) { { federation_peer: serialize_federation_peer(peer.reload), accepted: true } }
      end

      def federation_scan(_params)
        findings = ::Sdwan::FederationGovernance.scan(account: @account)
        success_result(
          findings: findings,
          finding_count: findings.size,
          severity_summary: findings.group_by { |f| f[:severity] }.transform_values(&:size)
        )
      end

      # Update a federation peer's mutable fields. When status is supplied
      # it is gated by the v1 transition matrix (mirrors
      # FederationPeersController#update) so we never write a partial-state
      # row. Permitted keys match the controller's peer_update_params (no
      # endpoints — that's outside the REST surface). RecordNotFound /
      # RecordInvalid bubble to the dispatch rescue.
      #
      # Two transitions reachable here cross the trust boundary, and both are
      # routed through the approval gate exactly as the REST twin routes them
      # (FederationPeersController#update → gated_accept!/gated_revoke!):
      #
      #   accepted — EXTENDS trust: completes the handshake that starts
      #     mutual route advertisement with a remote instance.
      #   revoked  — WITHDRAWS it: cuts cross-instance routing, and is the
      #     transition whose cause has to be audited. V1_TRANSITIONS lists
      #     "revoked" from every non-terminal state, so this update reaches
      #     the same state change as system_sdwan_revoke_federation_peer.
      #
      # The bare update! this replaces was the MCP twin of the REST
      # PATCH-status bypass (bc2ef162/e655659f): status:"accepted" completed
      # the handshake with no gate, no signed_at, and without verifying or
      # consuming the Phase 11b single-use acceptance token (it bypassed
      # FederationPeer#accept! entirely); status:"revoked" skipped revoke!,
      # so no revocation_reason was ever recorded. IMP-796bde368789.
      #
      # Suspend/enroll/activate narrow or track an existing link and stay
      # inline, per the REST ruling.
      def update_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])

        if params[:status].present? && !peer.can_transition_to?(params[:status])
          return error_result(
            "peer #{peer.id} is in status=#{peer.status.inspect}; transition to #{params[:status].inspect} is not permitted (transition matrix: #{::System::FederationPeer::V1_TRANSITIONS.fetch(peer.status, []).inspect})"
          )
        end

        update_attrs = {}
        update_attrs[:status]                      = params[:status]                      if params.key?(:status)
        update_attrs[:remote_instance_url]         = params[:remote_instance_url]         if params.key?(:remote_instance_url)
        update_attrs[:remote_instance_id]          = params[:remote_instance_id]          if params.key?(:remote_instance_id)
        update_attrs[:remote_account_id]           = params[:remote_account_id]           if params.key?(:remote_account_id)
        update_attrs[:remote_prefix_advertisement] = params[:remote_prefix_advertisement] if params.key?(:remote_prefix_advertisement)
        update_attrs[:signed_at]                   = params[:signed_at]                   if params.key?(:signed_at)
        update_attrs[:expires_at]                  = params[:expires_at]                  if params.key?(:expires_at)
        update_attrs[:metadata]                    = params[:metadata]                    if params[:metadata].is_a?(Hash)

        case params[:status].to_s
        when "accepted" then return update_gated_accept(peer, params, update_attrs)
        when "revoked"  then return update_gated_revoke(peer, params)
        end

        peer.update!(update_attrs) if update_attrs.any?
        success_result(federation_peer: serialize_federation_peer(peer.reload))
      end

      # The acceptance leg of update_federation_peer. Every field the same
      # update carried rides along to the executor rather than being written
      # ahead of the approval — they are one caller intent, and applying half
      # of it now would let an unapproved caller edit the peer (the executor
      # applies them in one transaction with the acceptance, excluding
      # signed_at, which accept! stamps itself).
      #
      # The token is checked BEFORE the gate, like accept_federation_peer: a
      # doomed accept must fail immediately rather than park an approval
      # request that can only ever fail (on the :pending path the executor
      # runs from Ai::ApprovalRequest#notify_source_of_decision, which rescues
      # and only logs — an operator would approve and never learn the peer
      # stayed proposed). Not enforcement: the executor re-runs accept!'s own
      # verification when the deferred operation executes.
      def update_gated_accept(peer, params, update_attrs)
        if (token_error = peer.acceptance_token_error(params[:acceptance_token]))
          return error_result(
            "#{token_error} — pass acceptance_token (or accept through system_sdwan_accept_federation_peer)"
          )
        end

        gated_result(
          action_category: ::Sdwan::Executors::AcceptFederationPeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::AcceptFederationPeer",
          executor_params: {
            federation_peer_id: peer.id,
            acceptance_token: params[:acceptance_token],
            attributes: update_attrs.except(:status)
          },
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Accept federation peer #{peer.remote_instance_url}",
          pending_extra: { federation_peer: serialize_federation_peer(peer) }
        ) { { federation_peer: serialize_federation_peer(peer.reload) } }
      end

      # The revocation leg of update_federation_peer — same action category
      # and executor as system_sdwan_revoke_federation_peer, so one approval
      # policy and one audit trail cover every route to a revoked peer.
      #
      # Unlike the accept leg, ride-along fields are NOT forwarded: revoked is
      # terminal and the revoke executor applies no attributes, so there is
      # nowhere for them to land. They are ignored rather than refused, the
      # same choice gated_revoke! makes on the REST twin — a form-shaped
      # client resends every field on every update, and refusing that would
      # break a legitimate revocation.
      def update_gated_revoke(peer, params)
        gated_result(
          action_category: ::Sdwan::Executors::RevokeFederationPeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeFederationPeer",
          executor_params: { federation_peer_id: peer.id, reason: params[:reason] },
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Revoke federation peer #{peer.remote_instance_url}",
          pending_extra: { federation_peer: serialize_federation_peer(peer) }
        ) { { federation_peer: serialize_federation_peer(peer.reload) } }
      end

      # Set a federation peer's data residency region tag (scalar
      # system_federation_peers.data_residency column, ≤64 chars).
      #
      # IMP-9bf58a693634 — this was a bare `peer.update!`, and
      # `data_residency` was absent from FederationPeersController's permit
      # list, so a COMPLIANCE field (Federation::ResidencyEnforcer gates
      # cross-boundary record homing on it) was writable only by agents,
      # through no gate, leaving no row naming the change. It now routes
      # through Ai::AutonomyGate on the category its trust-boundary siblings
      # carry, and the REST surface permits the field under the same gate.
      #
      # The gate is what actually CONSTRAINS this write. The
      # ACTION_PERMISSIONS entry above it buys provenance, not protection: an
      # MCP instance principal clears #action_permitted? at its
      # `instance_authorized?` rung before the permission map is consulted at
      # all, and carries no User for #has_permission? to ask.
      def set_data_residency(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        attributes = { data_residency: params[:data_residency] }

        # Validate BEFORE the gate: an over-long tag would otherwise reach the
        # column as a StatementInvalid at APPROVAL time, parking a doomed
        # change for an operator to dispose of (the IMP-785d60f5ec3e oracle).
        if (invalid = validation_error_before_gate(peer, attributes))
          return invalid
        end

        gated_result(
          action_category: ::Sdwan::Executors::SetFederationPeerDataResidency::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::SetFederationPeerDataResidency",
          executor_params: { federation_peer_id: peer.id, attributes: attributes },
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Set data residency for federation peer #{peer.remote_instance_url}",
          pending_extra: { federation_peer: serialize_federation_peer(peer) }
        ) { { federation_peer: serialize_federation_peer(peer.reload) } }
      end

      # Read-only audit trail for a federation peer.
      #
      # audit_shipments: P9.2 WORM shipment rows (sealed FleetEvent batches),
      # newest period first. Only non-secret fields are surfaced — the
      # content-addressable sealed_path and any error_message are withheld.
      #
      # events: federation.* FleetEvents pertaining to this peer. Scoped by
      # account + kind prefix `federation.` + payload->>'federation_peer_id'
      # — the canonical key every federation emitter stamps (same filter
      # Federation::AuditShipmentService#events_for_peer uses). FleetEvent
      # has no direct FK to FederationPeer, so scoping is by that JSON
      # payload field rather than an association.
      def get_audit_log(params)
        peer  = account_federation_peers.find(params[:federation_peer_id])
        limit = (params[:limit] || 50).to_i

        shipments = ::System::FederationAuditShipment
                    .where(federation_peer: peer)
                    .order(period_start: :desc)
                    .limit(limit)

        events = ::System::FleetEvent
                 .where(account_id: peer.account_id)
                 .where("kind LIKE ?", "federation.%")
                 .where("payload->>'federation_peer_id' = ?", peer.id)
                 .recent
                 .limit(limit)

        success_result(
          audit_shipments: shipments.map { |s| serialize_audit_shipment(s) },
          events: events.map { |e| serialize_audit_event(e) }
        )
      end

      # === Phase 3 (Federation & Multi-Site) — SDWAN-first composer skills ===
      #
      # Each MCP action is a thin adapter onto its skill executor. The
      # executors do the composition-of-services work (they validate inputs,
      # audit-log, and run the synchronous sibling/service chain with
      # reverse-order rollback); the tool only threads the operator's params
      # in and maps the executor's {success:, data:/error:} result onto the
      # tool's success_result/error_result contract (the two shapes are
      # identical, so this is a straight pass-through). Invocation is the
      # plain synchronous executor entry point — NOT the async execute_agent
      # path — matching the executor contract.

      def federation_compose(params)
        run_skill_executor(
          ::System::Ai::Skills::SdwanFederationComposeExecutor,
          network_name: params[:network_name],
          topology: params[:topology],
          peers: params[:peers],
          routing_protocol: params[:routing_protocol],
          dry_run: params[:dry_run]
        )
      end

      def multi_tenant_isolation(params)
        run_skill_executor(
          ::System::Ai::Skills::MultiTenantIsolationExecutor,
          tenant_key: params[:tenant_key],
          network_name: params[:network_name],
          tenant_cidr: params[:tenant_cidr],
          nb_db_endpoint: params[:nb_db_endpoint],
          sb_db_endpoint: params[:sb_db_endpoint],
          ovn_switch_name: params[:ovn_switch_name],
          dry_run: params[:dry_run]
        )
      end

      def service_discovery_compose(params)
        run_skill_executor(
          ::System::Ai::Skills::ServiceDiscoveryComposerExecutor,
          service_name: params[:service_name],
          service_slug: params[:service_slug],
          sdwan_network_id: params[:sdwan_network_id],
          backend_peer_id: params[:backend_peer_id],
          backend_port: params[:backend_port],
          vip_cidr: params[:vip_cidr],
          protocol: params[:protocol],
          grant_scopes: params[:grant_scopes],
          grant_ttl_days: params[:grant_ttl_days],
          traefik_dynamic_dir: params[:traefik_dynamic_dir],
          public_dns: params[:public_dns]
        )
      end

      # Instantiate a skill executor with this tool's account/agent/user
      # context, run it synchronously, and map its result. nil-valued inputs
      # are dropped so the executor's own keyword defaults (e.g. dry_run:
      # false, routing_protocol: "static") and required-input validation
      # apply — passing explicit nils would clobber those defaults.
      #
      # The instance provenance travels with the call. Forwarding `user:` alone
      # dropped it — an instance principal has no User, so the executor read the
      # nil user as "in-process reconciler" and handed every tool it nests the
      # internal bypass, out of reach of the name grant and the destructive deny
      # overlay that authorized THIS call. (IMP-0e6b216de843)
      def run_skill_executor(executor_class, **inputs)
        executor = build_skill_executor(executor_class)
        result = executor.execute(**inputs.compact)
        result[:success] ? success_result(result[:data]) : error_result(result[:error])
      end

      # IMP-4ed94eef2971 — the general peer update, mirroring the REST twin
      # (PeersController#update) field for field through the ONE writable list
      # on Sdwan::Peer. Until this landed the MCP surface could set only
      # lan_subnets and tags, so an agent remediating a wrong endpoint — or
      # correcting a peer's hub election — had no MCP path at all while the
      # operator HTTP surface gated the whole set.
      #
      # A THIN ARM, not a new executor: Sdwan::Executors::UpdatePeer already
      # takes an attributes hash and is already the sole writer for this
      # category, so this adds a surface, not a mechanism. The two
      # single-field setters below STAY: update_peer_lan_subnets gates on
      # system.sdwan.routing.manage and answers a routing-shaped payload
      # (advertisement_count), set_peer_tags answers a label-shaped one, and
      # both are a published contract existing agents call. The permission
      # difference cuts BOTH ways and neither direction is an escalation: a
      # routing operator who is not a peers manager reaches lan_subnets only
      # through the setter, and a peers manager reaches it only through this
      # arm — which is exactly what peer_update_params has always allowed a
      # peers manager over HTTP. All three land on ONE action category and ONE
      # executor, so no path is a policy bypass of another — pinned in
      # peer_update_surface_parity_spec.rb. Note the split is USER-principal
      # only: action_permitted? short-circuits on instance_authorized? before
      # ACTION_PERMISSIONS is read at all.
      #
      # publicly_reachable IS THE HUB-ELECTION FLAG (NodeApi::SdwanController#
      # hubbed_network_ids, and the hub/spoke partition in every topology
      # strategy). This arm can flip it on an ALREADY-ENROLLED peer, which
      # attach_peer cannot (the network+instance unique index means create
      # only ever reaches a peer that does not exist yet). That is deliberate
      # — MCP is the operator/agent surface, the same one PeersController
      # serves, and the flag stays unreachable from the node_api INSTANCE
      # surface, which is the property that stops a node self-electing there.
      #
      # WHAT THE GATE ACTUALLY DOES HERE, stated because it is easy to assume
      # otherwise: sdwan.peer_update is seeded `notify_and_proceed` for BOTH
      # audiences (system_sdwan_manager_agent.rb seeds the table twice — once
      # agent-scoped, once agent-less scope-"action_type" for operator/MCP
      # callers), so on a seeded install this NOTIFIES and executes at once.
      # It parks an approval only where an operator has tiered the category up.
      # The gate is the policy seam, not a guarantee of human review, and no
      # comment or schema string on this arm may imply otherwise.
      def update_peer(params)
        peer = account_peers.find(params[:peer_id])

        opts = params[:options] || {}
        # A `type: "object"` parameter routinely arrives as a JSON STRING (or
        # an array) from a model that guessed the encoding. Without this,
        # `to_h` below raises NoMethodError/TypeError past every rescue in the
        # ladder and the caller gets a 500 instead of a field error. Same
        # guard create_network carries.
        unless opts.is_a?(::Hash) || opts.is_a?(::ActionController::Parameters)
          return error_result("options must be an object of fields to update — permitted: " \
                              "#{self.class.peer_update_option_names.join(', ')}")
        end

        attrs = peer_update_attrs(opts)
        # Requested-but-unusable fails LOUD rather than parking a no-op
        # approval (see update_port_mapping). The message is derived from the
        # same list, so it cannot name a field the arm no longer accepts.
        if attrs.empty?
          return error_result("no recognized fields to update — permitted (options): " \
                              "#{self.class.peer_update_option_names.join(', ')}")
        end

        error = validation_error_before_gate(peer, attrs) do |candidate|
          # Park what the executor will PERSIST, not the raw input. tags is
          # the one field in this set the model normalizes (normalize_tags:
          # trim/dedup/drop-blank), and the approval card renders the parked
          # attributes — so without this capture an approver reading
          # `[" Edge ", " Edge ", ""]` would approve a write of `["Edge"]`.
          # set_peer_tags below has done this since it was gated; the general
          # arm must not reintroduce the divergence for the same column.
          attrs[:tags] = candidate.tags.dup if attrs.key?(:tags)
        end
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdatePeer",
          executor_params: { peer_id: peer.id, attributes: attrs },
          source_type: "Sdwan::Peer",
          source_id: peer.id,
          # Matches UpdatePeer#summarize and the REST gate description, so all
          # three surfaces of the approval speak one sentence (IMP-3a563becb7d7).
          description: "Update SDWAN peer #{peer.operator_label}"
        ) { |_result| { peer: serialize_peer_full(peer.reload) } }
      end

      # The MCP mirror of PeersController#peer_update_params, run through
      # ActionController::Parameters against the SAME list so the two surfaces
      # share strong parameters' shape semantics rather than approximating
      # them: an array-declared key drops a non-array, a hash-declared key
      # drops a non-hash. That is what keeps a mis-shaped value out of a
      # `null: false` column here as well as over HTTP, instead of parking an
      # operation that can only fail at approval time.
      def peer_update_attrs(source)
        ::ActionController::Parameters.new(source.to_h).permit(
          *::Sdwan::Peer::UPDATE_SCALAR_ATTRIBUTES,
          **::Sdwan::Peer::UPDATE_ARRAY_ATTRIBUTES.index_with { [] },
          **::Sdwan::Peer::UPDATE_HASH_ATTRIBUTES.index_with { {} }
        ).to_h.symbolize_keys
      end

      # The same set under the names a CALLER uses, for the refusal message
      # and the tool schema's `options` description. A class method because
      # `self.action_definitions` is the schema's home.
      def self.peer_update_option_names
        ::Sdwan::Peer::UPDATE_ATTRIBUTES
      end

      # === Slice 9a — Routing (static subnet routing) ===

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate as sdwan.peer_update,
      # mirroring the REST twin: lan_subnets is in PeersController's
      # peer_update_params permit list, so the gated REST path and this arm
      # mutate the same category (changing lan_subnets rewrites AllowedIPs for
      # every peer routing to this one). UpdatePeer's update! is the only
      # writer; the proceed payload keeps this arm's routing-shaped response.
      def set_peer_lan_subnets(params)
        peer = account_peers.find(params[:peer_id])
        attrs = { lan_subnets: Array(params[:lan_subnets]).map(&:to_s) }
        error = validation_error_before_gate(peer, attrs)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdatePeer",
          executor_params: { peer_id: peer.id, attributes: attrs },
          source_type: "Sdwan::Peer",
          source_id: peer.id,
          # Matches UpdatePeer#summarize (Sdwan::Peer#operator_label — the
          # ladder every peer surface renders, IMP-ee57d0fbe859).
          description: "Update SDWAN peer #{peer.operator_label}"
        ) { |_result|
          {
            peer_id: peer.id,
            # The executor persisted exactly attrs (no callback transforms
            # lan_subnets) — answering it saves the reload SELECT; the
            # advertisement count reflects the executor's after_save sync,
            # so that query is unavoidable.
            lan_subnets: attrs[:lan_subnets],
            advertisement_count: peer.subnet_advertisements.active.count
          }
        }
      end

      # D8 — set the firewall tag labels on a peer (the model normalizes:
      # trim/dedup). Firewall { "tag": "x" } selectors then resolve to it.
      # IMP-c9798d9d5671 — gated as sdwan.peer_update like set_peer_lan_subnets:
      # tags ride the SAME REST permit list (peer_update_params), so leaving
      # this arm inline would keep the category bypassable through MCP.
      def set_peer_tags(params)
        peer = account_peers.find(params[:peer_id])
        # The valid? pass runs the model's before_validation normalize
        # (trim/dedup/drop-blank) — capture it in the helper's valid-path
        # window and park THAT, not the raw input: the approval card renders
        # the parked attributes, so what the approver sees must be what the
        # executor persists. Same capture answers the proceed payload
        # without a reload SELECT.
        normalized_tags = nil
        error = validation_error_before_gate(peer, { tags: Array(params[:tags]).map(&:to_s) }) do |p|
          normalized_tags = p.tags.dup
        end
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdatePeer",
          executor_params: { peer_id: peer.id, attributes: { tags: normalized_tags } },
          source_type: "Sdwan::Peer",
          source_id: peer.id,
          description: "Update SDWAN peer #{peer.operator_label}"
        ) { |_result| { peer_id: peer.id, tags: normalized_tags } }
      end

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate as
      # sdwan.network_update: routing_protocol is in NetworksController's
      # network_params permit list, so the gated REST update and this arm flip
      # the same control-plane knob. The mode check is the MODEL's inclusion
      # validation via the shared pre-gate ceremony (one wording with the
      # REST twin, and a doomed change parks no approval); UpdateNetwork's
      # update! is the only writer. The general update_network arm gates on
      # the same category (IMP-2ff1980f7813).
      def set_network_routing_mode(params)
        network = account_networks.find(params[:network_id])
        mode = params[:routing_protocol].to_s
        attrs = { routing_protocol: mode }
        error = validation_error_before_gate(network, attrs)
        return error if error

        # The iBGP capability warning must survive BOTH branches: the caller
        # sees it on :pending via pending_extra (the old inline arm always
        # returned it), and the APPROVER sees it in the description — neither
        # would otherwise learn the mode they are approving isn't fully
        # functional yet.
        note = mode == "ibgp" ? "iBGP mode requires slice 9c (FRR daemon) — peers won't propagate routes via BGP yet." : nil

        gated_result(
          action_category: ::Sdwan::Executors::UpdateNetwork::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateNetwork",
          executor_params: { network_id: network.id, attributes: attrs },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Base sentence matches NetworksController#update's gate description.
          description: "Update SDWAN network '#{network.name}'#{" — #{note}" if note}",
          pending_extra: note ? { note: note } : {}
        ) { |_result|
          {
            network_id: network.id,
            # The executor persisted exactly attrs — no reload needed.
            routing_protocol: mode,
            note: note
          }
        }
      end

      def list_subnet_advertisements(params)
        network = account_networks.find(params[:network_id])
        scope = network.subnet_advertisements
        scope = scope.where(source: params[:source]) if params[:source].present?
        scope = scope.active unless params[:include_withdrawn]
        paginated_result(:advertisements, scope, params, sort: :prefix, direction: :asc,
                         network_id: network.id) { |a| serialize_subnet_advertisement(a) }
      end

      def get_routing_summary(params)
        network = account_networks.find(params[:network_id])
        success_result(
          network_id: network.id,
          routing_protocol: network.routing_protocol,
          advertise_overlay_subnet: network.advertise_overlay_subnet,
          route_reflector_redundancy: network.route_reflector_redundancy,
          peer_count: network.peers.count,
          hub_count: network.peers.where(publicly_reachable: true).count,
          rr_count: network.peers.where(publicly_reachable: true).count, # slice 9c will distinguish
          advertised_prefix_count: network.subnet_advertisements.active.count,
          declared_subnet_count: network.subnet_advertisements.active.declared.count,
          vip_count: network.subnet_advertisements.active.vip.count,
          learned_count: network.subnet_advertisements.active.learned.count
        )
      end

      def serialize_subnet_advertisement(a)
        {
          id: a.id,
          peer_id: a.sdwan_peer_id,
          network_id: a.sdwan_network_id,
          prefix: a.prefix,
          source: a.source,
          origin_peer_id: a.origin_peer_id,
          via_peer_id: a.via_peer_id,
          as_path: a.as_path,
          med: a.med,
          local_pref: a.local_pref,
          first_seen_at: a.first_seen_at&.iso8601,
          last_seen_at: a.last_seen_at&.iso8601,
          withdrawn_at: a.withdrawn_at&.iso8601,
          active: a.active?
        }
      end

      # === Slice 9b — Virtual IPs ===

      # IMP-6c482005db87 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (VirtualIpsController#create): the executor existed with no
      # caller, so the seeded sdwan.virtual_ip_create policy matched nothing
      # this tool did. Sdwan::Executors::CreateVirtualIp performs the whole
      # slice-9b create ceremony server-side (activation + initial assignment
      # row), so it survives the :pending path; this method mutates nothing
      # on either branch.
      #
      # The candidate is validated BEFORE the gate — mirroring the executor's
      # build (including activation) so validation sees exactly the row that
      # would be written — and is never saved. Account ownership is enforced
      # HERE by account_networks, the same split the HTTP path uses.
      def create_virtual_ip(params)
        network = account_networks.find(params[:network_id])
        attrs = virtual_ip_create_attrs(params)

        candidate = network.virtual_ips.new(attrs)
        candidate.activate_if_held
        unless candidate.valid?
          return error_result(candidate.errors.full_messages.join("; "))
        end

        gated_result(
          action_category: ::Sdwan::Executors::CreateVirtualIp::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateVirtualIp",
          executor_params: { network_id: network.id, attributes: attrs },
          source_type: "Sdwan::Network",
          source_id: network.id,
          # Matches CreateVirtualIp#summarize so both surfaces of the
          # approval speak one sentence (IMP-3a563becb7d7).
          description: "Allocate SDWAN VIP '#{candidate.name}' on network #{network.name}"
        ) { |result| { virtual_ip: serialize_virtual_ip(network.virtual_ips.find(result.result&.dig(:data, :vip_id))) } }
      end

      def list_virtual_ips(params)
        network = account_networks.find(params[:network_id])
        scope = network.virtual_ips
        scope = scope.where(state: params[:state]) if params[:state].present?
        paginated_result(:virtual_ips, scope, params, sort: :name, direction: :asc) { |v| serialize_virtual_ip(v) }
      end

      def get_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        success_result(virtual_ip: serialize_virtual_ip(vip).merge(
          assignments: vip.assignments.order(assumed_at: :desc).limit(20).map { |a| serialize_vip_assignment(a) }
        ))
      end

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (VirtualIpsController#update). This verb was NOT a clean
      # drop-in wiring: the holder audit sync ran inline here (a hand copy of
      # what became Sdwan::VirtualIp#sync_holder_assignments!), and gated_result
      # never invokes its proceed block on :pending — the executor is the sole
      # writer there — so the whole update+sync transaction now lives ONLY in
      # UpdateVirtualIp#perform (which also anchors sdwan_network_id via
      # Base#anchor_reparent!, a tenancy guard the inline body never had).
      # Attribution rides the DeferredOperation's requested_by (this @user).
      def update_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        updates = {}
        %i[holder_peer_ids failover_holder_peer_ids tags].each do |k|
          updates[k] = Array(params[k]) if params.key?(k)
        end
        %i[anycast description advertised_med advertised_local_pref].each do |k|
          updates[k] = params[k] if params.key?(k) && !params[k].nil?
        end

        # Requested-but-unusable fails LOUD rather than parking a no-op
        # approval (see update_firewall_rule).
        if updates.empty?
          return error_result("no recognized fields to update — permitted: holder_peer_ids, failover_holder_peer_ids, tags, anycast, description, advertised_med, advertised_local_pref")
        end
        error = validation_error_before_gate(vip, updates)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdateVirtualIp::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateVirtualIp",
          # IMP-391525770512 — the same replay-baseline stamp the REST twin
          # makes. Omitting it here would leave one surface of ONE executor
          # guarded and the other not, which is how a per-verb guard turns
          # into a hole reachable by a different noun. `vip` is persisted
          # state: validation_error_before_gate restores it above.
          executor_params: {
            vip_id: vip.id, attributes: updates,
            replay_baseline: ::Sdwan::Executors::UpdateVirtualIp.replay_baseline(vip, updates)
          },
          source_type: "Sdwan::VirtualIp",
          source_id: vip.id,
          # Matches UpdateVirtualIp#summarize so both surfaces of the
          # approval speak one sentence (IMP-3a563becb7d7).
          description: "Update SDWAN VIP '#{vip.name}' on network #{vip.network.name}"
        ) { |_result| { virtual_ip: serialize_virtual_ip(vip.reload) } }
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.virtual_ip_delete, matching VirtualIpsController#destroy.
      #
      # The inline arm released live assignments before destroying. That step is
      # not carried over and is not lost: VirtualIp declares
      # `has_many :assignments, dependent: :destroy`, so the holder rows go with
      # the VIP either way — the release only ever stamped rows a beat before
      # deleting them. The executor's destroy! runs the same association
      # callbacks.
      def delete_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteVirtualIp::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteVirtualIp",
          executor_params: { vip_id: vip.id },
          source_type: "Sdwan::VirtualIp",
          source_id: vip.id,
          # Verbatim the REST twin (VirtualIpsController#destroy).
          description: "Delete VIP #{vip.try(:cidr) || vip.id}"
        ) do |_result|
          { deleted: true, id: vip.id }
        end
      end

      # IMP-7c911ca26585 — routed through Ai::AutonomyGate with the REST
      # twin's exact category (VirtualIpsController#failover): promoting the
      # failover holder rewrites BGP/AllowedIPs reachability, so an agent
      # refused approval on the REST surface must not get it inline here.
      # The model's preconditions are asked PRE-gate so a doomed failover
      # fails loud instead of parking an approval that can only fail on
      # execution. IMP-d952c791e264 replaced the hand-copied mirror of the two
      # StateError guards with Sdwan::VirtualIp#failover_blocker — the same
      # symbol failover! raises — so this arm cannot drift from the model's
      # wording again and inherits the case the copy missed (a standby that is
      # no longer a live peer of the VIP's network).
      #
      # gated_result never invokes its proceed block on :pending, so
      # the rotate + audit transaction runs ONLY in FailoverVirtualIp#perform;
      # attribution rides the DeferredOperation's requested_by (this @user —
      # the executor credits deferred_operation.requested_by, replacing the
      # inline body's triggered_by_user: @user).
      def failover_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        if (blocker = vip.failover_blocker)
          return error_result(blocker)
        end

        gated_result(
          action_category: ::Sdwan::Executors::FailoverVirtualIp::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::FailoverVirtualIp",
          executor_params: { vip_id: vip.id },
          source_type: "Sdwan::VirtualIp",
          source_id: vip.id,
          # Matches the REST twin's wording (VirtualIpsController#failover)
          # so both surfaces of the approval speak one sentence.
          description: "Manual failover of VIP #{vip.try(:cidr) || vip.id}"
        ) { |_result| { virtual_ip: serialize_virtual_ip(vip.reload), failed_over: true } }
      end

      def list_vip_assignments(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        paginated_result(:assignments, vip.assignments, params,
                         virtual_ip_id: vip.id) { |a| serialize_vip_assignment(a) }
      end

      # ─── Slice 9c — iBGP control plane ─────────────────────────────────

      def get_account_bgp(_params)
        row = ::Sdwan::AccountBgp.find_by(account_id: @account.id)
        success_result(account_bgp: row ? serialize_account_bgp(row) : nil)
      end

      def set_account_as_number(_params)
        existing = ::Sdwan::AccountBgp.find_by(account_id: @account.id)
        if existing
          return success_result(account_bgp: serialize_account_bgp(existing), allocated: false)
        end

        row = ::Sdwan::Bgp::AsNumberAllocator.allocate!(account: @account)
        success_result(account_bgp: serialize_account_bgp(row), allocated: true)
      rescue ::Sdwan::Bgp::AsNumberAllocator::CapacityExhausted => e
        error_result(e.message)
      end

      def get_bgp_sessions(params)
        scope = ::Sdwan::BgpSession.joins(:network)
                                   .where(system_sdwan_networks: { account_id: @account.id })
        scope = scope.where(system_sdwan_networks: { id: params[:network_id] }) if params[:network_id].present?
        scope = scope.where(state: params[:state]) if params[:state].present?

        sessions = scope.order(updated_at: :desc).limit(500).to_a
        success_result(
          sessions: sessions.map { |s| serialize_bgp_session(s) },
          count: sessions.size
        )
      end

      def get_bgp_config_for_peer(params)
        peer = ::Sdwan::Peer.joins(:network)
                            .where(system_sdwan_networks: { account_id: @account.id })
                            .find(params[:peer_id])
        cfg = ::Sdwan::Bgp::ConfigCompiler.compile_for_peer(peer)
        success_result(peer_id: peer.id, network_id: peer.sdwan_network_id, bgp: cfg)
      rescue ActiveRecord::RecordNotFound
        error_result("peer not found in account scope")
      end

      def serialize_account_bgp(row)
        {
          id: row.id,
          as_number: row.as_number,
          router_id_strategy: row.router_id_strategy,
          default_local_pref: row.default_local_pref,
          enabled: row.enabled,
          created_at: row.created_at&.iso8601
        }
      end

      def serialize_bgp_session(s)
        {
          id: s.id,
          peer_id: s.sdwan_peer_id,
          network_id: s.sdwan_network_id,
          neighbor_peer_id: s.neighbor_peer_id,
          neighbor_address: s.neighbor_address,
          state: s.state,
          uptime_seconds: s.uptime_seconds,
          prefixes_received: s.prefixes_received,
          prefixes_sent: s.prefixes_sent,
          last_state_change_at: s.last_state_change_at&.iso8601,
          last_observed_at: s.last_observed_at&.iso8601,
          last_error: s.last_error
        }
      end

      # ─── Slice 9e — route policies ─────────────────────────────────────

      def list_route_policies(params)
        scope = ::Sdwan::RoutePolicy.where(account_id: @account.id)
        scope = scope.where(scope: params[:scope]) if params[:scope].present?
        scope = scope.where(direction: params[:direction]) if params[:direction].present?
        paginated_result(:route_policies, scope, params, sort: :scope, direction: :asc) { |p| serialize_route_policy(p) }
      end

      def get_route_policy(params)
        p = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        success_result(route_policy: serialize_route_policy_full(p))
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.route_policy_create, matching RoutePoliciesController#create.
      #
      # The candidate is validated BEFORE the gate and never saved
      # (Sdwan::Executors::CreateRoutePolicy#create! stays the sole writer), so
      # a payload that could only ever fail keeps its message instead of parking
      # an approval an operator has to dispose of — the same
      # validate-before-gate contract every other create arm here keeps.
      def create_route_policy(params)
        attrs = params.slice(:name, :scope, :direction, :scope_resource_id, :description, :enabled)
        attrs[:statements] = params[:statements] if params[:statements].present?
        candidate = ::Sdwan::RoutePolicy.new(attrs.merge(account_id: @account.id))
        unless candidate.valid?
          return error_result(candidate.errors.full_messages.join("; "))
        end

        gated_result(
          action_category: ::Sdwan::Executors::CreateRoutePolicy::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateRoutePolicy",
          # The executor takes the account from the operation, so `attributes`
          # carries only what the caller asked for — account_id above belongs to
          # the candidate, not to the replayed payload.
          executor_params: { attributes: attrs },
          # Provenance only: RoutePolicy belongs directly to the account, so
          # there is no parent row to anchor — same anchor the REST twin passes.
          source_type: "Account",
          source_id: @account.id,
          description: "Create SDWAN route policy #{candidate.name}"
        ) do |result|
          policy = ::Sdwan::RoutePolicy.where(account_id: @account.id)
                                       .find(result.result&.dig(:data, :policy_id))
          { route_policy: serialize_route_policy_full(policy) }
        end
      end

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (RoutePoliciesController#update). UpdateRoutePolicy's
      # update! stays the only writer (validation_error_before_gate ceremony).
      def update_route_policy(params)
        policy = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        opts = params[:options] || {}
        attrs = opts.slice(:name, :description, :scope, :scope_resource_id, :direction,
                           :enabled, :statements, :metadata)
        # Requested-but-unusable fails LOUD rather than parking a no-op
        # approval (see update_firewall_rule).
        if attrs.empty?
          return error_result("no recognized fields to update — permitted (options): name, description, scope, scope_resource_id, direction, enabled, statements, metadata")
        end
        error = validation_error_before_gate(policy, attrs)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdateRoutePolicy::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateRoutePolicy",
          executor_params: { policy_id: policy.id, attributes: attrs },
          source_type: "Sdwan::RoutePolicy",
          source_id: policy.id,
          # Matches RoutePoliciesController#update's gate description.
          description: "Update SDWAN route policy #{policy.name}"
        ) { |_result| { route_policy: serialize_route_policy_full(policy.reload) } }
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.route_policy_delete, matching RoutePoliciesController#destroy.
      # update_route_policy above was already gated; delete was the odd one out,
      # and dropping a policy is the direction that widens what a neighbor
      # accepts.
      def delete_route_policy(params)
        policy = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteRoutePolicy::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteRoutePolicy",
          executor_params: { policy_id: policy.id },
          source_type: "Sdwan::RoutePolicy",
          source_id: policy.id,
          description: "Delete route policy '#{policy.name}'"
        ) do |_result|
          { deleted: true, id: policy.id }
        end
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      def compile_route_policy(params)
        peer = ::Sdwan::Peer.joins(:network)
                            .where(system_sdwan_networks: { account_id: @account.id })
                            .find(params[:peer_id])
        compiled = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(peer)
        success_result(peer_id: peer.id, network_id: peer.sdwan_network_id, compiled: compiled)
      rescue ActiveRecord::RecordNotFound
        error_result("peer not found in account scope")
      end

      def serialize_route_policy(p)
        {
          id: p.id, name: p.name, description: p.description,
          scope: p.scope, scope_resource_id: p.scope_resource_id,
          direction: p.direction, enabled: p.enabled,
          statement_count: Array(p.statements).size,
          slug: p.slug,
          created_at: p.created_at&.iso8601, updated_at: p.updated_at&.iso8601
        }
      end

      def serialize_route_policy_full(p)
        serialize_route_policy(p).merge(statements: p.statements, metadata: p.metadata)
      end

      # ─── Slice 7b — port mappings ────────────────────────────────────

      def list_port_mappings(params)
        net = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
        scope = net.port_mappings
        scope = scope.where(sdwan_peer_id: params[:hub_peer_id]) if params[:hub_peer_id].present?
        paginated_result(:port_mappings, scope, params, sort: :listen_port, direction: :asc) { |m| serialize_port_mapping(m) }
      rescue ActiveRecord::RecordNotFound
        error_result("network not found in account scope")
      end

      def get_port_mapping(params)
        m = port_mapping_in_account(params[:port_mapping_id])
        return error_result("port mapping not found") unless m

        success_result(port_mapping: serialize_port_mapping_full(m))
      end

      def create_port_mapping(params)
        net = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
        # IMP-2c531ddb5a0c: one writable list with the REST twin. Create takes
        # its fields at the top level rather than under `options`.
        attrs = port_mapping_writable_attrs(params).merge(account_id: @account.id).compact
        # Create-time defaults, applied so an omitted value is explicit on the
        # candidate rather than left to the column default alone.
        attrs[:protocol] ||= "tcp"
        attrs[:enabled] = true unless attrs.key?(:enabled)
        m = net.port_mappings.new(attrs)
        if m.save
          success_result(port_mapping: serialize_port_mapping_full(m))
        else
          error_result(m.errors.full_messages.join("; "))
        end
      rescue ActiveRecord::RecordNotFound
        error_result("network not found in account scope")
      end

      # IMP-c9798d9d5671 — routed through Ai::AutonomyGate, mirroring the
      # REST twin (PortMappingsController#update). UpdatePortMapping's
      # update! stays the only writer (validation_error_before_gate ceremony).
      def update_port_mapping(params)
        m = port_mapping_in_account(params[:port_mapping_id])
        return error_result("port mapping not found") unless m

        opts = params[:options] || {}
        # IMP-2c531ddb5a0c: one writable list with the REST twin, which has
        # always permitted the hub column this arm silently dropped.
        attrs = port_mapping_writable_attrs(opts)
        # Requested-but-unusable fails LOUD rather than parking a no-op
        # approval (see update_firewall_rule). The message is derived from the
        # same list, so it cannot name a field the arm no longer accepts.
        if attrs.empty?
          return error_result("no recognized fields to update — permitted (options): #{self.class.port_mapping_option_names.join(', ')}")
        end
        error = validation_error_before_gate(m, attrs)
        return error if error

        gated_result(
          action_category: ::Sdwan::Executors::UpdatePortMapping::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdatePortMapping",
          executor_params: { mapping_id: m.id, attributes: attrs },
          source_type: "Sdwan::PortMapping",
          source_id: m.id,
          # Matches UpdatePortMapping#summarize so both surfaces of the
          # approval speak one sentence (IMP-3a563becb7d7).
          description: "Update SDWAN port mapping #{m.name} on #{m.network.name}"
        ) { |_result| { port_mapping: serialize_port_mapping_full(m.reload) } }
      end

      # IMP-800b25c1cc45 — routed through Ai::AutonomyGate as
      # sdwan.port_mapping_delete, matching PortMappingsController#destroy.
      # Create and update on this resource were already gated here.
      def delete_port_mapping(params)
        m = port_mapping_in_account(params[:port_mapping_id])
        return error_result("port mapping not found") unless m

        gated_result(
          action_category: ::Sdwan::Executors::DeletePortMapping::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeletePortMapping",
          executor_params: { mapping_id: m.id },
          source_type: "Sdwan::PortMapping",
          source_id: m.id,
          # Verbatim the REST twin (PortMappingsController#destroy), so the
          # approval card reads the same whichever surface opened it.
          description: "Delete port mapping #{m.id}"
        ) do |_result|
          { deleted: true, id: m.id }
        end
      end

      # This surface's name for a port-mapping column that it does not call by
      # the column's own name. `hub_peer_id` is what create's parameter, both
      # serializers and list's filter have always called sdwan_peer_id, so the
      # shared writable list is TRANSLATED here rather than sliced through —
      # renaming the caller-facing key would break every existing agent call.
      PORT_MAPPING_OPTION_ALIASES = { hub_peer_id: :sdwan_peer_id }.freeze

      # Caller-supplied attributes for a port-mapping write, taken from
      # Sdwan::PortMapping's one writable list (IMP-2c531ddb5a0c) with the
      # alias above applied. `source` is the top-level params on create and
      # the `options` sub-hash on update.
      def port_mapping_writable_attrs(source)
        direct = ::Sdwan::PortMapping::WRITABLE_ATTRIBUTES - PORT_MAPPING_OPTION_ALIASES.values
        attrs = source.slice(*direct)
        PORT_MAPPING_OPTION_ALIASES.each do |option, column|
          attrs[column] = source[option] if source.key?(option)
        end
        attrs
      end

      # The same set under the names a CALLER uses, for the refusal message
      # and the tool schema's `options` description. A class method because
      # `self.action_definitions` is the schema's home.
      def self.port_mapping_option_names
        (::Sdwan::PortMapping::WRITABLE_ATTRIBUTES - PORT_MAPPING_OPTION_ALIASES.values) +
          PORT_MAPPING_OPTION_ALIASES.keys
      end

      def port_mapping_in_account(id)
        return nil if id.blank?

        ::Sdwan::PortMapping.joins(:network)
                            .where(system_sdwan_networks: { account_id: @account.id })
                            .find_by(id: id)
      end

      def serialize_port_mapping(m)
        {
          id: m.id,
          network_id: m.sdwan_network_id,
          hub_peer_id: m.sdwan_peer_id,
          target_peer_id: m.target_peer_id,
          target_virtual_ip_id: m.target_virtual_ip_id,
          name: m.name,
          listen_port: m.listen_port,
          target_port: m.target_port,
          effective_target_port: m.effective_target_port,
          protocol: m.protocol,
          enabled: m.enabled,
          created_at: m.created_at&.iso8601
        }
      end

      def serialize_port_mapping_full(m)
        serialize_port_mapping(m).merge(
          description: m.description,
          metadata: m.metadata,
          resolved_target_address: m.resolved_target_address,
          rate_limit: m.rate_limit,
          max_connections: m.max_connections,
          source_cidrs: m.source_cidrs
        )
      end

      def account_virtual_ips
        ::Sdwan::VirtualIp.where(account_id: @account.id)
      end

      def serialize_virtual_ip(v)
        primary = v.primary_holder
        {
          id: v.id,
          network_id: v.sdwan_network_id,
          name: v.name,
          cidr: v.cidr,
          anycast: v.anycast?,
          state: v.state,
          holder_peer_ids: Array(v.holder_peer_ids),
          failover_holder_peer_ids: Array(v.failover_holder_peer_ids),
          primary_holder_peer_id: primary&.id,
          primary_holder_address: primary&.assigned_address,
          advertised_med: v.advertised_med,
          advertised_local_pref: v.advertised_local_pref,
          tags: Array(v.tags),
          description: v.description,
          created_at: v.created_at&.iso8601
        }
      end

      def serialize_vip_assignment(a)
        {
          id: a.id,
          peer_id: a.sdwan_peer_id,
          assumed_at: a.assumed_at.iso8601,
          released_at: a.released_at&.iso8601,
          reason: a.reason,
          triggered_by_user_id: a.triggered_by_user_id,
          active: a.active?
        }
      end

      # The attribute Hash the gate stores and Sdwan::Executors::CreateVirtualIp
      # replays into save! — same key set and defaults the inline create
      # carried. The slice-9b initial-assignment bootstrap that used to live
      # beside this moved into the executor, where it also runs on the :pending
      # path (IMP-6c482005db87).
      #
      # IMP-4a5094b22df0: no account_id. It existed ONLY to give the approval
      # card an account to scope its network label by, back when Base.preview
      # ran with deferred_operation: nil; the card now anchors on the
      # operation's own account. Sdwan::VirtualIp derives account_id from its
      # network in a before_validation, so the candidate still validates
      # identically.
      def virtual_ip_create_attrs(params)
        {
          name: params[:name],
          cidr: params[:cidr],
          anycast: params[:anycast] || false,
          holder_peer_ids: Array(params[:holder_peer_ids]),
          failover_holder_peer_ids: Array(params[:failover_holder_peer_ids]),
          description: params[:description],
          tags: Array(params[:tags]),
          advertised_med: params[:advertised_med] || 0,
          advertised_local_pref: params[:advertised_local_pref] || 100
        }
      end

      def account_federation_peers
        ::System::FederationPeer.where(account_id: @account.id)
      end

      def serialize_federation_peer(p)
        {
          id: p.id,
          remote_instance_url: p.remote_instance_url,
          remote_instance_id: p.remote_instance_id,
          remote_account_id: p.remote_account_id,
          remote_prefix_advertisement: p.remote_prefix_advertisement,
          status: p.status,
          data_residency: p.data_residency,
          # The revocation cause this tool records (system_sdwan_revoke_federation_peer)
          # would otherwise be write-only over MCP — none of the nine actions
          # sharing this projection expose peer metadata, so nothing could read
          # it back.
          revocation_reason: p.metadata["revocation_reason"],
          v1_allowed_transitions: ::System::FederationPeer::V1_TRANSITIONS.fetch(p.status, []),
          signed_at: p.signed_at&.iso8601,
          expires_at: p.expires_at&.iso8601,
          created_at: p.created_at&.iso8601
        }
      end

      # Non-secret projection of a FederationAuditShipment (P9.2 WORM
      # batch). sealed_path (content-addressable seal location) and
      # error_message are deliberately omitted.
      def serialize_audit_shipment(s)
        {
          id: s.id,
          period_start: s.period_start&.iso8601,
          period_end: s.period_end&.iso8601,
          event_count: s.event_count,
          sha256: s.sha256,
          status: s.status
        }
      end

      # Compact projection of a federation FleetEvent for the audit log view.
      def serialize_audit_event(e)
        {
          id: e.id,
          kind: e.kind,
          severity: e.severity,
          source: e.source,
          payload: e.payload,
          correlation_id: e.correlation_id,
          emitted_at: e.emitted_at&.iso8601
        }
      end

      def serialize_rule(r)
        {
          id: r.id,
          network_id: r.sdwan_network_id,
          name: r.name,
          priority: r.priority,
          action: r.action,
          direction: r.direction,
          protocol: r.protocol,
          src_selector: r.src_selector,
          dst_selector: r.dst_selector,
          port_range: r.port_range_hash,
          enabled: r.enabled,
          created_at: r.created_at.iso8601
        }
      end

      def account_networks
        ::Sdwan::Network.where(account_id: @account.id)
      end

      def account_peers
        ::Sdwan::Peer.where(account_id: @account.id)
      end

      def serialize_network(n)
        {
          id: n.id,
          name: n.name,
          slug: n.slug,
          status: n.status,
          cidr_64: n.cidr_64,
          peer_count: n.peers.size,
          created_at: n.created_at.iso8601
        }
      end

      def serialize_network_full(n)
        serialize_network(n).merge(
          description: n.description,
          settings: n.settings,
          tags: n.tags,
          hub_count: n.peers.where(publicly_reachable: true).count,
          spoke_count: n.peers.where(publicly_reachable: false).count
        )
      end

      def serialize_peer(p)
        primary = p.primary_endpoint
        fallback = p.fallback_endpoint
        {
          id: p.id,
          network_id: p.sdwan_network_id,
          node_instance_id: p.node_instance_id,
          assigned_address: p.assigned_address,
          publicly_reachable: p.publicly_reachable,
          endpoint_host: p.endpoint_host,
          endpoint_host_v6: p.endpoint_host_v6,
          endpoint_host_v4: p.endpoint_host_v4,
          endpoint_port: p.endpoint_port,
          effective_endpoint: primary && ::Sdwan::Peer.format_host_port(primary[:host], primary[:port]),
          effective_endpoint_family: primary && primary[:family].to_s,
          fallback_endpoint: fallback && "#{fallback[:host]}:#{fallback[:port]}",
          listen_port: p.listen_port,
          status: p.status,
          tags: Array(p.tags),
          public_key: p.active_key&.public_key,
          last_handshake_at: p.last_handshake_at&.iso8601,
          # IMP-ab73cc2fca65 — observed WireGuard byte counters. nil means NOT
          # MEASURED; 0 means measured and idle. Shares the model-owned slice
          # with the REST serializer. See Sdwan::Peer#observed_traffic.
          **p.observed_traffic
        }
      end

      def serialize_peer_full(p)
        serialize_peer(p).merge(
          capabilities: p.capabilities,
          last_compiled_at: p.last_compiled_at&.iso8601,
          created_at: p.created_at.iso8601
        )
      end

      # ─── Phase O6 — host bridges (O1) ──────────────────────────────────

      # IMP-97c7b4123d8f — the O6 write family is gated. Allocation assigns a
      # short_id and a bridge name the compiler emits onto the node, so it
      # reaches the dataplane rather than merely recording intent.
      def create_host_bridge(params)
        host = ::System::NodeInstance.joins(:node)
                                     .where(system_nodes: { account_id: @account.id })
                                     .find(params[:node_instance_id])
        kind = params[:kind].presence
        if kind && !::Sdwan::HostBridge::KINDS.include?(kind.to_s)
          return error_result("kind must be one of #{::Sdwan::HostBridge::KINDS.join(', ')}")
        end

        gated_result(
          action_category: ::Sdwan::Executors::CreateHostBridge::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateHostBridge",
          executor_params: { node_instance_id: host.id, kind: params[:kind].presence },
          source_type: "System::NodeInstance",
          source_id: host.id,
          description: "Allocate SDWAN host bridge on #{host.name.presence || host.id}"
        ) do |result|
          bridge = ::Sdwan::HostBridge.find(result.result&.dig(:data, :host_bridge_id))
          { host_bridge: serialize_host_bridge(bridge) }
        end
      end

      def list_host_bridges(params)
        scope = ::Sdwan::HostBridge.where(account_id: @account.id)
        scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
        paginated_result(:host_bridges, scope, params, sort: :node_instance_id, direction: :asc) { |b| serialize_host_bridge(b) }
      end

      # IMP-53a5c597ec8c — the missing single-row read. `list` could page the
      # whole account, but "what state is THIS bridge in" is the question
      # every activate/release decision turns on, and answering it by
      # listing-and-filtering is both wasteful and easy to get wrong on a
      # busy host. The REST twin (host_bridges#show) has had this since the
      # controller shipped; this is the MCP half.
      def get_host_bridge(params)
        bridge = ::Sdwan::HostBridge.where(account_id: @account.id).find_by(id: params[:id])
        return error_result("host bridge not found") unless bridge

        success_result(host_bridge: serialize_host_bridge(bridge))
      end

      # Mark a HostBridge as `active`. The compiler's `compilable` scope
      # (`active|draining`) only emits active+draining bridges, so a
      # bridge stuck in `pending` is invisible to provisioning. Without
      # this MCP action operators had to drop to `rails runner` to
      # invoke `bridge.mark_active!` after create_host_bridge.
      #
      # `mark_active` only transitions from pending|active — with
      # whiny_transitions: false a call against a `draining`/`removed` row
      # returns false rather than raising, so we surface that as an
      # error_result instead of reporting success on an unchanged row.
      # A `removed` bridge needs `readopt` (drift-remediation event), not
      # `mark_active`, to come back to life.
      def activate_host_bridge(params)
        bridge = ::Sdwan::HostBridge.where(account_id: @account.id).find(params[:id])
        # Transition matrix first: `may_mark_active?` reads the state machine
        # without writing, so an impossible activation is refused here rather
        # than parked as an approval that can only fail.
        unless bridge.may_mark_active?
          hint = bridge.state == "removed" ? " — use readopt to revive a removed bridge" : ""
          return error_result("cannot activate a #{bridge.state} host bridge#{hint}")
        end

        gated_result(
          action_category: ::Sdwan::Executors::ActivateHostBridge::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::ActivateHostBridge",
          executor_params: { host_bridge_id: bridge.id },
          source_type: "Sdwan::HostBridge",
          source_id: bridge.id,
          description: "Activate SDWAN host bridge #{bridge.bridge_name.presence || bridge.id}"
        ) do |_result|
          { host_bridge: serialize_host_bridge(bridge.reload) }
        end
      end

      # Release a HostBridge via the allocator. The default DRAINS: the row
      # stays in `compilable`, so the compiler keeps emitting the bridge and
      # in-flight taps finish without a short_id collision. `force: true`
      # skips that window and marks the row removed immediately.
      #
      # IMP-53a5c597ec8c — the default and its coercion now live on
      # Sdwan::Executors::ReleaseHostBridge rather than being re-expressed
      # here. The REST twin used to hard-force unconditionally while this arm
      # defaulted to draining, so one act had two safety postures depending on
      # who asked. `.force?` also accepts the string form REST params arrive
      # in, so `?force=true` and `force: true` mean the same thing.
      def release_host_bridge(params)
        bridge = ::Sdwan::HostBridge.where(account_id: @account.id).find(params[:id])
        forced = ::Sdwan::Executors::ReleaseHostBridge.force?(params[:force])
        gated_result(
          action_category: ::Sdwan::Executors::ReleaseHostBridge::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::ReleaseHostBridge",
          executor_params: { host_bridge_id: bridge.id, force: forced },
          source_type: "Sdwan::HostBridge",
          source_id: bridge.id,
          description: "Release SDWAN host bridge #{bridge.bridge_name.presence || bridge.id}" \
                       "#{forced ? ' (forced)' : ''}"
        ) do |_result|
          { host_bridge: serialize_host_bridge(bridge.reload) }
        end
      end

      def serialize_host_bridge(b)
        {
          id: b.id,
          account_id: b.account_id,
          node_instance_id: b.node_instance_id,
          short_id: b.short_id,
          bridge_name: b.bridge_name,
          kind: b.kind,
          state: b.state,
          ipv4_cidr: b.ipv4_cidr,
          ipv6_cidr: b.ipv6_cidr,
          applied_at: b.applied_at&.iso8601,
          draining_at: b.draining_at&.iso8601,
          removed_at: b.removed_at&.iso8601,
          created_at: b.created_at&.iso8601
        }
      end

      # ─── Phase O6 — OVN deployment + switches + ports + plan (O3) ──────

      def create_ovn_deployment(params)
        # Validate BEFORE the gate, per gated_result's contract: a payload
        # that can only ever fail must not park an approval an operator has
        # to dispose of. The executor re-runs the checks that count.
        candidate = ::Sdwan::OvnDeployment.new(
          account: @account,
          nb_db_endpoint: params[:nb_db_endpoint], sb_db_endpoint: params[:sb_db_endpoint],
          northd_host: params[:northd_host],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateOvnDeployment::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateOvnDeployment",
          executor_params: {
            nb_db_endpoint: params[:nb_db_endpoint], sb_db_endpoint: params[:sb_db_endpoint],
            northd_host: params[:northd_host],
            settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
          },
          description: "Create the OVN control-plane deployment"
        ) do |result|
          deployment = ::Sdwan::OvnDeployment.find(result.result&.dig(:data, :deployment_id))
          { ovn_deployment: serialize_ovn_deployment(deployment) }
        end
      end

      def create_ovn_logical_switch(params)
        deployment = account_ovn_deployments.find(params[:deployment_id])
        candidate = deployment.logical_switches.new(
          account: @account, name: params[:name], cidr: params[:cidr],
          description: params[:description],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateOvnLogicalSwitch::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateOvnLogicalSwitch",
          executor_params: {
            deployment_id: deployment.id, name: params[:name], cidr: params[:cidr],
            description: params[:description],
            settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
          },
          source_type: "Sdwan::OvnDeployment",
          source_id: deployment.id,
          description: "Create OVN logical switch #{params[:name]}"
        ) do |result|
          switch = ::Sdwan::OvnLogicalSwitch.find(result.result&.dig(:data, :logical_switch_id))
          { ovn_logical_switch: serialize_ovn_logical_switch(switch) }
        end
      end

      def create_ovn_logical_switch_port(params)
        switch = account_ovn_logical_switches.find(params[:logical_switch_id])

        host = nil
        if params[:host_node_instance_id].present?
          host = ::System::NodeInstance.joins(:node)
                                       .where(system_nodes: { account_id: @account.id })
                                       .find(params[:host_node_instance_id])
        end

        candidate = switch.ports.new(
          account: @account, name: params[:name], kind: params[:kind].to_s,
          host_node_instance: host,
          addresses: Array(params[:addresses]).map(&:to_s), mac: params[:mac].presence
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateOvnLogicalSwitchPort::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateOvnLogicalSwitchPort",
          executor_params: {
            logical_switch_id: switch.id, name: params[:name], kind: params[:kind].to_s,
            host_node_instance_id: host&.id,
            addresses: Array(params[:addresses]).map(&:to_s), mac: params[:mac].presence
          },
          source_type: "Sdwan::OvnLogicalSwitch",
          source_id: switch.id,
          description: "Create OVN logical switch port #{params[:name]}"
        ) do |result|
          port = ::Sdwan::OvnLogicalSwitchPort.find(result.result&.dig(:data, :port_id))
          { ovn_logical_switch_port: serialize_ovn_logical_switch_port(port) }
        end
      end

      # Mark an OvnLogicalSwitch as `active`. Mirrors activate_host_bridge:
      # create_ovn_logical_switch lands rows in `pending`, and OvnCompiler's
      # `compilable` scope only emits `active` switches. Without this action
      # the documented create -> compile sequence silently yields an empty
      # plan with zero errors — switches never had an activation path via
      # MCP (only host bridges did, added for exactly this trap).
      #
      # `mark_active` only transitions from pending|active — with
      # whiny_transitions: false a call against a `removed` row returns
      # false rather than raising, so we surface that as an error_result
      # instead of reporting success on an unchanged row.
      def activate_ovn_logical_switch(params)
        switch = account_ovn_logical_switches.find(params[:logical_switch_id])
        unless switch.may_mark_active?
          return error_result("cannot activate a #{switch.state} logical switch")
        end

        gated_result(
          action_category: ::Sdwan::Executors::ActivateOvnLogicalSwitch::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::ActivateOvnLogicalSwitch",
          executor_params: { logical_switch_id: switch.id },
          source_type: "Sdwan::OvnLogicalSwitch",
          source_id: switch.id,
          description: "Activate OVN logical switch #{switch.name.presence || switch.id}"
        ) do |_result|
          { ovn_logical_switch: serialize_ovn_logical_switch(switch.reload) }
        end
      end

      # Mark an OvnLogicalSwitchPort as `active`. Same trap as switches: a
      # port stuck in `pending` is invisible to the compiler even when its
      # parent switch is active.
      def activate_ovn_logical_switch_port(params)
        port = account_ovn_logical_switch_ports.find(params[:port_id])
        unless port.may_mark_active?
          return error_result("cannot activate a #{port.state} logical switch port")
        end

        gated_result(
          action_category: ::Sdwan::Executors::ActivateOvnLogicalSwitchPort::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::ActivateOvnLogicalSwitchPort",
          executor_params: { port_id: port.id },
          source_type: "Sdwan::OvnLogicalSwitchPort",
          source_id: port.id,
          description: "Activate OVN logical switch port #{port.name.presence || port.id}"
        ) do |_result|
          { ovn_logical_switch_port: serialize_ovn_logical_switch_port(port.reload) }
        end
      end

      def compile_ovn_plan(params)
        deployment = account_ovn_deployments.find(params[:deployment_id])
        plan = ::Sdwan::OvnCompiler.compile_for_deployment(deployment)
        success_result(plan: plan)
      end

      # F8-06 — read/prune symmetry.
      def list_ovn_deployments(params)
        scope = account_ovn_deployments
        scope = scope.where(status: params[:status]) if params[:status].present?
        paginated_result(:ovn_deployments, scope, params, direction: :asc) { |d| serialize_ovn_deployment(d) }
      end

      def get_ovn_deployment(params)
        deployment = account_ovn_deployments.find(params[:deployment_id])
        success_result(
          ovn_deployment: serialize_ovn_deployment(deployment).merge(
            logical_switches: deployment.logical_switches.includes(:ports).order(:created_at).map { |s| serialize_ovn_logical_switch_with_ports(s) }
          )
        )
      end

      def list_ovn_logical_switches(params)
        scope = account_ovn_logical_switches
        scope = scope.where(sdwan_ovn_deployment_id: params[:deployment_id]) if params[:deployment_id].present?
        paginated_result(:ovn_logical_switches, scope.includes(:ports), params,
                         direction: :asc) { |s| serialize_ovn_logical_switch_with_ports(s) }
      end

      def delete_ovn_logical_switch_port(params)
        port = account_ovn_logical_switch_ports.find(params[:port_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteOvnLogicalSwitchPort::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteOvnLogicalSwitchPort",
          executor_params: { port_id: port.id },
          source_type: "Sdwan::OvnLogicalSwitchPort",
          source_id: port.id,
          description: "Delete OVN logical switch port #{port.name.presence || port.id}"
        ) do |result|
          { deleted: true, port_id: params[:port_id], name: result.result&.dig(:data, :name) }
        end
      end

      def account_ovn_deployments
        ::Sdwan::OvnDeployment.where(account_id: @account.id)
      end

      def account_ovn_logical_switches
        ::Sdwan::OvnLogicalSwitch.where(account_id: @account.id)
      end

      def account_ovn_logical_switch_ports
        ::Sdwan::OvnLogicalSwitchPort.where(account_id: @account.id)
      end

      def serialize_ovn_logical_switch_with_ports(s)
        serialize_ovn_logical_switch(s).merge(
          ports: s.ports.map { |p| serialize_ovn_logical_switch_port(p) }
        )
      end

      def serialize_ovn_deployment(d)
        {
          id: d.id,
          account_id: d.account_id,
          nb_db_endpoint: d.nb_db_endpoint,
          sb_db_endpoint: d.sb_db_endpoint,
          northd_host: d.northd_host,
          status: d.status,
          settings: d.settings,
          bootstrapped_at: d.bootstrapped_at&.iso8601,
          activated_at: d.activated_at&.iso8601,
          degraded_at: d.degraded_at&.iso8601,
          created_at: d.created_at&.iso8601
        }
      end

      def serialize_ovn_logical_switch(s)
        {
          id: s.id,
          account_id: s.account_id,
          deployment_id: s.sdwan_ovn_deployment_id,
          name: s.name,
          cidr: s.cidr,
          description: s.description,
          settings: s.settings,
          state: s.state,
          activated_at: s.activated_at&.iso8601,
          removed_at: s.removed_at&.iso8601,
          created_at: s.created_at&.iso8601
        }
      end

      def serialize_ovn_logical_switch_port(p)
        {
          id: p.id,
          account_id: p.account_id,
          logical_switch_id: p.sdwan_ovn_logical_switch_id,
          name: p.name,
          kind: p.kind,
          host_node_instance_id: p.host_node_instance_id,
          mac: p.mac,
          addresses: Array(p.addresses),
          state: p.state,
          activated_at: p.activated_at&.iso8601,
          removed_at: p.removed_at&.iso8601,
          created_at: p.created_at&.iso8601
        }
      end

      # ─── Phase O6 — IPFIX collectors (O5) ──────────────────────────────

      def create_ipfix_collector(params)
        candidate = ::Sdwan::IpfixCollector.new(
          account: @account, name: params[:name], host: params[:host],
          port: params[:port].present? ? params[:port].to_i : 4739,
          sampling_rate: params[:sampling_rate].present? ? params[:sampling_rate].to_i : 1
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateIpfixCollector::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateIpfixCollector",
          executor_params: {
            name: params[:name], host: params[:host],
            port: params[:port], sampling_rate: params[:sampling_rate]
          },
          description: "Create IPFIX collector #{params[:name]}"
        ) do |result|
          collector = ::Sdwan::IpfixCollector.find(result.result&.dig(:data, :collector_id))
          { ipfix_collector: serialize_ipfix_collector(collector) }
        end
      end

      def list_ipfix_collectors(params)
        collectors = ::Sdwan::IpfixCollector.where(account_id: @account.id)
        paginated_result(:ipfix_collectors, collectors, params, sort: :name, direction: :asc) { |c| serialize_ipfix_collector(c) }
      end

      # REST twin of IpfixCollectorsController#show, down to the
      # is_winning_collector flag: the topology compiler stamps the account's
      # OLDEST ACTIVE collector onto every ovs-kind HostBridge and ignores the
      # rest, so "which of these is actually exporting" is a question the read
      # surface has to answer or an agent will disable the wrong row.
      #
      # Computed per call rather than memoised on the tool instance: one
      # SdwanTool serves many actions in a session, and a create or a state
      # toggle in between would make a cached winner wrong.
      def get_ipfix_collector(params)
        collector = ::Sdwan::IpfixCollector.where(account_id: @account.id).find(params[:collector_id])

        success_result(
          ipfix_collector: serialize_ipfix_collector_with_winner(collector)
        )
      end

      # The compiler's own selection, re-read on every call rather than
      # memoised on the tool instance: one SdwanTool serves many actions in a
      # session, and a create or a state toggle in between would make a cached
      # winner wrong.
      def serialize_ipfix_collector_with_winner(collector)
        winner_id = ::Sdwan::IpfixCollector.for_account(@account).active.order(:created_at).first&.id
        serialize_ipfix_collector(collector).merge(is_winning_collector: collector.id == winner_id)
      end

      # The non-destructive way to take a collector out of service. Its
      # absence from this surface was the defect (IMP-6bbe5c673c38): an agent
      # asked to stop a mis-sampling collector could only reach
      # delete_ipfix_collector, which cascades the collector's flow_samples.
      #
      # VALIDATE BEFORE THE GATE, per gated_result's contract: an unknown
      # state can never succeed, so it is refused now rather than parked for
      # an operator to approve and watch fail. The wording is the REST twin's
      # verbatim, so the two surfaces naming one operation cannot disagree.
      def update_ipfix_collector(params)
        collector = ::Sdwan::IpfixCollector.where(account_id: @account.id).find(params[:collector_id])
        target = params[:state].to_s
        return error_result("state must be 'active' or 'disabled'") unless ::Sdwan::IpfixCollector::STATES.include?(target)

        # The TRANSITION, not just the string — the same pre-gate check the
        # activate arms make with may_mark_active?. Both events accept both
        # source states today, so this refuses nothing yet; it is here so that
        # narrowing the state machine surfaces as an immediate refusal rather
        # than as a doomed operation an operator approves and watches fail.
        permitted = target == "active" ? collector.may_enable? : collector.may_disable?
        return error_result("cannot move IPFIX collector from #{collector.state} to #{target}") unless permitted

        gated_result(
          action_category: ::Sdwan::Executors::UpdateIpfixCollector::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::UpdateIpfixCollector",
          executor_params: { collector_id: collector.id, state: target },
          source_type: "Sdwan::IpfixCollector",
          source_id: collector.id,
          description: "Set IPFIX collector #{collector.name.presence || collector.id} to #{target}"
        ) do |_result|
          # With the winner flag: disabling the winning collector silently
          # PROMOTES the next-oldest active row, and an agent that just
          # stopped one export needs to see whether another took over.
          { ipfix_collector: serialize_ipfix_collector_with_winner(collector.reload) }
        end
      end

      def serialize_ipfix_collector(c)
        {
          id: c.id,
          account_id: c.account_id,
          name: c.name,
          host: c.host,
          port: c.port,
          sampling_rate: c.sampling_rate,
          state: c.state,
          target_endpoint: c.target_endpoint,
          settings: c.settings,
          created_at: c.created_at&.iso8601
        }
      end

      # ─── Phase O6 follow-up — OVN ACLs ──────────────────────────────

      def create_ovn_acl(params)
        switch = account_ovn_logical_switches.find(params[:logical_switch_id])
        # The auto-activate that used to sit here now runs INSIDE the
        # executor, so the gate stands in front of both the write and the
        # activation rather than between them.
        candidate = switch.acls.new(
          account: @account, name: params[:name], direction: params[:direction].to_s,
          priority: params[:priority].present? ? params[:priority].to_i : ::Sdwan::OvnAcl::DEFAULT_PRIORITY,
          match: params[:match], action: params[:acl_action].to_s
        )
        return error_result(candidate.errors.full_messages.join("; ")) unless candidate.valid?

        gated_result(
          action_category: ::Sdwan::Executors::CreateOvnAcl::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::CreateOvnAcl",
          executor_params: {
            logical_switch_id: switch.id, name: params[:name],
            direction: params[:direction].to_s, priority: params[:priority],
            match: params[:match], acl_action: params[:acl_action].to_s
          },
          source_type: "Sdwan::OvnLogicalSwitch",
          source_id: switch.id,
          description: "Create OVN ACL #{params[:name]} (#{params[:acl_action]} #{params[:match]})"
        ) do |result|
          acl = ::Sdwan::OvnAcl.find(result.result&.dig(:data, :acl_id))
          { ovn_acl: serialize_ovn_acl(acl) }
        end
      end

      def delete_ovn_acl(params)
        acl = ::Sdwan::OvnAcl.where(account_id: @account.id).find(params[:acl_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteOvnAcl::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteOvnAcl",
          executor_params: { acl_id: acl.id },
          source_type: "Sdwan::OvnAcl",
          source_id: acl.id,
          description: "Delete OVN ACL #{acl.name.presence || acl.id}"
        ) do |result|
          { deleted: true, acl_id: params[:acl_id], name: result.result&.dig(:data, :name) }
        end
      end

      def delete_ovn_logical_switch(params)
        sw = account_ovn_logical_switches.find(params[:logical_switch_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteOvnLogicalSwitch::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteOvnLogicalSwitch",
          executor_params: { logical_switch_id: sw.id },
          source_type: "Sdwan::OvnLogicalSwitch",
          source_id: sw.id,
          description: "Delete OVN logical switch #{sw.name.presence || sw.id}"
        ) do |result|
          { deleted: true, logical_switch_id: params[:logical_switch_id],
            name: result.result&.dig(:data, :name) }
        end
      end

      def delete_ovn_deployment(params)
        dep = ::Sdwan::OvnDeployment.where(account_id: @account.id).find(params[:deployment_id])
        # OvnDeployment is the per-account OVN control plane row and has no
        # `name` column/method (unlike acls/switches/ports) — report its
        # status instead so a botched deployment can still be torn down.
        gated_result(
          action_category: ::Sdwan::Executors::DeleteOvnDeployment::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteOvnDeployment",
          executor_params: { deployment_id: dep.id },
          source_type: "Sdwan::OvnDeployment",
          source_id: dep.id,
          description: "Delete the OVN control-plane deployment #{dep.id}"
        ) do |result|
          { deleted: true, deployment_id: params[:deployment_id],
            status: result.result&.dig(:data, :status) }
        end
      end

      def delete_ipfix_collector(params)
        col = ::Sdwan::IpfixCollector.where(account_id: @account.id).find(params[:collector_id])
        gated_result(
          action_category: ::Sdwan::Executors::DeleteIpfixCollector::ACTION_CATEGORY,
          executor_class: "Sdwan::Executors::DeleteIpfixCollector",
          executor_params: { collector_id: col.id },
          source_type: "Sdwan::IpfixCollector",
          source_id: col.id,
          description: "Delete IPFIX collector #{col.name.presence || col.id}"
        ) do |result|
          { deleted: true, collector_id: params[:collector_id], name: result.result&.dig(:data, :name) }
        end
      end

      def list_ovn_acls(params)
        scope = ::Sdwan::OvnAcl.where(account_id: @account.id)
        scope = scope.where(sdwan_ovn_logical_switch_id: params[:logical_switch_id]) if params[:logical_switch_id].present?
        if params[:sdwan_ovn_deployment_id].present?
          switch_ids = account_ovn_logical_switches
                         .where(sdwan_ovn_deployment_id: params[:sdwan_ovn_deployment_id])
                         .pluck(:id)
          scope = scope.where(sdwan_ovn_logical_switch_id: switch_ids)
        end
        # ORDER DIFFERS FROM THE COMPILER AT EQUAL PRIORITY, deliberately.
        # Sdwan::OvnCompiler#acls_for sorts by [-priority, name] (ovn_compiler.rb:161)
        # so the plan emits in OVN evaluation order; a keyset cursor can carry ONE
        # sort column plus the id tiebreak, so this listing walks priority desc with
        # the UUIDv7 id breaking ties instead of the name. Priority defaults to 1000,
        # so ties are the common case: read the compiled plan, not this listing, to
        # reason about which of two equal-priority ACLs OVN applies first.
        paginated_result(:ovn_acls, scope, params, sort: :priority,
                         filters: {
                           logical_switch_id: params[:logical_switch_id],
                           sdwan_ovn_deployment_id: params[:sdwan_ovn_deployment_id]
                         }.compact) { |a| serialize_ovn_acl(a) }
      end

      def serialize_ovn_acl(a)
        {
          id: a.id,
          account_id: a.account_id,
          logical_switch_id: a.sdwan_ovn_logical_switch_id,
          name: a.name,
          direction: a.direction,
          priority: a.priority,
          match: a.match,
          action: a.action,
          state: a.state,
          activated_at: a.activated_at&.iso8601,
          removed_at: a.removed_at&.iso8601,
          created_at: a.created_at&.iso8601
        }
      end
    end
  end
end
