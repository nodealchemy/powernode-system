# frozen_string_literal: true

# Sdwan::Bgp::ConfigCompiler — emits a host-wide FRR config rendered as
# one `router bgp <as> vrf <name>` block per Sdwan::HostVrfAssignment
# bound to the calling peer's host, plus a single global block for
# management/loopback context. Cross-VRF prefix import clauses
# (Sdwan::RouteLeak) are emitted as `import vrf` directives inside the
# destination VRF's address-family block.
#
# Public API: `.compile_for_peer(peer)` is preserved for topology
# compatibility — it returns a BgpConf shape sized for a single peer's
# view, but the `frr_text` field carries the FULL host-wide config
# because FRR is one daemon per host. This means every iBGP-enabled
# peer on a given host will receive the same `frr_text` content; the
# agent writes it once and reloads.
#
# This file replaces the slice-9c single-iBGP-network compiler. The
# old "first iBGP network wins" code path is gone.
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
module Sdwan
  module Bgp
    class ConfigCompiler
      DEFAULT_HOLD_SECONDS      = 90
      DEFAULT_KEEPALIVE_SECONDS = 30

      def self.compile_for_peer(peer)
        new(peer).compile
      end

      def initialize(peer)
        @peer = peer
        @network = peer.network
        @host = peer.node_instance
        @account_bgp = ::Sdwan::AccountBgp.find_by(account_id: peer.account_id)
      end

      # Returns a BgpConf-shaped Hash for the agent. Even though FRR is
      # host-wide, we keep the per-peer return shape so the existing
      # topology_compiler call site does not need to change. The agent
      # reads `frr_text` and writes it verbatim.
      def compile
        return disabled_config unless ibgp_enabled?

        as_number = @account_bgp.as_number
        router_id = ::Sdwan::Bgp::RouterIdResolver.for_peer(@peer)
        # Per-peer neighbors are kept for the operator UI's current
        # "neighbors of this peer" surface — they describe the slice of
        # the iBGP fabric this peer participates in, scoped to its own
        # network. Cross-VRF neighbors are not advertised in this list
        # (route leaks are not iBGP sessions).
        neighbors = neighbors_for(@peer)
        policy_output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(@peer)

        {
          enabled: true,
          as_number: as_number,
          router_id: router_id,
          is_route_reflector: route_reflector?(@peer),
          route_reflector_client: rr_client?(@peer),
          neighbors: neighbors,
          networks: networks_to_announce(@peer),
          hold_time_seconds: DEFAULT_HOLD_SECONDS,
          keepalive_seconds: DEFAULT_KEEPALIVE_SECONDS,
          graceful_restart: true,
          policies: policy_output.except(:neighbor_assignments),
          neighbor_route_maps: policy_output[:neighbor_assignments],
          # vrf_blocks summarises every VRF emitted in frr_text — the
          # operator UI uses it to render a "this host's VRFs" panel
          # without re-parsing the FRR config.
          vrf_blocks: vrf_block_summaries,
          frr_text: render_frr_text
        }
      end

      private

      def disabled_config
        { enabled: false, neighbors: [], networks: [], vrf_blocks: [] }
      end

      def ibgp_enabled?
        @network.respond_to?(:ibgp_routing?) &&
          @network.ibgp_routing? &&
          @account_bgp&.enabled?
      end

      # ----------------------------------------------------------------
      # Per-VRF neighbor + announcement helpers
      # ----------------------------------------------------------------

      # In the hub-spoke RR topology each network maintains:
      #   * hubs (publicly_reachable=true) act as route reflectors
      #   * spokes peer only with the hubs in their own network
      # Cross-VRF neighbors are never inferred; route leaks (Sdwan::RouteLeak)
      # are the only supported way for prefixes to cross VRF boundaries.
      def route_reflector?(peer)
        return false unless network_supports_ibgp?(peer.network)
        return true if peer.publicly_reachable?

        false
      end

      def rr_client?(peer)
        return false if route_reflector?(peer)

        peer.bgp_route_reflector_client || !peer.publicly_reachable?
      end

      def network_supports_ibgp?(network)
        network.respond_to?(:ibgp_routing?) && network.ibgp_routing?
      end

      def neighbors_for(peer)
        all_peers = peer.network.peers.where.not(id: peer.id).to_a
        target_peers = if route_reflector?(peer)
                         all_peers
                       else
                         all_peers.select { |p| route_reflector?(p) }
                       end

        target_peers.map do |np|
          {
            neighbor_peer_id: np.id,
            neighbor_address: np.assigned_address.to_s.split("/").first,
            remote_as: @account_bgp.as_number,
            route_reflector_client: route_reflector?(peer) && rr_client?(np),
            description: "iBGP to #{np.id}"
          }
        end
      end

      def networks_to_announce(peer)
        out = [peer.assigned_address.to_s]
        out << peer.network.cidr_64 if advertise_overlay_subnet?(peer.network)
        out.concat(Array(peer.lan_subnets))
        out.concat(vip_cidrs_held_by(peer))
        out.compact.uniq
      end

      def advertise_overlay_subnet?(network)
        network.respond_to?(:advertise_overlay_subnet) &&
          network.advertise_overlay_subnet
      end

      def vip_cidrs_held_by(peer)
        net = peer.network
        return [] unless net.respond_to?(:virtual_ips)

        net.virtual_ips.where(state: %w[active pending]).filter_map do |vip|
          holders = Array(vip.holder_peer_ids)
          next nil if holders.empty?

          holds = vip.anycast? ? holders.include?(peer.id) : holders.first == peer.id
          next nil unless holds

          vip.cidr
        end
      end

      # ----------------------------------------------------------------
      # Multi-VRF host enumeration
      # ----------------------------------------------------------------

      # Returns the list of (host_vrf_assignment, peer_on_this_host_in_that_network)
      # pairs the FRR config should emit BGP blocks for. Limits to
      # iBGP-enabled networks; static-only networks have no FRR
      # presence.
      #
      # Nil host (orphan peer with no node_instance) collapses to the
      # single-network slice — used by tests that build peers without
      # a host.
      def vrf_pairs_for_host
        return [[synthetic_assignment_for(@peer), @peer]] if @host.nil?

        ::Sdwan::HostVrfAssignment
          .compilable
          .for_host(@host)
          .includes(network: :peers)
          .filter_map do |hva|
            next unless network_supports_ibgp?(hva.network)

            host_peer = hva.network.peers.find { |p| p.node_instance_id == @host.id }
            next unless host_peer

            [hva, host_peer]
          end
      end

      # When the calling peer has no node_instance (test fixtures
      # building peers in isolation), synthesise a transient assignment
      # so the compiler still produces output without requiring full
      # host wiring. The synthetic table_id is the lowest legal value;
      # nothing persists.
      def synthetic_assignment_for(peer)
        ::Sdwan::HostVrfAssignment.new(
          account_id: peer.account_id,
          node_instance_id: nil,
          network: peer.network,
          table_id: ::Sdwan::HostVrfAssignment::TABLE_ID_MIN,
          vrf_name: peer.network.vrf_name_for(nil)
        )
      end

      def vrf_block_summaries
        vrf_pairs_for_host.map do |hva, _|
          {
            network_id: hva.sdwan_network_id,
            vrf_name: hva.vrf_name,
            table_id: hva.table_id,
            state: hva.state
          }
        end
      end

      # ----------------------------------------------------------------
      # Route-leak rendering
      # ----------------------------------------------------------------

      # All active leaks whose dest network is one of the host's VRFs.
      # The compiler emits one `import vrf <source_vrf>` directive plus
      # an inbound route-map filter per leak. Bidirectional leaks
      # produce two clauses (one per direction).
      def leak_clauses_for(hva)
        dest_network = hva.network
        leaks = ::Sdwan::RouteLeak
                  .compilable
                  .where(account_id: dest_network.account_id)
                  .where("source_network_id = :nid OR dest_network_id = :nid", nid: dest_network.id)
                  .includes(:source_network, :dest_network)

        clauses = []
        leaks.each do |leak|
          leak.directed_pairs.each do |pair|
            next unless pair[:dest].id == dest_network.id

            source_vrf = vrf_name_for_network_on_host(pair[:source])
            next unless source_vrf

            clauses << {
              source_network_id: pair[:source].id,
              source_vrf: source_vrf,
              route_map_name: leak_route_map_name(pair[:source], pair[:dest]),
              prefix_list_name: leak_prefix_list_name(pair[:source], pair[:dest]),
              prefix_filter: Array(leak.prefix_filter)
            }
          end
        end
        clauses
      end

      # Look up the VRF name a sibling network resolves to on this same
      # host. Returns nil if the host doesn't actually carry that
      # network — in which case the leak directive cannot be emitted
      # (FRR rejects `import vrf X` for an unknown VRF X).
      def vrf_name_for_network_on_host(network)
        return network.vrf_name_for(nil) if @host.nil?

        ::Sdwan::HostVrfAssignment
          .compilable
          .for_host(@host)
          .where(sdwan_network_id: network.id)
          .pick(:vrf_name)
      end

      def leak_route_map_name(source_network, dest_network)
        "leak-#{source_network.network_handle}-to-#{dest_network.network_handle}"
      end

      def leak_prefix_list_name(source_network, dest_network)
        "leak-pl-#{source_network.network_handle}-to-#{dest_network.network_handle}"
      end

      # ----------------------------------------------------------------
      # FRR config rendering
      # ----------------------------------------------------------------

      # Produces the host-wide frr.conf text. Layout:
      #
      #   1. Header / global daemon settings
      #   2. VRF definitions (one `vrf <name>\n vni <table_id>\nexit-vrf` per HVA)
      #   3. Auxiliary objects (per-VRF prefix-lists, leak prefix-lists, etc.)
      #   4. Route-map blocks (per-VRF route-policy maps + leak filter maps)
      #   5. Per-VRF `router bgp <as> vrf <name>` blocks
      #   6. Trailing `line vty`
      def render_frr_text
        lines = []
        render_header(lines)
        render_vrf_definitions(lines)
        render_auxiliary_objects(lines)
        render_per_vrf_route_maps(lines)
        render_per_vrf_bgp_blocks(lines)
        lines << "!"
        lines << "line vty"
        lines << "!"
        lines.join("\n") + "\n"
      end

      def render_header(lines)
        lines << "! Powernode SDWAN — generated by Sdwan::Bgp::ConfigCompiler"
        lines << "! Host #{@host&.id || '(orphan)'}"
        lines << "frr defaults traditional"
        lines << "hostname pn-#{(@host&.id || @peer.id).to_s.first(8)}"
        lines << "log syslog informational"
        lines << "service integrated-vtysh-config"
        lines << "!"
      end

      def render_vrf_definitions(lines)
        vrf_pairs_for_host.each do |hva, _|
          lines << "vrf #{hva.vrf_name}"
          # `vni <table_id>` ties the VRF master device to a routing
          # table id FRR can reference; while EVPN/VXLAN deployments
          # use vni for L2 VNI mapping, in our pure L3 setup it just
          # marks the VRF for FRR's address-family bookkeeping.
          lines << " vni #{hva.table_id}"
          lines << "exit-vrf"
          lines << "!"
        end
      end

      def render_auxiliary_objects(lines)
        # Per-VRF route policies first.
        vrf_pairs_for_host.each do |_, host_peer|
          policy_output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(host_peer)
          policy_output[:prefix_lists].each      { |l| lines << l }
          policy_output[:ipv6_prefix_lists].each { |l| lines << l }
          policy_output[:as_path_lists].each     { |l| lines << l }
          policy_output[:community_lists].each   { |l| lines << l }
          if policy_output[:prefix_lists].any? || policy_output[:ipv6_prefix_lists].any? ||
             policy_output[:as_path_lists].any? || policy_output[:community_lists].any?
            lines << "!"
          end
        end

        # Then per-leak prefix-lists. Empty filter lists permit all.
        vrf_pairs_for_host.each do |hva, _|
          leak_clauses_for(hva).each do |clause|
            entries = clause[:prefix_filter]
            if entries.empty?
              # No filter → permit all under the standard list name so
              # the route-map can still reference it. seq 5 is the
              # canonical "default permit" entry.
              lines << "ipv6 prefix-list #{clause[:prefix_list_name]} seq 5 permit ::/0 le 128"
            else
              # deny entries first (FRR evaluates in order; explicit
              # denies must precede a fall-through permit).
              ordered = entries.sort_by { |e| (e["action"] || e[:action]).to_s == "deny" ? 0 : 1 }
              ordered.each_with_index do |entry, idx|
                cidr = entry["cidr"] || entry[:cidr]
                action = entry["action"] || entry[:action]
                family = cidr.include?(":") ? "ipv6" : "ip"
                lines << "#{family} prefix-list #{clause[:prefix_list_name]} seq #{(idx + 1) * 5} #{action} #{cidr}"
              end
            end
          end
        end
        lines << "!" if vrf_pairs_for_host.any? { |hva, _| leak_clauses_for(hva).any? }
      end

      def render_per_vrf_route_maps(lines)
        vrf_pairs_for_host.each do |_, host_peer|
          policy_output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(host_peer)
          policy_output[:route_maps].each { |rm| lines << rm }
          lines << "!" if policy_output[:route_maps].any?
        end

        # Leak filter maps — one per (source, dest) directed pair.
        vrf_pairs_for_host.each do |hva, _|
          leak_clauses_for(hva).each do |clause|
            lines << "route-map #{clause[:route_map_name]} permit 10"
            lines << " match ipv6 address prefix-list #{clause[:prefix_list_name]}"
            lines << "!"
          end
        end
      end

      def render_per_vrf_bgp_blocks(lines)
        as_number = @account_bgp.as_number

        vrf_pairs_for_host.each do |hva, host_peer|
          neighbors = neighbors_for(host_peer)
          policy_output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(host_peer)
          neighbor_assignments = policy_output[:neighbor_assignments] || {}
          announces = networks_to_announce(host_peer)

          lines << "router bgp #{as_number} vrf #{hva.vrf_name}"
          lines << " bgp router-id #{::Sdwan::Bgp::RouterIdResolver.for_peer(host_peer)}"
          lines << " no bgp default ipv4-unicast"
          lines << " bgp graceful-restart"
          lines << " timers bgp #{DEFAULT_KEEPALIVE_SECONDS} #{DEFAULT_HOLD_SECONDS}"
          lines << " !"

          neighbors.each do |n|
            addr = n[:neighbor_address]
            lines << " neighbor #{addr} remote-as #{n[:remote_as]}"
            lines << " neighbor #{addr} description #{n[:description]}"
            lines << " neighbor #{addr} update-source #{host_peer.assigned_address.to_s.split('/').first}"
          end
          lines << " !"

          # IPv6 unicast AFI — overlay rides ULA /128s.
          lines << " address-family ipv6 unicast"
          announces.each do |cidr|
            lines << "  network #{cidr}" if cidr.include?(":")
          end
          neighbors.each do |n|
            addr = n[:neighbor_address]
            lines << "  neighbor #{addr} activate"
            lines << "  neighbor #{addr} route-reflector-client" if n[:route_reflector_client]
            lines << "  neighbor #{addr} soft-reconfiguration inbound"
            if (assignment = neighbor_assignments[addr])
              lines << "  neighbor #{addr} route-map #{assignment[:import]} in"  if assignment[:import]
              lines << "  neighbor #{addr} route-map #{assignment[:export]} out" if assignment[:export]
            end
          end
          # Render leak imports inside this VRF's IPv6 AF — leaks pull
          # prefixes from sibling VRFs into this VRF's RIB.
          leak_clauses_for(hva).each do |clause|
            lines << "  import vrf #{clause[:source_vrf]}"
            lines << "  import vrf route-map #{clause[:route_map_name]} in"
          end
          lines << " exit-address-family"
          lines << " !"

          # IPv4 unicast AFI for lan_subnets / v4 VIPs.
          v4_announces = announces.reject { |c| c.include?(":") }
          if v4_announces.any?
            lines << " address-family ipv4 unicast"
            v4_announces.each { |cidr| lines << "  network #{cidr}" }
            neighbors.each do |n|
              addr = n[:neighbor_address]
              lines << "  neighbor #{addr} activate"
              lines << "  neighbor #{addr} route-reflector-client" if n[:route_reflector_client]
              if (assignment = neighbor_assignments[addr])
                lines << "  neighbor #{addr} route-map #{assignment[:import]} in"  if assignment[:import]
                lines << "  neighbor #{addr} route-map #{assignment[:export]} out" if assignment[:export]
              end
            end
            lines << " exit-address-family"
          end
          lines << "!"
        end
      end
    end
  end
end
