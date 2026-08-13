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

      # Autonomy action category for federation acceptance. Seeded
      # require_approval on the SDWAN Manager
      # (db/seeds/system_sdwan_manager_agent.rb) and registered in the engine's
      # category allowlist.
      FEDERATION_ACCEPT_CATEGORY = "sdwan.federation_peer_accept"

      # Autonomy action category for revoking one user VPN device. Shared
      # verbatim with Api::V1::System::Sdwan::UserDevicesController (#revoke and
      # #destroy) so the MCP and HTTP surfaces resolve the SAME policy — seeded
      # require_approval in db/seeds/fleet_autonomy_agent.rb and registered in
      # the engine's category allowlist.
      USER_DEVICE_REVOKE_CATEGORY = "system.sdwan_user_device_revoke"

      # Autonomy action category for revoking a whole access grant — which
      # cascades to every device on it. Shared verbatim with
      # Api::V1::System::Sdwan::AccessGrantsController#revoke so the MCP and HTTP
      # surfaces resolve the SAME policy — seeded require_approval on the SDWAN
      # Manager (db/seeds/system_sdwan_manager_agent.rb) and registered in the
      # engine's category allowlist.
      ACCESS_GRANT_REVOKE_CATEGORY = "sdwan.access_grant_revoke"

      ACTION_PERMISSIONS = {
        "system_sdwan_list_networks"   => "system.sdwan.networks.read",
        "system_sdwan_get_network"     => "system.sdwan.networks.read",
        "system_sdwan_create_network"  => "system.sdwan.networks.manage",
        "system_sdwan_update_network"  => "system.sdwan.networks.manage",
        "system_sdwan_delete_network"  => "system.sdwan.networks.manage",
        "system_sdwan_list_peers"      => "system.sdwan.peers.read",
        "system_sdwan_get_peer"        => "system.sdwan.peers.read",
        "system_sdwan_attach_peer"     => "system.sdwan.peers.manage",
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
            parameters: { options: { type: "object", required: false, description: "Reserved options hash (currently unused; pass {} or omit)" } }
          },
          "system_sdwan_get_network" => {
            description: "Fetch an SDWAN network by id",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to fetch" } }
          },
          "system_sdwan_create_network" => {
            description: "Create a new SDWAN overlay network. CIDR (/64) is allocated automatically.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new network" },
              description: { type: "string", required: false, description: "Free-form description of the network's purpose" },
              options: { type: "object", required: false, description: "settings hash (mtu, topology_strategy, ...)" }
            }
          },
          "system_sdwan_update_network" => {
            description: "Update an SDWAN network's name/description/status/settings",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network to update" },
              options: { type: "object", required: false, description: "Hash of fields to update: name, description, status, settings (settings must itself be a hash)" }
            }
          },
          "system_sdwan_delete_network" => {
            description: "Delete an SDWAN network and all its peers + keys (destructive)",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to delete" } }
          },
          "system_sdwan_list_peers" => {
            description: "List peers in an SDWAN network",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose peers to list" } }
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
          "system_sdwan_detach_peer" => {
            description: "Detach a peer (revokes key, removes membership)",
            parameters: { peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to detach" } }
          },
          "system_sdwan_get_topology" => {
            description: "Return the compiled per-peer view for an SDWAN network — what each peer would receive on its next config pull",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to compile topology for" } }
          },
          "system_sdwan_list_firewall_rules" => {
            description: "List firewall rules in an SDWAN network (priority-ordered)",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose firewall rules to list" } }
          },
          "system_sdwan_get_firewall_rule" => {
            description: "Fetch a single firewall rule, including its compiled nft preview",
            parameters: { firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to fetch" } }
          },
          "system_sdwan_create_firewall_rule" => {
            description: "Create a firewall rule. Selectors accept {peer_id|tag|cidr|all} primitives. Port range is optional and only applies to tcp/udp.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network this rule belongs to" },
              name: { type: "string", required: true, description: "Display name for the firewall rule" },
              firewall_action: { type: "string", required: false, description: "accept (default) | drop | reject" },
              direction: { type: "string", required: false, description: "ingress | egress | both (default)" },
              protocol: { type: "string", required: false, description: "any (default) | tcp | udp | icmp6" },
              priority: { type: "integer", required: false, description: "Evaluation priority (lower runs first); defaults to the model's default" },
              src_selector: { type: "object", required: false, description: "Source match: one of {peer_id|tag|cidr|all}" },
              dst_selector: { type: "object", required: false, description: "Destination match: one of {peer_id|tag|cidr|all}" },
              port_from: { type: "integer", required: false, description: "Start of the port range (tcp/udp only; pair with port_to)" },
              port_to:   { type: "integer", required: false, description: "End of the port range (tcp/udp only; pair with port_from)" }
            }
          },
          "system_sdwan_update_firewall_rule" => {
            description: "Update a firewall rule (any field). Pass port_from/port_to as null to clear the port range.",
            parameters: {
              firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to update" },
              name: { type: "string", required: false, description: "New display name for the rule" },
              firewall_action: { type: "string", required: false, description: "accept | drop | reject" },
              direction: { type: "string", required: false, description: "ingress | egress | both" },
              protocol: { type: "string", required: false, description: "any | tcp | udp | icmp6" },
              priority: { type: "integer", required: false, description: "Evaluation priority (lower runs first)" },
              src_selector: { type: "object", required: false, description: "Source match: one of {peer_id|tag|cidr|all}" },
              dst_selector: { type: "object", required: false, description: "Destination match: one of {peer_id|tag|cidr|all}" },
              port_from: { type: "integer", required: false, description: "Start of the port range (tcp/udp only)" },
              port_to:   { type: "integer", required: false, description: "End of the port range (tcp/udp only)" },
              enabled:   { type: "boolean", required: false, description: "Whether the rule is active" }
            }
          },
          "system_sdwan_delete_firewall_rule" => {
            description: "Delete a firewall rule (immediate; takes effect on next agent reconcile)",
            parameters: { firewall_rule_id: { type: "string", required: true, description: "UUID of the SDWAN firewall rule to delete" } }
          },
          # Slice 4: user VPN
          "system_sdwan_list_access_grants" => {
            description: "List user access grants on an SDWAN network",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose access grants to list" } }
          },
          "system_sdwan_create_access_grant" => {
            description: "Grant a user access to an SDWAN network (precondition for issuing them VPN devices)",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network to grant access to" },
              user_id:    { type: "string", required: true,  description: "UUID of the User (in this account) being granted access" },
              tags:       { type: "array",  required: false, description: "Optional list of tag strings applied to the grant (used for firewall tag selectors)" }
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
            parameters: { access_grant_id: { type: "string", required: true, description: "UUID of the SDWAN access grant whose devices to list" } }
          },
          "system_sdwan_issue_user_device" => {
            description: "Issue a fresh WireGuard config for a user. Returns a one-shot bootstrap_url (15-min expiry, single-use) — copy it to the user out-of-band.",
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
            parameters: { options: { type: "object", required: false, description: "Reserved options hash (currently unused; pass {} or omit)" } }
          },
          "system_sdwan_get_federation_peer" => {
            description: "Fetch a federation peer with its v1-allowed transitions",
            parameters: { federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to fetch" } }
          },
          "system_sdwan_propose_federation_peer" => {
            description: "Propose a new federation peer. Status starts at 'proposed'. With generate_token: true (Phase 11b), generates a single-use acceptance token (plaintext returned ONCE) — Account A operator copies it out-of-band to Account B operator who pastes it into system_sdwan_accept_federation_peer.",
            parameters: {
              remote_instance_url: { type: "string", required: true, description: "Base URL of the remote Powernode instance to peer with" },
              remote_instance_id: { type: "string", required: false, description: "Optional identifier of the remote Powernode instance" },
              remote_account_id: { type: "string", required: false, description: "Optional identifier of the remote account on the peer instance" },
              remote_prefix_advertisement: { type: "string", required: false, description: "/48|/56|/64 ULA prefix the remote instance claims" },
              generate_token: { type: "boolean", required: false, description: "When true, generate a single-use acceptance token (Phase 11b token round-trip handshake). Plaintext returned ONCE — not recoverable." },
              token_ttl_seconds: { type: "integer", required: false, description: "Token expiry window in seconds (default 7 days)" }
            }
          },
          "system_sdwan_accept_federation_peer" => {
            description: "Transition a proposed federation peer to accepted. Approval-gated (sdwan.federation_peer_accept) — under require_approval this returns pending: true with a deferred_operation_id and the peer is accepted only once an operator approves. When the proposing operator generated a single-use acceptance token, pass it as acceptance_token — it is verified (digest match + not expired + single-use) before the request is gated, and again before the transition is written. Performs the status transition only (sets signed_at + audit metadata); it does NOT run the enroll / node-enrollment / SDWAN-attach chain — that is the federation_acceptance skill.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to accept (must be in 'proposed' status)" },
              acceptance_token:   { type: "string", required: false, description: "Single-use token from the proposing-account operator (from propose with generate_token: true). Verified against the stored digest; consumed on success." }
            }
          },
          "system_sdwan_revoke_federation_peer" => {
            description: "Revoke a federation peer (terminal in v1)",
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
            description: "Update a federation peer's mutable fields. When `status` is supplied it is gated by the v1 transition matrix (FederationPeer#can_transition_to?) — disallowed transitions return an error. Mirrors the FederationPeersController#update permitted keys.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to update" },
              status: { type: "string", required: false, description: "Target status — must be an allowed v1 transition from the current status" },
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
            description: "Set a federation peer's data residency region tag (the system_federation_peers.data_residency column, a scalar string ≤64 chars). Used by the residency enforcer to gate which peers may home a given record.",
            parameters: {
              federation_peer_id: { type: "string", required: true, description: "UUID of the federation peer to tag" },
              data_residency: { type: "string", required: true, description: "Region/residency tag, e.g. 'us-east' or 'eu'" }
            }
          },
          "system_sdwan_get_audit_log" => {
            description: "Read-only audit trail for a federation peer: WORM audit shipments (P9.2 sealed FleetEvent batches) plus recent federation.* FleetEvents pertaining to this peer. Secret fields (sealed_path, error_message) are not surfaced.",
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
              topology: { type: "string", required: true, description: "hub_and_spoke | full_mesh" },
              peers: { type: "array", required: true, description: "Member descriptors (1-200). Each: {node_instance_id (required), role: 'hub'|'spoke' (hub_and_spoke only; default spoke), endpoint_host_v6, endpoint_host_v4, endpoint_port, listen_port, lan_subnets: [cidr], bgp_route_reflector_client: bool}" },
              routing_protocol: { type: "string", required: false, description: "static (default) | ibgp — 'ibgp' enables FRR route-policy distribution" },
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
              protocol: { type: "string", required: false, description: "Service protocol advertised in the catalog: https (default) | http | tcp | tls" },
              grant_scopes: { type: "array", required: false, description: "Default FederationGrant scopes subscribers receive (subset of read, write, admin, migrate). Defaults to ['read']" },
              grant_ttl_days: { type: "integer", required: false, description: "Default grant TTL in days (>= 7)" },
              traefik_dynamic_dir: { type: "string", required: false, description: "Override for the Traefik dynamic-config directory" },
              public_dns: { type: "object", required: false, description: "INTERNET-FACING name only: { dns_credential_id, record_name, record_type? (A|AAAA|CNAME), record_content?, ttl? }. Omit for overlay-only discovery." }
            }
          },
          # Slice 9a — routing layer (static subnet routing baseline)
          "system_sdwan_update_peer_lan_subnets" => {
            description: "Declare the external LAN prefixes a peer can route to. In static mode, the topology compiler folds these into AllowedIPs so other peers route across the SDWAN to reach them. CIDR strings (v4 or v6).",
            parameters: {
              peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer whose LAN subnets to declare" },
              lan_subnets: { type: "array", required: true, description: "Array of CIDR strings. Empty array clears." }
            }
          },
          "system_sdwan_set_peer_tags" => {
            description: "Set the firewall tag labels on a peer. A FirewallRule whose src/dst selector is { \"tag\": \"<label>\" } matches every peer carrying that label (Sdwan::SelectorResolver compiles it to an nft set of their addresses). Replaces the peer's whole tag set; empty array clears it.",
            parameters: {
              peer_id: { type: "string", required: true, description: "UUID of the SDWAN peer to label" },
              tags: { type: "array", required: true, description: "Array of tag label strings (whitespace-trimmed, de-duped). Empty array clears all tags." }
            }
          },
          "system_sdwan_update_network_routing_mode" => {
            description: "Set a network's routing protocol: 'static' (declarative AllowedIPs, no daemon) or 'ibgp' (slice 9c FRR + dynamic distribution). Until slice 9c lands, only 'static' is fully functional.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose routing mode to set" },
              routing_protocol: { type: "string", required: true, description: "static | ibgp" }
            }
          },
          "system_sdwan_list_subnet_advertisements" => {
            description: "List route advertisements for a network — declared lan_subnets, VIP announcements (slice 9b), and BGP-learned routes (slice 9c) unified. Filterable by source.",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose advertisements to list" },
              source: { type: "string", required: false, description: "Filter: declared_lan_subnet | virtual_ip | learned_via_bgp" },
              include_withdrawn: { type: "boolean", required: false, description: "Include withdrawn (inactive) advertisements (default false = active only)" }
            }
          },
          "system_sdwan_get_routing_summary" => {
            description: "Routing-layer summary for a network: protocol, peer count, advertised prefixes, hub redundancy, BGP session count. Cheap; safe to poll.",
            parameters: { network_id: { type: "string", required: true, description: "UUID of the SDWAN network to summarize" } }
          },
          # Slice 9b — Virtual IPs
          "system_sdwan_create_virtual_ip" => {
            description: "Create a Virtual IP. Static mode (anycast=false) = single primary holder + ordered failover. Anycast mode (slice 9c iBGP) = all holders advertise simultaneously. CIDR is typically /32 (v4) or /128 (v6).",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network the Virtual IP lives in" },
              name: { type: "string", required: true, description: "Display name for the Virtual IP" },
              cidr: { type: "string", required: true, description: "Host CIDR for the VIP (typically /32 for v4, /128 for v6) within the network's /64" },
              holder_peer_ids: { type: "array", required: true, description: "Ordered: first entry is primary holder when anycast=false." },
              failover_holder_peer_ids: { type: "array", required: false, description: "Ordered failover candidates (non-anycast); head is promoted on failover" },
              anycast: { type: "boolean", required: false, description: "When true, all holders advertise simultaneously (slice 9c iBGP); default false" },
              description: { type: "string", required: false, description: "Free-form description of the VIP's purpose" },
              tags: { type: "array", required: false, description: "Optional list of tag strings applied to the VIP" },
              advertised_med: { type: "integer", required: false, description: "BGP MULTI_EXIT_DISC advertised for this VIP (default 0)" },
              advertised_local_pref: { type: "integer", required: false, description: "BGP LOCAL_PREF advertised for this VIP (default 100)" }
            }
          },
          "system_sdwan_list_virtual_ips" => {
            description: "List Virtual IPs in an SDWAN network",
            parameters: {
              network_id: { type: "string", required: true, description: "UUID of the SDWAN network whose Virtual IPs to list" },
              state: { type: "string", required: false, description: "Filter: pending|active|failing_over|unassigned|error" }
            }
          },
          "system_sdwan_get_virtual_ip" => {
            description: "Fetch a Virtual IP with its assignment history (last 20 transitions)",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to fetch" } }
          },
          "system_sdwan_update_virtual_ip" => {
            description: "Update a Virtual IP's holders, failover candidates, anycast mode, advertised_med/local_pref, etc. Holder changes are recorded as 'holder_changed' assignment rows.",
            parameters: {
              virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to update" },
              holder_peer_ids: { type: "array", required: false, description: "Ordered holder peer UUIDs; first is primary when anycast=false" },
              failover_holder_peer_ids: { type: "array", required: false, description: "Ordered failover candidate peer UUIDs (non-anycast)" },
              anycast: { type: "boolean", required: false, description: "When true, all holders advertise simultaneously (slice 9c iBGP)" },
              description: { type: "string", required: false, description: "Free-form description of the VIP's purpose" },
              tags: { type: "array", required: false, description: "Optional list of tag strings applied to the VIP" },
              advertised_med: { type: "integer", required: false, description: "BGP MULTI_EXIT_DISC advertised for this VIP" },
              advertised_local_pref: { type: "integer", required: false, description: "BGP LOCAL_PREF advertised for this VIP" }
            }
          },
          "system_sdwan_delete_virtual_ip" => {
            description: "Delete a Virtual IP. Closes all active assignments + destroys the row.",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to delete" } }
          },
          "system_sdwan_failover_virtual_ip" => {
            description: "Manual failover for a non-anycast VIP — promotes the head of failover_holder_peer_ids to holder. Anycast VIPs don't fail over (all holders are active simultaneously).",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP to fail over" } }
          },
          "system_sdwan_list_vip_assignments" => {
            description: "Audit-grade history of VIP holder transitions for a Virtual IP",
            parameters: { virtual_ip_id: { type: "string", required: true, description: "UUID of the SDWAN virtual IP whose assignment history to list" } }
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
              state: { type: "string", required: false, description: "idle | connect | active | opensent | openconfirm | established" }
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
              scope: { type: "string", required: false, description: "account | network | peer" },
              direction: { type: "string", required: false, description: "import | export" }
            }
          },
          "system_sdwan_get_route_policy" => {
            description: "Fetch a route policy by id, including its full statement list.",
            parameters: { route_policy_id: { type: "string", required: true, description: "UUID of the SDWAN route policy to fetch" } }
          },
          "system_sdwan_create_route_policy" => {
            description: "Create a route policy. statements is an ordered list of {match: {...}, action: {...}} objects. Compile output appears in TopologyCompiler#bgp.policies.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the route policy" },
              scope: { type: "string", required: true, description: "account | network | peer" },
              direction: { type: "string", required: true, description: "import | export" },
              statements: { type: "array", required: true, description: "Ordered list of {match,action} hashes" },
              scope_resource_id: { type: "string", required: false, description: "UUID of the scoped resource (network or peer) when scope is 'network' or 'peer'" },
              description: { type: "string", required: false, description: "Free-form description of the policy's intent" },
              enabled: { type: "boolean", required: false, description: "Whether the policy is active and compiled into frr.conf" }
            }
          },
          "system_sdwan_update_route_policy" => {
            description: "Update a route policy's name, scope, statements, or enabled state.",
            parameters: {
              route_policy_id: { type: "string", required: true, description: "UUID of the SDWAN route policy to update" },
              options: { type: "object", required: true, description: "Hash of fields to update: name, description, scope, scope_resource_id, direction, enabled, statements, metadata" }
            }
          },
          "system_sdwan_delete_route_policy" => {
            description: "Delete a route policy. The next agent reconcile removes the corresponding route-map from frr.conf.",
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
              hub_peer_id: { type: "string", required: false, description: "Optional UUID of the hub peer to filter mappings by" }
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
              protocol: { type: "string", required: true, description: "tcp | udp" },
              target_peer_id: { type: "string", required: false, description: "UUID of the target peer to DNAT to (mutually exclusive with target_virtual_ip_id)" },
              target_virtual_ip_id: { type: "string", required: false, description: "UUID of the target virtual IP to DNAT to (mutually exclusive with target_peer_id)" },
              target_port: { type: "integer", required: false, description: "Defaults to listen_port if omitted" },
              description: { type: "string", required: false, description: "Free-form description of the mapping" },
              enabled: { type: "boolean", required: false, description: "Whether the mapping is active (default true)" },
              rate_limit: { type: "integer", required: false, description: "Hardened DNAT tier (increment 6): max NEW CONNECTIONS per second (conntrack flows — the nat chain only sees each connection's first packet, so this throttles connection-establishment rate, not request/packet throughput). Omit for unrestricted (default)." },
              max_connections: { type: "integer", required: false, description: "Hardened DNAT tier (increment 6): max concurrent connections before excess are dropped. Omit for unrestricted (default)." },
              source_cidrs: { type: "array", required: false, description: "Hardened DNAT tier (increment 6): allow-list of source CIDR strings (v4 and/or v6). Traffic from any other source is dropped. Omit/empty for unrestricted (default)." }
            }
          },
          "system_sdwan_update_port_mapping" => {
            description: "Update a port mapping's name, target, ports, protocol, enabled state, or hardening (rate_limit/max_connections/source_cidrs).",
            parameters: {
              port_mapping_id: { type: "string", required: true, description: "UUID of the SDWAN port mapping to update" },
              options: { type: "object", required: true, description: "Hash of fields to update: name, description, target_peer_id, target_virtual_ip_id, listen_port, target_port, protocol, enabled, metadata, rate_limit, max_connections, source_cidrs. Pass rate_limit/max_connections as null or source_cidrs as [] to clear back to unrestricted." }
            }
          },
          "system_sdwan_delete_port_mapping" => {
            description: "Delete a port mapping. Agent removes the corresponding nft DNAT rule on next reconcile.",
            parameters: { port_mapping_id: { type: "string", required: true, description: "UUID of the SDWAN port mapping to delete" } }
          },
          # ─── Phase O6 — host bridges (O1) ──────────────────────────────────
          "system_sdwan_create_host_bridge" => {
            description: "Allocate a HostBridge for a NodeInstance via Sdwan::HostBridgeAllocator. Idempotent — returns the existing bridge of the requested kind on this host if one already exists. When `kind` is omitted the allocator picks 'ovs' for heavyweight hosts and 'linux' for lightweight hosts based on the host's network_profile.",
            parameters: {
              node_instance_id: { type: "string", required: true, description: "UUID of the System::NodeInstance (host) to allocate a bridge on" },
              kind: { type: "string", required: false, description: "linux | ovs (defaults to host's network_profile mapping)" }
            }
          },
          "system_sdwan_activate_host_bridge" => {
            description: "Mark a HostBridge as `active` so the topology compiler picks it up. Newly allocated bridges land in `pending`; the resolver only sees active bridges. Use this after create_host_bridge when the agent isn't yet reporting back its applied state.",
            parameters: {
              id: { type: "string", required: true, description: "Sdwan::HostBridge id" }
            }
          },
          "system_sdwan_release_host_bridge" => {
            description: "Release a HostBridge via Sdwan::HostBridgeAllocator.release!. Default `force: false` transitions the bridge to `draining` (preserves the short_id during in-flight tap teardown). Pass `force: true` to mark the bridge `removed` immediately, releasing the short_id back to the pool.",
            parameters: {
              id: { type: "string", required: true, description: "Sdwan::HostBridge id" },
              force: { type: "boolean", required: false, description: "When true, skip the draining grace window and mark removed immediately (default false)" }
            }
          },
          "system_sdwan_list_host_bridges" => {
            description: "List HostBridges for the current account. Optionally filter by node_instance_id.",
            parameters: {
              node_instance_id: { type: "string", required: false, description: "Optional UUID of the System::NodeInstance (host) to filter bridges by" }
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
              kind: { type: "string", required: true, description: "vm | container | external" },
              host_node_instance_id: { type: "string", required: false, description: "Required for vm/container ports; ignored for external" },
              addresses: { type: "array", required: false, description: "Array of IPv4/IPv6 strings; appended to the OVN `addresses=` line" },
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
            parameters: {}
          },
          # ─── Phase O6 follow-up — OVN ACLs ──────────────────────────────
          "system_sdwan_create_ovn_acl" => {
            description: "Create an OVN ACL (firewall rule) on a logical switch. ACLs operate at the intra-host / logical-network scope (compiled to OVS OpenFlow via OVN's logical-flow translation) — distinct from SDWAN nftables firewall rules which operate at inter-peer scope. Heavyweight-profile only in effect.",
            parameters: {
              logical_switch_id: { type: "string", required: true, description: "Sdwan::OvnLogicalSwitch id this ACL applies to" },
              name: { type: "string", required: true, description: "Operator-chosen name (unique per switch, max 63 chars, [letters/digits/_/-/.] only)" },
              direction: { type: "string", required: true, description: "from-lport (egress from source pod/VM) | to-lport (ingress to destination)" },
              priority: { type: "integer", required: false, description: "0-32767, higher first; default 1000. Ties broken by lexicographic match-string order." },
              match: { type: "string", required: true, description: "OVN match expression, e.g. `ip4.src == 10.0.0.0/8 && tcp.dst == 5432`. Raw OVN syntax — OVN's parser rejects bad values at apply time." },
              acl_action: { type: "string", required: true, description: "allow | drop | reject | allow-related" }
            }
          },
          "system_sdwan_list_ovn_acls" => {
            description: "List OVN ACLs for the current account. Optionally filter by logical_switch_id (per-switch scope) or sdwan_ovn_deployment_id (per-deployment scope). With no filter, returns every active ACL across every switch in every deployment.",
            parameters: {
              logical_switch_id: { type: "string", required: false, description: "Restrict to ACLs on this switch" },
              sdwan_ovn_deployment_id: { type: "string", required: false, description: "Restrict to ACLs on switches under this deployment" }
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
            parameters: { status: { type: "string", required: false, description: "Optional status filter (pending | active | degraded | ...)" } }
          },
          "system_sdwan_get_ovn_deployment" => {
            description: "Fetch one OVN deployment with its logical switches (each switch includes its ports), so an agent can rediscover the full topology and the ids it needs for compile/delete.",
            parameters: { deployment_id: { type: "string", required: true, description: "Sdwan::OvnDeployment id" } }
          },
          "system_sdwan_list_ovn_logical_switches" => {
            description: "List OVN logical switches (optionally scoped to a deployment), each with its ports so port ids are discoverable for system_sdwan_delete_ovn_logical_switch_port.",
            parameters: { deployment_id: { type: "string", required: false, description: "Restrict to switches under this Sdwan::OvnDeployment" } }
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

        result = ::Ai::AutonomyGate.evaluate(
          action_category: ACCESS_GRANT_REVOKE_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeAccessGrant",
          # Key names are the executor's contract, not this tool's — grant_id
          # and reason, shared verbatim with AccessGrantsController#revoke.
          params: { grant_id: grant.id, reason: params[:reason] },
          account: @account,
          # Agent AND user. The seeded row is scoped to the SDWAN Manager
          # (upsert_policies! passes agent:), and
          # Ai::InterventionPolicy#agent_matches? rejects a scoped row against a
          # nil agent — so an SDWAN Manager caller that dropped @agent would
          # stop matching its own row. Every other caller falls through to
          # InterventionPolicyService#default_policy, which is also
          # require_approval, so the gate holds either way; what @agent
          # additionally buys is attribution — AutonomyGate#resolve_chain routes
          # to "<agent name> Actions" and to "Manual Operations" when nil.
          agent: @agent,
          # Replaces the `by_user:` this method used to pass to
          # AccessGrant#revoke!, which the model accepts and never persists
          # (there is no revoked_by column) — attribution now lands on the
          # DeferredOperation instead, where the approver can see it.
          requested_by: @user,
          source_type: "Sdwan::AccessGrant",
          source_id: grant.id,
          description: "Revoke SDWAN access for #{grant.user&.email || grant.id}"
        )

        case result.decision
        when :proceed
          success_result(grant: serialize_grant(grant.reload), revoked: true)
        when :pending
          success_result(
            pending: true,
            action_category: ACCESS_GRANT_REVOKE_CATEGORY,
            deferred_operation_id: result.deferred_operation&.id,
            approval_request_id: result.approval_request&.id,
            grant: serialize_grant(grant),
            message: "Approval required: #{ACCESS_GRANT_REVOKE_CATEGORY}"
          )
        else
          error_result(result.error || "Action #{ACCESS_GRANT_REVOKE_CATEGORY} is blocked by policy")
        end
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

        result = ::Ai::AutonomyGate.evaluate(
          action_category: USER_DEVICE_REVOKE_CATEGORY,
          executor_class: "Sdwan::Executors::RevokeUserDevice",
          # Key names are the executor's contract, not this tool's: it reads
          # grant_id/device_id (shared with the two HTTP device verbs).
          params: { grant_id: device.sdwan_access_grant_id, device_id: device.id, reason: params[:reason] },
          account: @account,
          # Agent AND user. The seeded row is scoped to Fleet Autonomy
          # (upsert_policies! passes agent:), and
          # Ai::InterventionPolicy#agent_matches? rejects a scoped row against a
          # nil agent — so a Fleet Autonomy caller that dropped @agent would
          # stop matching its own row. Every other caller falls through to
          # InterventionPolicyService#default_policy, which is also
          # require_approval, so the gate holds either way; what @agent
          # additionally buys is attribution — AutonomyGate#resolve_chain routes
          # to "<agent name> Actions" and to "Manual Operations" when nil.
          agent: @agent,
          requested_by: @user,
          source_type: "Sdwan::UserDevice",
          source_id: device.id,
          description: "Revoke SDWAN device #{device.label || device.id}"
        )

        case result.decision
        when :proceed
          success_result(device: serialize_user_device(device.reload), revoked: true)
        when :pending
          success_result(
            pending: true,
            action_category: USER_DEVICE_REVOKE_CATEGORY,
            deferred_operation_id: result.deferred_operation&.id,
            approval_request_id: result.approval_request&.id,
            device: serialize_user_device(device),
            message: "Approval required: #{USER_DEVICE_REVOKE_CATEGORY}"
          )
        else
          error_result(result.error || "Action #{USER_DEVICE_REVOKE_CATEGORY} is blocked by policy")
        end
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

      def list_federation_peers(_params)
        peers = ::System::FederationPeer.where(account_id: @account.id).order(created_at: :desc)
        success_result(federation_peers: peers.map { |p| serialize_federation_peer(p) }, count: peers.size)
      end

      def get_federation_peer(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        success_result(federation_peer: serialize_federation_peer(peer))
      end

      def propose_federation_peer(params)
        peer = ::System::FederationPeer.create!(
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

        result = ::Ai::AutonomyGate.evaluate(
          action_category: FEDERATION_ACCEPT_CATEGORY,
          executor_class: "Sdwan::Executors::AcceptFederationPeer",
          # The single-use token has to outlive the approval window to be
          # verified and consumed by the executor, so it is carried on the
          # deferred operation. Note that Ai::AutonomyGate copies these params
          # into the ApprovalRequest's request_data, which the approvals API
          # serializes verbatim — so under require_approval the plaintext token
          # is readable by any holder of ai.autonomy.approve, a wider audience
          # than system.sdwan.federation.manage.
          params: { federation_peer_id: peer.id, acceptance_token: params[:acceptance_token] },
          account: @account,
          # Agent AND user: an agent-scoped intervention policy (the seeded
          # SDWAN Manager row) only matches when the agent is passed —
          # Ai::InterventionPolicy#agent_matches? rejects a nil agent against a
          # scoped row — and the gate uses the agent to route the approval to
          # that agent's chain rather than to "Manual Operations".
          agent: @agent,
          requested_by: @user,
          source_type: "System::FederationPeer",
          source_id: peer.id,
          description: "Accept federation peer #{peer.remote_instance_url}"
        )

        case result.decision
        when :proceed
          success_result(federation_peer: serialize_federation_peer(peer.reload), accepted: true)
        when :pending
          success_result(
            pending: true,
            action_category: FEDERATION_ACCEPT_CATEGORY,
            deferred_operation_id: result.deferred_operation&.id,
            approval_request_id: result.approval_request&.id,
            federation_peer: serialize_federation_peer(peer),
            message: "Approval required: #{FEDERATION_ACCEPT_CATEGORY}"
          )
        else
          error_result(result.error || "Action #{FEDERATION_ACCEPT_CATEGORY} is blocked by policy")
        end
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

        peer.update!(update_attrs) if update_attrs.any?
        success_result(federation_peer: serialize_federation_peer(peer.reload))
      end

      # Set a federation peer's data residency region tag (scalar
      # system_federation_peers.data_residency column, ≤64 chars).
      def set_data_residency(params)
        peer = account_federation_peers.find(params[:federation_peer_id])
        peer.update!(data_residency: params[:data_residency])
        success_result(federation_peer: serialize_federation_peer(peer.reload))
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

      # D8 — set the firewall tag labels on a peer (the model normalizes:
      # trim/dedup). Firewall { "tag": "x" } selectors then resolve to it.
      def set_peer_tags(params)
        peer = account_peers.find(params[:peer_id])
        peer.update!(tags: Array(params[:tags]).map(&:to_s))
        success_result(peer_id: peer.id, tags: peer.tags)
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
          enabled: params.fetch(:enabled, true),
          rate_limit: params[:rate_limit],
          max_connections: params[:max_connections],
          source_cidrs: params[:source_cidrs]
        }.compact
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
                                :listen_port, :target_port, :protocol, :enabled, :metadata,
                                :rate_limit, :max_connections, :source_cidrs))
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
          effective_endpoint: primary && "#{primary[:host]}:#{primary[:port]}",
          effective_endpoint_family: primary && primary[:family].to_s,
          fallback_endpoint: fallback && "#{fallback[:host]}:#{fallback[:port]}",
          listen_port: p.listen_port,
          status: p.status,
          tags: Array(p.tags),
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
        unless bridge.mark_active!
          hint = bridge.state == "removed" ? " — use readopt to revive a removed bridge" : ""
          return error_result("cannot activate a #{bridge.state} host bridge#{hint}")
        end

        success_result(host_bridge: serialize_host_bridge(bridge.reload))
      end

      # Release a HostBridge via the allocator. Default `force: false`
      # keeps the short_id reserved during the draining grace window
      # (lets in-flight taps drain without short_id collision); `force:
      # true` releases immediately. Operators using this from the UI
      # generally want force: true since the UI's arm-and-confirm gate
      # is the equivalent safety net.
      def release_host_bridge(params)
        bridge = ::Sdwan::HostBridge.where(account_id: @account.id).find(params[:id])
        ::Sdwan::HostBridgeAllocator.release!(bridge, force: params[:force] == true)
        success_result(host_bridge: serialize_host_bridge(bridge.reload))
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
        return error_result("cannot activate a #{switch.state} logical switch") unless switch.mark_active!

        success_result(ovn_logical_switch: serialize_ovn_logical_switch(switch))
      end

      # Mark an OvnLogicalSwitchPort as `active`. Same trap as switches: a
      # port stuck in `pending` is invisible to the compiler even when its
      # parent switch is active.
      def activate_ovn_logical_switch_port(params)
        port = account_ovn_logical_switch_ports.find(params[:port_id])
        return error_result("cannot activate a #{port.state} logical switch port") unless port.mark_active!

        success_result(ovn_logical_switch_port: serialize_ovn_logical_switch_port(port))
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
        success_result(ovn_deployments: scope.order(:created_at).map { |d| serialize_ovn_deployment(d) })
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
        success_result(
          ovn_logical_switches: scope.includes(:ports).order(:created_at).map { |s| serialize_ovn_logical_switch_with_ports(s) }
        )
      end

      def delete_ovn_logical_switch_port(params)
        port = account_ovn_logical_switch_ports.find(params[:port_id])
        name = port.name
        port.destroy!
        success_result(deleted: true, port_id: params[:port_id], name: name)
      rescue ActiveRecord::InvalidForeignKey => e
        error_result("FK blocks destroy: #{e.message}")
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

      # ─── Phase O6 follow-up — OVN ACLs ──────────────────────────────

      def create_ovn_acl(params)
        switch = account_ovn_logical_switches.find(params[:logical_switch_id])
        acl = switch.acls.create!(
          account: @account,
          name: params[:name],
          direction: params[:direction].to_s,
          priority: params[:priority].present? ? params[:priority].to_i : ::Sdwan::OvnAcl::DEFAULT_PRIORITY,
          match: params[:match],
          action: params[:acl_action].to_s
        )
        # Auto-activate so the compiler emits in the same call. Mirrors
        # the SdwanOvnApplyAclExecutor skill's auto-activate step.
        acl.mark_active!
        success_result(ovn_acl: serialize_ovn_acl(acl))
      end

      def delete_ovn_acl(params)
        acl = ::Sdwan::OvnAcl.where(account_id: @account.id).find(params[:acl_id])
        name = acl.name
        acl.destroy!
        success_result(deleted: true, acl_id: params[:acl_id], name: name)
      end

      def delete_ovn_logical_switch(params)
        sw = account_ovn_logical_switches.find(params[:logical_switch_id])
        name = sw.name
        sw.destroy!
        success_result(deleted: true, logical_switch_id: params[:logical_switch_id], name: name)
      rescue ActiveRecord::InvalidForeignKey => e
        error_result("FK blocks destroy: #{e.message}")
      end

      def delete_ovn_deployment(params)
        dep = ::Sdwan::OvnDeployment.where(account_id: @account.id).find(params[:deployment_id])
        # OvnDeployment is the per-account OVN control plane row and has no
        # `name` column/method (unlike acls/switches/ports) — report its
        # status instead so a botched deployment can still be torn down.
        status = dep.status
        dep.destroy!
        success_result(deleted: true, deployment_id: params[:deployment_id], status: status)
      rescue ActiveRecord::InvalidForeignKey => e
        error_result("FK blocks destroy: #{e.message}")
      end

      def delete_ipfix_collector(params)
        col = ::Sdwan::IpfixCollector.where(account_id: @account.id).find(params[:collector_id])
        name = col.name
        col.destroy!
        success_result(deleted: true, collector_id: params[:collector_id], name: name)
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
        # Compiler order: priority desc, name asc.
        acls = scope.order(priority: :desc, name: :asc).to_a
        success_result(
          ovn_acls: acls.map { |a| serialize_ovn_acl(a) },
          count: acls.size,
          filters: {
            logical_switch_id: params[:logical_switch_id],
            sdwan_ovn_deployment_id: params[:sdwan_ovn_deployment_id]
          }.compact
        )
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
