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
      REQUIRED_PERMISSION = "sdwan.networks.read"

      ACTION_PERMISSIONS = {
        "system_sdwan_list_networks"   => "sdwan.networks.read",
        "system_sdwan_get_network"     => "sdwan.networks.read",
        "system_sdwan_create_network"  => "sdwan.networks.manage",
        "system_sdwan_update_network"  => "sdwan.networks.manage",
        "system_sdwan_delete_network"  => "sdwan.networks.manage",
        "system_sdwan_list_peers"      => "sdwan.peers.read",
        "system_sdwan_get_peer"        => "sdwan.peers.read",
        "system_sdwan_attach_peer"     => "sdwan.peers.manage",
        "system_sdwan_detach_peer"     => "sdwan.peers.manage",
        "system_sdwan_get_topology"    => "sdwan.peers.read",
        # Slice 2: firewall
        "system_sdwan_list_firewall_rules"  => "sdwan.firewall.read",
        "system_sdwan_get_firewall_rule"    => "sdwan.firewall.read",
        "system_sdwan_create_firewall_rule" => "sdwan.firewall.manage",
        "system_sdwan_update_firewall_rule" => "sdwan.firewall.manage",
        "system_sdwan_delete_firewall_rule" => "sdwan.firewall.manage",
        # Slice 4: user VPN
        "system_sdwan_list_access_grants"   => "sdwan.user_devices.manage",
        "system_sdwan_create_access_grant"  => "sdwan.user_devices.manage",
        "system_sdwan_revoke_access_grant"  => "sdwan.user_devices.manage",
        "system_sdwan_list_user_devices"    => "sdwan.user_devices.manage",
        "system_sdwan_issue_user_device"    => "sdwan.user_devices.manage",
        "system_sdwan_revoke_user_device"   => "sdwan.user_devices.manage",
        # Slice 6: federation scaffold
        "system_sdwan_list_federation_peers"   => "sdwan.federation.read",
        "system_sdwan_get_federation_peer"     => "sdwan.federation.read",
        "system_sdwan_propose_federation_peer" => "sdwan.federation.manage",
        "system_sdwan_accept_federation_peer"  => "sdwan.federation.manage",
        "system_sdwan_revoke_federation_peer"  => "sdwan.federation.manage",
        "system_sdwan_federation_scan"         => "sdwan.federation.read",
        # Slice 9a: routing layer (static subnet routing)
        "system_sdwan_set_peer_lan_subnets"        => "sdwan.routing.manage",
        "system_sdwan_set_network_routing_mode"    => "sdwan.routing.manage",
        "system_sdwan_list_subnet_advertisements"  => "sdwan.routing.read",
        "system_sdwan_get_routing_summary"         => "sdwan.routing.read",
        # Slice 9b: virtual IPs
        "system_sdwan_create_virtual_ip"           => "sdwan.vips.manage",
        "system_sdwan_list_virtual_ips"            => "sdwan.vips.read",
        "system_sdwan_get_virtual_ip"              => "sdwan.vips.read",
        "system_sdwan_update_virtual_ip"           => "sdwan.vips.manage",
        "system_sdwan_delete_virtual_ip"           => "sdwan.vips.manage",
        "system_sdwan_failover_virtual_ip"         => "sdwan.vips.manage",
        "system_sdwan_list_vip_assignments"        => "sdwan.vips.read",
        # Slice 9c: iBGP / FRR control plane
        "system_sdwan_get_account_bgp"             => "sdwan.routing.read",
        "system_sdwan_set_account_as_number"       => "sdwan.routing.manage",
        "system_sdwan_get_bgp_sessions"            => "sdwan.routing.read",
        "system_sdwan_get_bgp_config_for_peer"     => "sdwan.routing.read",
        # Slice 9e: route policies
        "system_sdwan_list_route_policies"         => "sdwan.route_policies.read",
        "system_sdwan_get_route_policy"            => "sdwan.route_policies.read",
        "system_sdwan_create_route_policy"         => "sdwan.route_policies.manage",
        "system_sdwan_update_route_policy"         => "sdwan.route_policies.manage",
        "system_sdwan_delete_route_policy"         => "sdwan.route_policies.manage",
        "system_sdwan_compile_route_policy"        => "sdwan.route_policies.read",
        # Slice 7b: hub port mappings (DNAT for v4-only clients)
        "system_sdwan_list_port_mappings"          => "sdwan.port_mappings.read",
        "system_sdwan_get_port_mapping"            => "sdwan.port_mappings.read",
        "system_sdwan_create_port_mapping"         => "sdwan.port_mappings.manage",
        "system_sdwan_update_port_mapping"         => "sdwan.port_mappings.manage",
        "system_sdwan_delete_port_mapping"         => "sdwan.port_mappings.manage",
        # Phase O6 — host bridges (O1) + OVN deployment/switches/ports (O3) + IPFIX (O5)
        "system_sdwan_create_host_bridge"          => "sdwan.host_bridges.manage",
        "system_sdwan_list_host_bridges"           => "sdwan.host_bridges.read",
        "system_sdwan_create_ovn_deployment"       => "sdwan.ovn.manage",
        "system_sdwan_create_ovn_logical_switch"   => "sdwan.ovn.manage",
        "system_sdwan_create_ovn_logical_switch_port" => "sdwan.ovn.manage",
        "system_sdwan_compile_ovn_plan"            => "sdwan.ovn.read",
        "system_sdwan_create_ipfix_collector"      => "sdwan.ipfix.manage",
        "system_sdwan_list_ipfix_collectors"       => "sdwan.ipfix.read"
      }.freeze

      def self.definition
        {
          name: "sdwan",
          description: "SDWAN overlay operations: networks, peers, topology compilation, firewall rules, key rotation",
          parameters: {
            action: { type: "string", required: true, description: "Action to perform" },
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
            firewall_action: { type: "string", required: false, description: "accept | drop | reject" },
            direction: { type: "string", required: false, description: "ingress | egress | both" },
            protocol: { type: "string", required: false, description: "any | tcp | udp | icmp6" },
            src_selector: { type: "object", required: false },
            dst_selector: { type: "object", required: false },
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
            parameters: { options: { type: "object", required: false } }
          },
          "system_sdwan_get_network" => {
            description: "Fetch an SDWAN network by id",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_create_network" => {
            description: "Create a new SDWAN overlay network. CIDR (/64) is allocated automatically.",
            parameters: {
              name: { type: "string", required: true },
              description: { type: "string", required: false },
              options: { type: "object", required: false, description: "settings hash (mtu, topology_strategy, ...)" }
            }
          },
          "system_sdwan_update_network" => {
            description: "Update an SDWAN network's name/description/status/settings",
            parameters: {
              network_id: { type: "string", required: true },
              options: { type: "object", required: false }
            }
          },
          "system_sdwan_delete_network" => {
            description: "Delete an SDWAN network and all its peers + keys (destructive)",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_list_peers" => {
            description: "List peers in an SDWAN network",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_get_peer" => {
            description: "Fetch a single peer with its current key + endpoint",
            parameters: { peer_id: { type: "string", required: true } }
          },
          "system_sdwan_attach_peer" => {
            description: "Attach a NodeInstance to an SDWAN network (allocates address, generates keypair). Slice 7a: prefer endpoint_host_v6/v4 over the legacy endpoint_host for new hubs.",
            parameters: {
              network_id: { type: "string", required: true },
              node_instance_id: { type: "string", required: true },
              publicly_reachable: { type: "boolean", required: false },
              endpoint_host: { type: "string", required: false, description: "Legacy single-endpoint field; prefer endpoint_host_v6/v4 for new hubs" },
              endpoint_host_v6: { type: "string", required: false, description: "IPv6 literal or hostname (slice 7a). v6-preferred when both this and endpoint_host_v4 are set." },
              endpoint_host_v4: { type: "string", required: false, description: "IPv4 literal or hostname (slice 7a). Used as fallback if v6 dial fails." },
              endpoint_port: { type: "integer", required: false },
              listen_port: { type: "integer", required: false }
            }
          },
          "system_sdwan_detach_peer" => {
            description: "Detach a peer (revokes key, removes membership)",
            parameters: { peer_id: { type: "string", required: true } }
          },
          "system_sdwan_get_topology" => {
            description: "Return the compiled per-peer view for an SDWAN network — what each peer would receive on its next config pull",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_list_firewall_rules" => {
            description: "List firewall rules in an SDWAN network (priority-ordered)",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_get_firewall_rule" => {
            description: "Fetch a single firewall rule, including its compiled nft preview",
            parameters: { firewall_rule_id: { type: "string", required: true } }
          },
          "system_sdwan_create_firewall_rule" => {
            description: "Create a firewall rule. Selectors accept {peer_id|tag|cidr|all} primitives. Port range is optional and only applies to tcp/udp.",
            parameters: {
              network_id: { type: "string", required: true },
              name: { type: "string", required: true },
              firewall_action: { type: "string", required: false, description: "accept (default) | drop | reject" },
              direction: { type: "string", required: false, description: "ingress | egress | both (default)" },
              protocol: { type: "string", required: false, description: "any (default) | tcp | udp | icmp6" },
              priority: { type: "integer", required: false },
              src_selector: { type: "object", required: false },
              dst_selector: { type: "object", required: false },
              port_from: { type: "integer", required: false },
              port_to:   { type: "integer", required: false }
            }
          },
          "system_sdwan_update_firewall_rule" => {
            description: "Update a firewall rule (any field). Pass port_from/port_to as null to clear the port range.",
            parameters: {
              firewall_rule_id: { type: "string", required: true },
              name: { type: "string", required: false },
              firewall_action: { type: "string", required: false },
              direction: { type: "string", required: false },
              protocol: { type: "string", required: false },
              priority: { type: "integer", required: false },
              src_selector: { type: "object", required: false },
              dst_selector: { type: "object", required: false },
              port_from: { type: "integer", required: false },
              port_to:   { type: "integer", required: false },
              enabled:   { type: "boolean", required: false }
            }
          },
          "system_sdwan_delete_firewall_rule" => {
            description: "Delete a firewall rule (immediate; takes effect on next agent reconcile)",
            parameters: { firewall_rule_id: { type: "string", required: true } }
          },
          # Slice 4: user VPN
          "system_sdwan_list_access_grants" => {
            description: "List user access grants on an SDWAN network",
            parameters: { network_id: { type: "string", required: true } }
          },
          "system_sdwan_create_access_grant" => {
            description: "Grant a user access to an SDWAN network (precondition for issuing them VPN devices)",
            parameters: {
              network_id: { type: "string", required: true },
              user_id:    { type: "string", required: true },
              tags:       { type: "array",  required: false }
            }
          },
          "system_sdwan_revoke_access_grant" => {
            description: "Revoke an access grant — cascades to revoke all the user's devices on this network",
            parameters: {
              access_grant_id: { type: "string", required: true },
              reason:          { type: "string", required: false }
            }
          },
          "system_sdwan_list_user_devices" => {
            description: "List a user's VPN devices on an SDWAN network (per access grant)",
            parameters: { access_grant_id: { type: "string", required: true } }
          },
          "system_sdwan_issue_user_device" => {
            description: "Issue a fresh WireGuard config for a user. Returns a one-shot bootstrap_url (15-min expiry, single-use) — copy it to the user out-of-band.",
            parameters: {
              access_grant_id: { type: "string", required: true },
              label:           { type: "string", required: true, description: "Operator-supplied device label, e.g. 'phone' or 'work-laptop'" }
            }
          },
          "system_sdwan_revoke_user_device" => {
            description: "Revoke a user device (immediate; agent drops it from the hub view on next reconcile)",
            parameters: {
              user_device_id: { type: "string", required: true },
              reason:         { type: "string", required: false }
            }
          },
          # Slice 6: federation scaffold (data-only in v1)
          "system_sdwan_list_federation_peers" => {
            description: "List federation peer records (proposed cross-Powernode-instance overlay peerings)",
            parameters: { options: { type: "object", required: false } }
          },
          "system_sdwan_get_federation_peer" => {
            description: "Fetch a federation peer with its v1-allowed transitions",
            parameters: { federation_peer_id: { type: "string", required: true } }
          },
          "system_sdwan_propose_federation_peer" => {
            description: "Propose a new federation peer. Status starts at 'proposed'. With generate_token: true (Phase 11b), generates a single-use acceptance token (plaintext returned ONCE) — Account A operator copies it out-of-band to Account B operator who pastes it into system_sdwan_accept_federation_peer.",
            parameters: {
              remote_instance_url: { type: "string", required: true },
              remote_instance_id: { type: "string", required: false },
              remote_account_id: { type: "string", required: false },
              remote_prefix_advertisement: { type: "string", required: false, description: "/48|/56|/64 ULA prefix the remote instance claims" },
              generate_token: { type: "boolean", required: false, description: "When true, generate a single-use acceptance token (Phase 11b token round-trip handshake). Plaintext returned ONCE — not recoverable." },
              token_ttl_seconds: { type: "integer", required: false, description: "Token expiry window in seconds (default 7 days)" }
            }
          },
          "system_sdwan_accept_federation_peer" => {
            description: "Transition a proposed federation peer to accepted (drill-mode v1 — no cross-account auth handshake yet; future Phase 11b adds token round-trip). Sets signed_at + audit metadata. Returns the updated peer.",
            parameters: {
              federation_peer_id: { type: "string", required: true },
              acceptance_token:   { type: "string", required: false, description: "Forward-compat: token from the proposing-account operator. v1 records its presence in metadata; v11b verifies." }
            }
          },
          "system_sdwan_revoke_federation_peer" => {
            description: "Revoke a federation peer (terminal in v1)",
            parameters: {
              federation_peer_id: { type: "string", required: true },
              reason: { type: "string", required: false }
            }
          },
          "system_sdwan_federation_scan" => {
            description: "Run the federation governance scanner — flags prefix overlaps and stale-accepted rows",
            parameters: {}
          },
          # Slice 9a — routing layer (static subnet routing baseline)
          "system_sdwan_set_peer_lan_subnets" => {
            description: "Declare the external LAN prefixes a peer can route to. In static mode, the topology compiler folds these into AllowedIPs so other peers route across the SDWAN to reach them. CIDR strings (v4 or v6).",
            parameters: {
              peer_id: { type: "string", required: true },
              lan_subnets: { type: "array", required: true, description: "Array of CIDR strings. Empty array clears." }
            }
          },
          "system_sdwan_set_network_routing_mode" => {
            description: "Set a network's routing protocol: 'static' (declarative AllowedIPs, no daemon) or 'ibgp' (slice 9c FRR + dynamic distribution). Until slice 9c lands, only 'static' is fully functional.",
            parameters: {
              network_id: { type: "string", required: true },
              routing_protocol: { type: "string", required: true, description: "static | ibgp" }
            }
          },
          "system_sdwan_list_subnet_advertisements" => {
            description: "List route advertisements for a network — declared lan_subnets, VIP announcements (slice 9b), and BGP-learned routes (slice 9c) unified. Filterable by source.",
            parameters: {
              network_id: { type: "string", required: true },
              source: { type: "string", required: false, description: "Filter: declared_lan_subnet | virtual_ip | learned_via_bgp" },
              include_withdrawn: { type: "boolean", required: false }
            }
          },
          "system_sdwan_get_routing_summary" => {
            description: "Routing-layer summary for a network: protocol, peer count, advertised prefixes, hub redundancy, BGP session count. Cheap; safe to poll.",
            parameters: { network_id: { type: "string", required: true } }
          },
          # Slice 9b — Virtual IPs
          "system_sdwan_create_virtual_ip" => {
            description: "Create a Virtual IP. Static mode (anycast=false) = single primary holder + ordered failover. Anycast mode (slice 9c iBGP) = all holders advertise simultaneously. CIDR is typically /32 (v4) or /128 (v6).",
            parameters: {
              network_id: { type: "string", required: true },
              name: { type: "string", required: true },
              cidr: { type: "string", required: true },
              holder_peer_ids: { type: "array", required: true, description: "Ordered: first entry is primary holder when anycast=false." },
              failover_holder_peer_ids: { type: "array", required: false },
              anycast: { type: "boolean", required: false },
              description: { type: "string", required: false },
              tags: { type: "array", required: false },
              advertised_med: { type: "integer", required: false },
              advertised_local_pref: { type: "integer", required: false }
            }
          },
          "system_sdwan_list_virtual_ips" => {
            description: "List Virtual IPs in an SDWAN network",
            parameters: {
              network_id: { type: "string", required: true },
              state: { type: "string", required: false, description: "Filter: pending|active|failing_over|unassigned|error" }
            }
          },
          "system_sdwan_get_virtual_ip" => {
            description: "Fetch a Virtual IP with its assignment history (last 20 transitions)",
            parameters: { virtual_ip_id: { type: "string", required: true } }
          },
          "system_sdwan_update_virtual_ip" => {
            description: "Update a Virtual IP's holders, failover candidates, anycast mode, advertised_med/local_pref, etc. Holder changes are recorded as 'holder_changed' assignment rows.",
            parameters: {
              virtual_ip_id: { type: "string", required: true },
              holder_peer_ids: { type: "array", required: false },
              failover_holder_peer_ids: { type: "array", required: false },
              anycast: { type: "boolean", required: false },
              description: { type: "string", required: false },
              tags: { type: "array", required: false },
              advertised_med: { type: "integer", required: false },
              advertised_local_pref: { type: "integer", required: false }
            }
          },
          "system_sdwan_delete_virtual_ip" => {
            description: "Delete a Virtual IP. Closes all active assignments + destroys the row.",
            parameters: { virtual_ip_id: { type: "string", required: true } }
          },
          "system_sdwan_failover_virtual_ip" => {
            description: "Manual failover for a non-anycast VIP — promotes the head of failover_holder_peer_ids to holder. Anycast VIPs don't fail over (all holders are active simultaneously).",
            parameters: { virtual_ip_id: { type: "string", required: true } }
          },
          "system_sdwan_list_vip_assignments" => {
            description: "Audit-grade history of VIP holder transitions for a Virtual IP",
            parameters: { virtual_ip_id: { type: "string", required: true } }
          },
          # ─── Slice 9c: iBGP routing control plane ──────────────────────
          "system_sdwan_get_account_bgp" => {
            description: "Read the account's iBGP config (AS number, router-id strategy, default local-pref). Returns null if AS not yet allocated.",
            parameters: {}
          },
          "system_sdwan_set_account_as_number" => {
            description: "Allocate the account's private AS number (RFC 6996 4-byte private range). Idempotent — returns existing AccountBgp if already allocated.",
            parameters: {}
          },
          "system_sdwan_get_bgp_sessions" => {
            description: "Live BGP session matrix across all networks (or filtered to one network). Returns observed sessions reported by agents — not desired state.",
            parameters: {
              network_id: { type: "string", required: false, description: "Filter to one network" },
              state: { type: "string", required: false, description: "idle | connect | active | opensent | openconfirm | established" }
            }
          },
          "system_sdwan_get_bgp_config_for_peer" => {
            description: "Compile the full BGP config for one peer including frr.conf text. Useful for debugging routing issues.",
            parameters: { peer_id: { type: "string", required: true } }
          },
          # ─── Slice 9e: route policies ──────────────────────────────────
          "system_sdwan_list_route_policies" => {
            description: "List SDWAN route policies for the current account, optionally filtered by scope/direction.",
            parameters: {
              scope: { type: "string", required: false, description: "account | network | peer" },
              direction: { type: "string", required: false, description: "import | export" }
            }
          },
          "system_sdwan_get_route_policy" => {
            description: "Fetch a route policy by id, including its full statement list.",
            parameters: { route_policy_id: { type: "string", required: true } }
          },
          "system_sdwan_create_route_policy" => {
            description: "Create a route policy. statements is an ordered list of {match: {...}, action: {...}} objects. Compile output appears in TopologyCompiler#bgp.policies.",
            parameters: {
              name: { type: "string", required: true },
              scope: { type: "string", required: true, description: "account | network | peer" },
              direction: { type: "string", required: true, description: "import | export" },
              statements: { type: "array", required: true, description: "Ordered list of {match,action} hashes" },
              scope_resource_id: { type: "string", required: false },
              description: { type: "string", required: false },
              enabled: { type: "boolean", required: false }
            }
          },
          "system_sdwan_update_route_policy" => {
            description: "Update a route policy's name, scope, statements, or enabled state.",
            parameters: {
              route_policy_id: { type: "string", required: true },
              options: { type: "object", required: true }
            }
          },
          "system_sdwan_delete_route_policy" => {
            description: "Delete a route policy. The next agent reconcile removes the corresponding route-map from frr.conf.",
            parameters: { route_policy_id: { type: "string", required: true } }
          },
          "system_sdwan_compile_route_policy" => {
            description: "Compile policies in the context of one peer; returns the FRR fragment (prefix-lists, route-maps, neighbor assignments) that would land in that peer's frr.conf. Useful for 'show me what this policy will do' previews.",
            parameters: { peer_id: { type: "string", required: true } }
          },
          # ─── Slice 7b: hub port mappings ──────────────────────────────────
          "system_sdwan_list_port_mappings" => {
            description: "List hub DNAT port mappings for a network. Optionally filter by hub_peer_id.",
            parameters: {
              network_id: { type: "string", required: true },
              hub_peer_id: { type: "string", required: false }
            }
          },
          "system_sdwan_get_port_mapping" => {
            description: "Fetch a port mapping by id.",
            parameters: { port_mapping_id: { type: "string", required: true } }
          },
          "system_sdwan_create_port_mapping" => {
            description: "Create a hub DNAT mapping. Exactly one of target_peer_id or target_virtual_ip_id must be set. The hub peer must be in the same network as the target.",
            parameters: {
              network_id: { type: "string", required: true },
              hub_peer_id: { type: "string", required: true },
              name: { type: "string", required: true },
              listen_port: { type: "integer", required: true },
              protocol: { type: "string", required: true, description: "tcp | udp" },
              target_peer_id: { type: "string", required: false },
              target_virtual_ip_id: { type: "string", required: false },
              target_port: { type: "integer", required: false, description: "Defaults to listen_port if omitted" },
              description: { type: "string", required: false },
              enabled: { type: "boolean", required: false }
            }
          },
          "system_sdwan_update_port_mapping" => {
            description: "Update a port mapping's name, target, ports, protocol, or enabled state.",
            parameters: {
              port_mapping_id: { type: "string", required: true },
              options: { type: "object", required: true }
            }
          },
          "system_sdwan_delete_port_mapping" => {
            description: "Delete a port mapping. Agent removes the corresponding nft DNAT rule on next reconcile.",
            parameters: { port_mapping_id: { type: "string", required: true } }
          },
          # ─── Phase O6 — host bridges (O1) ──────────────────────────────────
          "system_sdwan_create_host_bridge" => {
            description: "Allocate a HostBridge for a NodeInstance via Sdwan::HostBridgeAllocator. Idempotent — returns the existing bridge of the requested kind on this host if one already exists. When `kind` is omitted the allocator picks 'ovs' for heavyweight hosts and 'linux' for lightweight hosts based on the host's network_profile.",
            parameters: {
              node_instance_id: { type: "string", required: true },
              kind: { type: "string", required: false, description: "linux | ovs (defaults to host's network_profile mapping)" }
            }
          },
          "system_sdwan_list_host_bridges" => {
            description: "List HostBridges for the current account. Optionally filter by node_instance_id.",
            parameters: {
              node_instance_id: { type: "string", required: false }
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
              deployment_id: { type: "string", required: true },
              name: { type: "string", required: true },
              cidr: { type: "string", required: false, description: "Optional subnet CIDR (sets up DHCP on the switch when present)" },
              description: { type: "string", required: false },
              settings: { type: "object", required: false }
            }
          },
          "system_sdwan_create_ovn_logical_switch_port" => {
            description: "Create an OVN logical switch port. `kind` drives compiler choices: vm | container = host-backed (host_node_instance_id required for proper placement); external = uplink/transit (no host required, gets lsp-set-type localnet by default). MAC is auto-generated (locally-administered `02:` prefix) when blank.",
            parameters: {
              logical_switch_id: { type: "string", required: true },
              name: { type: "string", required: true },
              kind: { type: "string", required: true, description: "vm | container | external" },
              host_node_instance_id: { type: "string", required: false, description: "Required for vm/container ports; ignored for external" },
              addresses: { type: "array", required: false, description: "Array of IPv4/IPv6 strings; appended to the OVN `addresses=` line" },
              mac: { type: "string", required: false, description: "MAC in `xx:xx:xx:xx:xx:xx` form; auto-generated when blank" }
            }
          },
          "system_sdwan_compile_ovn_plan" => {
            description: "Compile the structured ovn-nbctl command plan for an OvnDeployment via Sdwan::OvnCompiler. Returns the full plan (deployment_id, plan: array of {cmd, args}, compiled_at). The compiler does NOT execute — it returns the plan as data for an executor or operator to replay against the NB DB.",
            parameters: {
              deployment_id: { type: "string", required: true }
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
            parameters: {}
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
        # Slice 9a routing actions
        when "system_sdwan_set_peer_lan_subnets"       then set_peer_lan_subnets(params)
        when "system_sdwan_set_network_routing_mode"   then set_network_routing_mode(params)
        when "system_sdwan_list_subnet_advertisements" then list_subnet_advertisements(params)
        when "system_sdwan_get_routing_summary"        then get_routing_summary(params)
        # Slice 9c iBGP actions
        when "system_sdwan_get_account_bgp"            then get_account_bgp(params)
        when "system_sdwan_set_account_as_number"     then set_account_as_number(params)
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
        when "system_sdwan_create_ovn_deployment"          then create_ovn_deployment(params)
        when "system_sdwan_create_ovn_logical_switch"      then create_ovn_logical_switch(params)
        when "system_sdwan_create_ovn_logical_switch_port" then create_ovn_logical_switch_port(params)
        when "system_sdwan_compile_ovn_plan"               then compile_ovn_plan(params)
        when "system_sdwan_create_ipfix_collector"         then create_ipfix_collector(params)
        when "system_sdwan_list_ipfix_collectors"          then list_ipfix_collectors(params)
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

      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      # === Networks ===

      def list_networks(_params)
        scope = ::Sdwan::Network.where(account_id: @account.id).order(:name)
        success_result(networks: scope.map { |n| serialize_network(n) }, count: scope.size)
      end

      def get_network(params)
        network = account_networks.find(params[:network_id])
        success_result(network: serialize_network_full(network))
      end

      def create_network(params)
        opts = params[:options] || {}
        network = ::Sdwan::Network.create!(
          account_id: @account.id,
          name: params[:name],
          description: params[:description],
          settings: opts.is_a?(Hash) ? opts : {}
        )
        success_result(network: serialize_network_full(network))
      end

      def update_network(params)
        network = account_networks.find(params[:network_id])
        opts = params[:options] || {}
        update_attrs = {}
        update_attrs[:name]        = opts["name"]        if opts.is_a?(Hash) && opts["name"]
        update_attrs[:description] = opts["description"] if opts.is_a?(Hash) && opts["description"]
        update_attrs[:status]      = opts["status"]      if opts.is_a?(Hash) && opts["status"]
        update_attrs[:settings]    = opts["settings"]    if opts.is_a?(Hash) && opts["settings"].is_a?(Hash)
        network.update!(update_attrs) if update_attrs.any?
        success_result(network: serialize_network_full(network.reload))
      end

      def delete_network(params)
        network = account_networks.find(params[:network_id])
        network.destroy!
        success_result(deleted: true, id: network.id)
      end

      # === Peers ===

      def list_peers(params)
        network = account_networks.find(params[:network_id])
        peers = network.peers.includes(:keys).order(:created_at)
        success_result(peers: peers.map { |p| serialize_peer(p) }, count: peers.size)
      end

      def get_peer(params)
        peer = account_peers.find(params[:peer_id])
        success_result(peer: serialize_peer_full(peer))
      end

      def attach_peer(params)
        network = account_networks.find(params[:network_id])
        node_instance = ::System::NodeInstance.joins(:node)
                                              .where(system_nodes: { account_id: @account.id })
                                              .find(params[:node_instance_id])

        peer = ::Sdwan::PeerEnroller.call(
          network: network,
          node_instance: node_instance,
          publicly_reachable: params[:publicly_reachable] || false,
          endpoint_host: params[:endpoint_host],
          endpoint_host_v6: params[:endpoint_host_v6],
          endpoint_host_v4: params[:endpoint_host_v4],
          endpoint_port: params[:endpoint_port],
          listen_port: params[:listen_port] || 51820
        )

        success_result(attached: true, peer: serialize_peer_full(peer))
      end

      def detach_peer(params)
        peer = account_peers.find(params[:peer_id])
        peer.destroy!
        success_result(detached: true, id: peer.id)
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
        rules = network.firewall_rules.ordered
        success_result(
          network_id: network.id,
          firewall_rules: rules.map { |r| serialize_rule(r) },
          count: rules.size,
          default_policy: ::Sdwan::FirewallCompiler.new(network).default_policy
        )
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

      def create_firewall_rule(params)
        network = account_networks.find(params[:network_id])
        rule = network.firewall_rules.new(account_id: @account.id)
        assign_rule_attrs(rule, params)
        rule.save!
        success_result(firewall_rule: serialize_rule(rule.reload))
      end

      def update_firewall_rule(params)
        rule = account_firewall_rules.find(params[:firewall_rule_id])
        assign_rule_attrs(rule, params)
        rule.save!
        success_result(firewall_rule: serialize_rule(rule.reload))
      end

      def delete_firewall_rule(params)
        rule = account_firewall_rules.find(params[:firewall_rule_id])
        rule.destroy!
        success_result(deleted: true, id: rule.id)
      end

      # === Helpers ===

      def assign_rule_attrs(rule, params)
        rule.name      = params[:name]              if params.key?(:name) && params[:name]
        rule.priority  = params[:priority].to_i     if params.key?(:priority) && params[:priority]
        rule.action    = params[:firewall_action]   if params.key?(:firewall_action) && params[:firewall_action]
        rule.direction = params[:direction]         if params.key?(:direction) && params[:direction]
        rule.protocol  = params[:protocol]          if params.key?(:protocol) && params[:protocol]
        rule.src_selector = params[:src_selector]   if params.key?(:src_selector) && !params[:src_selector].nil?
        rule.dst_selector = params[:dst_selector]   if params.key?(:dst_selector) && !params[:dst_selector].nil?
        rule.enabled   = params[:enabled]           if params.key?(:enabled) && !params[:enabled].nil?
        if params[:port_from] && params[:port_to]
          rule.port_range_hash = { from: params[:port_from].to_i, to: params[:port_to].to_i }
        end
      end

      def account_firewall_rules
        ::Sdwan::FirewallRule.where(account_id: @account.id)
      end

      # === Access Grants ===

      def list_access_grants(params)
        network = account_networks.find(params[:network_id])
        grants = network.access_grants.includes(:user, :user_devices).order(created_at: :desc)
        success_result(grants: grants.map { |g| serialize_grant(g) }, count: grants.size)
      end

      def create_access_grant(params)
        network = account_networks.find(params[:network_id])
        user = ::User.where(account_id: @account.id).find(params[:user_id])
        grant = network.access_grants.find_or_initialize_by(user_id: user.id)
        grant.assign_attributes(
          account_id: @account.id,
          status: "active",
          granted_by_id: @user&.id,
          granted_at: Time.current,
          tags: Array(params[:tags]),
          revoked_at: nil,
          revocation_reason: nil
        )
        grant.save!
        success_result(grant: serialize_grant(grant))
      end

      def revoke_access_grant(params)
        grant = account_access_grants.find(params[:access_grant_id])
        grant.revoke!(reason: params[:reason], by_user: @user)
        success_result(grant: serialize_grant(grant.reload), revoked: true)
      end

      # === User Devices ===

      def list_user_devices(params)
        grant = account_access_grants.find(params[:access_grant_id])
        devices = grant.user_devices.order(created_at: :desc)
        success_result(devices: devices.map { |d| serialize_user_device(d) }, count: devices.size)
      end

      def issue_user_device(params)
        grant = account_access_grants.find(params[:access_grant_id])
        result = ::Sdwan::UserDeviceIssuer.issue!(grant: grant, label: params[:label])
        success_result(
          device: serialize_user_device(result[:device]),
          bootstrap_url: "/api/v1/system/sdwan/bootstrap/#{result[:bootstrap_token]}",
          expires_at: result[:expires_at]
        )
      end

      def revoke_user_device(params)
        device = account_user_devices.find(params[:user_device_id])
        device.revoke!(reason: params[:reason])
        success_result(device: serialize_user_device(device.reload), revoked: true)
      end

      def account_access_grants
        ::Sdwan::AccessGrant.where(account_id: @account.id)
      end

      def account_user_devices
        ::Sdwan::UserDevice.joins(access_grant: :network)
                           .where(sdwan_networks: { account_id: @account.id })
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

      def list_federation_peers(_params)
        peers = ::Sdwan::FederationPeer.where(account_id: @account.id).order(created_at: :desc)
        success_result(federation_peers: peers.map { |p| serialize_federation_peer(p) }, count: peers.size)
      end

      def get_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        success_result(federation_peer: serialize_federation_peer(peer))
      end

      def propose_federation_peer(params)
        peer = ::Sdwan::FederationPeer.create!(
          account_id: @account.id,
          status: "proposed",
          remote_instance_url: params[:remote_instance_url],
          remote_instance_id: params[:remote_instance_id],
          remote_account_id: params[:remote_account_id],
          remote_prefix_advertisement: params[:remote_prefix_advertisement]
        )

        response = { federation_peer: serialize_federation_peer(peer) }

        # Phase 11b: optional token generation. Plaintext returned ONCE.
        if params[:generate_token] == true
          ttl = (params[:token_ttl_seconds] || 7.days.to_i).to_i
          plaintext = peer.generate_acceptance_token!(ttl_seconds: ttl)
          response[:acceptance_token_plaintext] = plaintext
          response[:acceptance_token_expires_at] = peer.reload.acceptance_token_expires_at&.iso8601
          response[:note] = "Store the acceptance token immediately — it is shown EXACTLY ONCE. Account B operator pastes this into system_sdwan_accept_federation_peer."
        end

        success_result(**response)
      end

      def revoke_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        peer.revoke!(reason: params[:reason])
        success_result(federation_peer: serialize_federation_peer(peer.reload), revoked: true)
      end

      def accept_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])

        unless peer.can_transition_to?("accepted")
          return error_result(
            "peer #{peer.id} is in status=#{peer.status.inspect}; only 'proposed' peers can be accepted (transition matrix: #{::Sdwan::FederationPeer::V1_TRANSITIONS[peer.status].inspect})"
          )
        end

        success = peer.accept!(
          accepted_by_user: @user,
          acceptance_token: params[:acceptance_token]
        )

        unless success
          # accept! sets errors on the model and returns false (Phase 11b
          # token verification path); surface to operator.
          return error_result(peer.errors.full_messages.join("; "))
        end

        success_result(
          federation_peer: serialize_federation_peer(peer.reload),
          accepted: true
        )
      end

      def federation_scan(_params)
        findings = ::Sdwan::FederationGovernance.scan(account: @account)
        success_result(
          findings: findings,
          finding_count: findings.size,
          severity_summary: findings.group_by { |f| f[:severity] }.transform_values(&:size)
        )
      end

      # === Slice 9a — Routing (static subnet routing) ===

      def set_peer_lan_subnets(params)
        peer = account_peers.find(params[:peer_id])
        peer.update!(lan_subnets: Array(params[:lan_subnets]).map(&:to_s))
        success_result(
          peer_id: peer.id,
          lan_subnets: peer.lan_subnets,
          advertisement_count: peer.subnet_advertisements.active.count
        )
      end

      def set_network_routing_mode(params)
        network = account_networks.find(params[:network_id])
        mode = params[:routing_protocol].to_s
        unless ::Sdwan::Network::ROUTING_PROTOCOLS.include?(mode)
          return error_result("routing_protocol must be one of: #{::Sdwan::Network::ROUTING_PROTOCOLS.join(', ')}")
        end

        network.update!(routing_protocol: mode)
        success_result(
          network_id: network.id,
          routing_protocol: network.routing_protocol,
          note: mode == "ibgp" ? "iBGP mode requires slice 9c (FRR daemon) — peers won't propagate routes via BGP yet." : nil
        )
      end

      def list_subnet_advertisements(params)
        network = account_networks.find(params[:network_id])
        scope = network.subnet_advertisements
        scope = scope.where(source: params[:source]) if params[:source].present?
        scope = scope.active unless params[:include_withdrawn]
        scope = scope.order(:prefix)
        success_result(
          network_id: network.id,
          advertisements: scope.map { |a| serialize_subnet_advertisement(a) },
          count: scope.size
        )
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

      def create_virtual_ip(params)
        network = account_networks.find(params[:network_id])
        ::Sdwan::VirtualIp.transaction do
          vip = network.virtual_ips.new(
            account_id: @account.id,
            name: params[:name],
            cidr: params[:cidr],
            anycast: params[:anycast] || false,
            holder_peer_ids: Array(params[:holder_peer_ids]),
            failover_holder_peer_ids: Array(params[:failover_holder_peer_ids]),
            description: params[:description],
            tags: Array(params[:tags]),
            advertised_med: params[:advertised_med] || 0,
            advertised_local_pref: params[:advertised_local_pref] || 100
          )
          vip.state = "active" if Array(vip.holder_peer_ids).any?
          vip.save!

          create_initial_vip_assignments!(vip)
          success_result(virtual_ip: serialize_virtual_ip(vip.reload))
        end
      end

      def list_virtual_ips(params)
        network = account_networks.find(params[:network_id])
        scope = network.virtual_ips.order(:name)
        scope = scope.where(state: params[:state]) if params[:state].present?
        success_result(virtual_ips: scope.map { |v| serialize_virtual_ip(v) }, count: scope.size)
      end

      def get_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        success_result(virtual_ip: serialize_virtual_ip(vip).merge(
          assignments: vip.assignments.order(assumed_at: :desc).limit(20).map { |a| serialize_vip_assignment(a) }
        ))
      end

      def update_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        ::Sdwan::VirtualIp.transaction do
          previous_holders = Array(vip.holder_peer_ids).dup
          updates = {}
          %i[holder_peer_ids failover_holder_peer_ids tags].each do |k|
            updates[k] = Array(params[k]) if params.key?(k)
          end
          %i[anycast description advertised_med advertised_local_pref].each do |k|
            updates[k] = params[k] if params.key?(k) && !params[k].nil?
          end
          vip.update!(updates)

          sync_vip_assignments_after_holder_change!(vip, previous_holders)
          success_result(virtual_ip: serialize_virtual_ip(vip.reload))
        end
      end

      def delete_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        ::Sdwan::VirtualIp.transaction do
          vip.assignments.where(released_at: nil)
             .update_all(released_at: Time.current, updated_at: Time.current)
          vip.destroy!
          success_result(deleted: true, id: vip.id)
        end
      end

      def failover_virtual_ip(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        vip.failover!(reason: "manual_failover", triggered_by_user: @user)
        success_result(virtual_ip: serialize_virtual_ip(vip.reload), failed_over: true)
      rescue ::Sdwan::VirtualIp::StateError => e
        error_result(e.message)
      end

      def list_vip_assignments(params)
        vip = account_virtual_ips.find(params[:virtual_ip_id])
        assignments = vip.assignments.order(assumed_at: :desc).limit(100)
        success_result(
          virtual_ip_id: vip.id,
          assignments: assignments.map { |a| serialize_vip_assignment(a) },
          count: assignments.size
        )
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
                                   .where(sdwan_networks: { account_id: @account.id })
        scope = scope.where(sdwan_networks: { id: params[:network_id] }) if params[:network_id].present?
        scope = scope.where(state: params[:state]) if params[:state].present?

        sessions = scope.order(updated_at: :desc).limit(500).to_a
        success_result(
          sessions: sessions.map { |s| serialize_bgp_session(s) },
          count: sessions.size
        )
      end

      def get_bgp_config_for_peer(params)
        peer = ::Sdwan::Peer.joins(:network)
                            .where(sdwan_networks: { account_id: @account.id })
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
        policies = scope.order(:scope, :name)
        success_result(
          route_policies: policies.map { |p| serialize_route_policy(p) },
          count: policies.size
        )
      end

      def get_route_policy(params)
        p = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        success_result(route_policy: serialize_route_policy_full(p))
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      def create_route_policy(params)
        attrs = params.slice(:name, :scope, :direction, :scope_resource_id, :description, :enabled)
        attrs[:statements] = params[:statements] if params[:statements].present?
        attrs[:account_id] = @account.id
        policy = ::Sdwan::RoutePolicy.new(attrs)
        if policy.save
          success_result(route_policy: serialize_route_policy_full(policy))
        else
          error_result(policy.errors.full_messages.join("; "))
        end
      end

      def update_route_policy(params)
        p = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        opts = params[:options] || {}
        if p.update(opts.slice(:name, :description, :scope, :scope_resource_id, :direction,
                                :enabled, :statements, :metadata))
          success_result(route_policy: serialize_route_policy_full(p))
        else
          error_result(p.errors.full_messages.join("; "))
        end
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      def delete_route_policy(params)
        p = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:route_policy_id])
        p.destroy!
        success_result(deleted: true, id: p.id)
      rescue ActiveRecord::RecordNotFound
        error_result("route policy not found")
      end

      def compile_route_policy(params)
        peer = ::Sdwan::Peer.joins(:network)
                            .where(sdwan_networks: { account_id: @account.id })
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
        mappings = scope.order(:listen_port, :protocol)
        success_result(
          port_mappings: mappings.map { |m| serialize_port_mapping(m) },
          count: mappings.size
        )
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
        attrs = {
          account_id: @account.id,
          sdwan_peer_id: params[:hub_peer_id],
          target_peer_id: params[:target_peer_id],
          target_virtual_ip_id: params[:target_virtual_ip_id],
          name: params[:name],
          listen_port: params[:listen_port],
          target_port: params[:target_port],
          protocol: params[:protocol] || "tcp",
          description: params[:description],
          enabled: params.fetch(:enabled, true)
        }
        m = net.port_mappings.new(attrs)
        if m.save
          success_result(port_mapping: serialize_port_mapping_full(m))
        else
          error_result(m.errors.full_messages.join("; "))
        end
      rescue ActiveRecord::RecordNotFound
        error_result("network not found in account scope")
      end

      def update_port_mapping(params)
        m = port_mapping_in_account(params[:port_mapping_id])
        return error_result("port mapping not found") unless m

        opts = params[:options] || {}
        if m.update(opts.slice(:name, :description, :target_peer_id, :target_virtual_ip_id,
                                :listen_port, :target_port, :protocol, :enabled, :metadata))
          success_result(port_mapping: serialize_port_mapping_full(m))
        else
          error_result(m.errors.full_messages.join("; "))
        end
      end

      def delete_port_mapping(params)
        m = port_mapping_in_account(params[:port_mapping_id])
        return error_result("port mapping not found") unless m

        m.destroy!
        success_result(deleted: true, id: m.id)
      end

      def port_mapping_in_account(id)
        return nil if id.blank?

        ::Sdwan::PortMapping.joins(:network)
                            .where(sdwan_networks: { account_id: @account.id })
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
          resolved_target_address: m.resolved_target_address
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

      def create_initial_vip_assignments!(vip)
        holders = vip.anycast? ? Array(vip.holder_peer_ids) : Array(vip.holder_peer_ids).first(1)
        holders.compact.each do |peer_id|
          vip.assignments.create!(
            peer: ::Sdwan::Peer.find(peer_id),
            assumed_at: Time.current,
            reason: "initial",
            triggered_by_user_id: @user&.id
          )
        end
      end

      def sync_vip_assignments_after_holder_change!(vip, previous_holders)
        current = vip.anycast? ? Array(vip.holder_peer_ids) : Array(vip.holder_peer_ids).first(1)
        current = current.compact

        departed = previous_holders - current
        arrived  = current - previous_holders
        return if departed.empty? && arrived.empty?

        now = Time.current
        departed.each do |peer_id|
          vip.assignments.where(sdwan_peer_id: peer_id, released_at: nil)
             .update_all(released_at: now, updated_at: now)
        end
        arrived.each do |peer_id|
          vip.assignments.create!(
            peer: ::Sdwan::Peer.find(peer_id),
            assumed_at: now,
            reason: "holder_changed",
            triggered_by_user_id: @user&.id
          )
        end
      end

      def account_federation_peers
        ::Sdwan::FederationPeer.where(account_id: @account.id)
      end

      def serialize_federation_peer(p)
        {
          id: p.id,
          remote_instance_url: p.remote_instance_url,
          remote_instance_id: p.remote_instance_id,
          remote_account_id: p.remote_account_id,
          remote_prefix_advertisement: p.remote_prefix_advertisement,
          status: p.status,
          v1_allowed_transitions: ::Sdwan::FederationPeer::V1_TRANSITIONS.fetch(p.status, []),
          signed_at: p.signed_at&.iso8601,
          expires_at: p.expires_at&.iso8601,
          created_at: p.created_at&.iso8601
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
          effective_endpoint: primary && "#{primary[:host]}:#{primary[:port]}",
          effective_endpoint_family: primary && primary[:family].to_s,
          fallback_endpoint: fallback && "#{fallback[:host]}:#{fallback[:port]}",
          listen_port: p.listen_port,
          status: p.status,
          public_key: p.active_key&.public_key,
          last_handshake_at: p.last_handshake_at&.iso8601
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

      def create_host_bridge(params)
        host = ::System::NodeInstance.joins(:node)
                                     .where(system_nodes: { account_id: @account.id })
                                     .find(params[:node_instance_id])
        bridge = ::Sdwan::HostBridgeAllocator.allocate!(
          host: host,
          kind: params[:kind].presence,
          account: @account
        )
        success_result(host_bridge: serialize_host_bridge(bridge))
      end

      def list_host_bridges(params)
        scope = ::Sdwan::HostBridge.where(account_id: @account.id)
        scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
        bridges = scope.order(:node_instance_id, :short_id)
        success_result(
          host_bridges: bridges.map { |b| serialize_host_bridge(b) },
          count: bridges.size
        )
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
        deployment = ::Sdwan::OvnDeployment.create!(
          account: @account,
          nb_db_endpoint: params[:nb_db_endpoint],
          sb_db_endpoint: params[:sb_db_endpoint],
          northd_host: params[:northd_host],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        success_result(ovn_deployment: serialize_ovn_deployment(deployment))
      end

      def create_ovn_logical_switch(params)
        deployment = account_ovn_deployments.find(params[:deployment_id])
        switch = deployment.logical_switches.create!(
          account: @account,
          name: params[:name],
          cidr: params[:cidr],
          description: params[:description],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        success_result(ovn_logical_switch: serialize_ovn_logical_switch(switch))
      end

      def create_ovn_logical_switch_port(params)
        switch = account_ovn_logical_switches.find(params[:logical_switch_id])

        host = nil
        if params[:host_node_instance_id].present?
          host = ::System::NodeInstance.joins(:node)
                                       .where(system_nodes: { account_id: @account.id })
                                       .find(params[:host_node_instance_id])
        end

        port = switch.ports.new(
          account: @account,
          name: params[:name],
          kind: params[:kind].to_s,
          host_node_instance: host,
          addresses: Array(params[:addresses]).map(&:to_s),
          mac: params[:mac].presence
        )
        port.save!
        success_result(ovn_logical_switch_port: serialize_ovn_logical_switch_port(port))
      end

      def compile_ovn_plan(params)
        deployment = account_ovn_deployments.find(params[:deployment_id])
        plan = ::Sdwan::OvnCompiler.compile_for_deployment(deployment)
        success_result(plan: plan)
      end

      def account_ovn_deployments
        ::Sdwan::OvnDeployment.where(account_id: @account.id)
      end

      def account_ovn_logical_switches
        ::Sdwan::OvnLogicalSwitch.where(account_id: @account.id)
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
        collector = ::Sdwan::IpfixCollector.create!(
          account: @account,
          name: params[:name],
          host: params[:host],
          port: params[:port].present? ? params[:port].to_i : 4739,
          sampling_rate: params[:sampling_rate].present? ? params[:sampling_rate].to_i : 1
        )
        success_result(ipfix_collector: serialize_ipfix_collector(collector))
      end

      def list_ipfix_collectors(_params)
        collectors = ::Sdwan::IpfixCollector.where(account_id: @account.id).order(:name)
        success_result(
          ipfix_collectors: collectors.map { |c| serialize_ipfix_collector(c) },
          count: collectors.size
        )
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
    end
  end
end
