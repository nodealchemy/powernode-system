# frozen_string_literal: true

# Sdwan::Bgp::ConfigCompiler — emits a per-peer FRR config (`frr.conf`
# fragment) for one network. The agent's frr_applier writes the result
# to /etc/frr/frr.conf and signals FRR to reload.
#
# Output is a Hash with two parts:
#   :frr_text → the human-readable FRR config (operator-debuggable)
#   :neighbors → structured neighbor list for the agent to enable AFI/SAFI
#                without parsing the text
#
# The compiler is route-reflector-aware: hub peers (publicly_reachable)
# in iBGP networks are configured as RRs; spokes are configured as RR
# clients with one neighbor entry per RR (default redundancy = 1, but
# operators can flip multiple hubs to RR for redundancy).
#
# Slice 9c of the SDWAN plan.
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
        @account_bgp = ::Sdwan::AccountBgp.find_by(account_id: peer.account_id)
      end

      # Returns the structured BGP config for inclusion in
      # TopologyCompiler#compile_peer_view → forwarded to the agent.
      def compile
        return disabled_config unless ibgp_enabled?

        as_number = @account_bgp.as_number
        router_id = ::Sdwan::Bgp::RouterIdResolver.for_peer(@peer)
        neighbors = neighbors_for(@peer)
        # Slice 9e — compile applicable route policies into FRR
        # auxiliary objects + route-map blocks + per-neighbor assignments.
        policy_output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(@peer)

        {
          enabled: true,
          as_number: as_number,
          router_id: router_id,
          is_route_reflector: route_reflector?(@peer),
          route_reflector_client: rr_client?(@peer),
          neighbors: neighbors,
          networks: networks_to_announce,
          hold_time_seconds: DEFAULT_HOLD_SECONDS,
          keepalive_seconds: DEFAULT_KEEPALIVE_SECONDS,
          graceful_restart: true,
          # Slice 9e — surface the resolved policy attachment so the
          # operator UI can show "this peer's iBGP traffic is filtered
          # by these policies" without having to recompile.
          policies: policy_output.except(:neighbor_assignments),
          neighbor_route_maps: policy_output[:neighbor_assignments],
          frr_text: render_frr_text(as_number: as_number,
                                    router_id: router_id,
                                    neighbors: neighbors,
                                    policy_output: policy_output)
        }
      end

      private

      def disabled_config
        { enabled: false, neighbors: [], networks: [] }
      end

      def ibgp_enabled?
        @network.respond_to?(:ibgp_routing?) &&
          @network.ibgp_routing? &&
          @account_bgp&.enabled?
      end

      # In a hub-and-spoke RR topology:
      #  - All hubs (publicly_reachable=true) are RRs by default
      #  - Spokes are RR clients to every hub
      #  - Operators can override via Peer#bgp_route_reflector_client
      def route_reflector?(peer)
        return false unless ibgp_enabled?
        return true if peer.publicly_reachable?

        false
      end

      def rr_client?(peer)
        return false if route_reflector?(peer)

        peer.bgp_route_reflector_client || !peer.publicly_reachable?
      end

      # Slice 9c topology shape:
      #  - If THIS peer is a route reflector → neighbor every other peer
      #    in the network (full inbound mesh; RR forwards iBGP between
      #    its clients without breaking the iBGP no-loop rule).
      #  - If THIS peer is a spoke → neighbor only the route reflectors.
      def neighbors_for(peer)
        all_peers = @network.peers.where.not(id: peer.id).to_a
        target_peers = if route_reflector?(peer)
                         all_peers
                       else
                         all_peers.select { |p| route_reflector?(p) }
                       end

        target_peers.map do |np|
          {
            neighbor_peer_id: np.id,
            neighbor_address: np.assigned_address.to_s.split("/").first, # strip /128
            remote_as: @account_bgp.as_number, # iBGP — same AS on both sides
            route_reflector_client: route_reflector?(peer) && rr_client?(np),
            description: "iBGP to #{np.id}"
          }
        end
      end

      # CIDRs that THIS peer announces into BGP:
      #  - Its own /128 (always — basic reachability)
      #  - The network's /64 if Network.advertise_overlay_subnet
      #  - Every prefix in Peer.lan_subnets (slice 9a static decl)
      #  - Every VIP this peer holds (slice 9b)
      def networks_to_announce
        out = [@peer.assigned_address.to_s]
        out << @network.cidr_64 if advertise_overlay_subnet?
        out.concat(Array(@peer.lan_subnets))
        out.concat(vip_cidrs_held_by_self)
        out.compact.uniq
      end

      def advertise_overlay_subnet?
        @network.respond_to?(:advertise_overlay_subnet) &&
          @network.advertise_overlay_subnet
      end

      def vip_cidrs_held_by_self
        return [] unless @network.respond_to?(:virtual_ips)

        @network.virtual_ips.where(state: %w[active pending]).filter_map do |vip|
          holders = Array(vip.holder_peer_ids)
          next nil if holders.empty?
          # Static-mode VIPs: only primary holder announces.
          # Anycast VIPs: every holder announces (BGP closest-path picks).
          holds = vip.anycast? ? holders.include?(@peer.id) : holders.first == @peer.id
          next nil unless holds

          vip.cidr
        end
      end

      # Render an FRR-readable config block. The agent writes this to
      # /etc/frr/frr.conf wholesale (the platform owns the file; FRR is
      # never operator-edited). Format follows FRR 8.x's `vtysh` syntax.
      #
      # Slice 9e — auxiliary objects (prefix/as-path/community lists) and
      # route-map blocks are emitted BEFORE the `router bgp` block so
      # FRR's parser sees them as defined when the router-bgp config
      # references them via `neighbor X route-map Y in`.
      def render_frr_text(as_number:, router_id:, neighbors:, policy_output: nil)
        lines = []
        lines << "! Powernode SDWAN — generated by Sdwan::Bgp::ConfigCompiler"
        lines << "! Network #{@network.id} peer #{@peer.id}"
        lines << "frr defaults traditional"
        lines << "hostname pn-#{@peer.id.to_s.first(8)}"
        lines << "log syslog informational"
        lines << "service integrated-vtysh-config"
        lines << "!"

        # Slice 9e — emit auxiliary objects + route-map blocks first.
        if policy_output
          policy_output[:prefix_lists].each      { |l| lines << l }
          policy_output[:ipv6_prefix_lists].each { |l| lines << l }
          policy_output[:as_path_lists].each     { |l| lines << l }
          policy_output[:community_lists].each   { |l| lines << l }
          lines << "!" if (policy_output[:prefix_lists].any? || policy_output[:ipv6_prefix_lists].any? ||
                          policy_output[:as_path_lists].any? || policy_output[:community_lists].any?)

          policy_output[:route_maps].each { |rm| lines << rm }
          lines << "!" if policy_output[:route_maps].any?
        end

        lines << "router bgp #{as_number}"
        lines << " bgp router-id #{router_id}"
        lines << " no bgp default ipv4-unicast"
        lines << " bgp graceful-restart"
        lines << " timers bgp #{DEFAULT_KEEPALIVE_SECONDS} #{DEFAULT_HOLD_SECONDS}"
        lines << " !"

        neighbors.each do |n|
          addr = n[:neighbor_address]
          lines << " neighbor #{addr} remote-as #{n[:remote_as]}"
          lines << " neighbor #{addr} description #{n[:description]}"
          lines << " neighbor #{addr} update-source #{@peer.assigned_address.to_s.split('/').first}"
          lines << " neighbor #{addr} ebgp-multihop 2" if false # iBGP — never
        end
        lines << " !"

        neighbor_assignments = policy_output ? (policy_output[:neighbor_assignments] || {}) : {}

        # IPv6 unicast AFI/SAFI — the overlay rides ULAs.
        lines << " address-family ipv6 unicast"
        networks_to_announce.each do |cidr|
          lines << "  network #{cidr}" if cidr.include?(":")
        end
        neighbors.each do |n|
          addr = n[:neighbor_address]
          lines << "  neighbor #{addr} activate"
          lines << "  neighbor #{addr} route-reflector-client" if n[:route_reflector_client]
          lines << "  neighbor #{addr} soft-reconfiguration inbound"
          # Slice 9e — apply route-maps per direction.
          if (assignment = neighbor_assignments[addr])
            lines << "  neighbor #{addr} route-map #{assignment[:import]} in"  if assignment[:import]
            lines << "  neighbor #{addr} route-map #{assignment[:export]} out" if assignment[:export]
          end
        end
        lines << " exit-address-family"
        lines << " !"

        # IPv4 unicast AFI/SAFI — for lan_subnets and v4 VIPs (slice 9b).
        v4_announces = networks_to_announce.reject { |c| c.include?(":") }
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
        lines << "line vty"
        lines << "!"
        lines.join("\n") + "\n"
      end
    end
  end
end
