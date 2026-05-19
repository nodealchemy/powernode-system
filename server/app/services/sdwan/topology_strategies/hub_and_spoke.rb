# frozen_string_literal: true

# Hub-and-spoke v1 topology strategy. One (or more) peers in a network are
# flagged `publicly_reachable: true` — they're the hubs. Spokes connect
# outbound to a hub on UDP/51820 with PersistentKeepalive=25 to maintain
# the NAT mapping. The hub forwards intra-network traffic.
#
# Hub view:   sees every other peer in the network with their full /128
#             AllowedIPs (so the hub can route packets to the right spoke).
# Spoke view: sees only the hubs, with AllowedIPs covering the entire /64
#             (so all overlay traffic exits through the hub).
#
# Networks with zero hubs are isolated: TopologyCompiler emits an empty
# `peers:` list for every spoke, and the agent reconciler will keep the
# interface up but with no working tunnels. Surfacing that state to the
# operator is a slice 3 (frontend) concern.
#
# Slice 1 of the SDWAN plan.
module Sdwan
  module TopologyStrategies
    class HubAndSpoke
      DEFAULT_PERSISTENT_KEEPALIVE = 25

      def initialize(network:)
        @network = network
        @peers = network.peers.includes(:keys).to_a
        @hubs, @spokes = @peers.partition(&:publicly_reachable)
        # Slice 4: user-VPN clients also flow through hubs.
        @user_devices = network.respond_to?(:user_devices) ? network.user_devices.active.to_a : []
        # Slice 9b — VIPs are reachable through their holder peers.
        # peer_id => [vip_cidrs] map; computed once per compile.
        @vips_by_holder = build_vips_by_holder_map
      end

      def peers_for(peer)
        return hub_view(peer) if peer.publicly_reachable

        spoke_view(peer)
      end

      private

      # The hub sees every other peer in the network plus every active
      # user_device. Each entry's AllowedIPs is its own /128, plus its
      # `lan_subnets` (slice 9a) when the network is in static-routing
      # mode — so the kernel routes packets for those LAN prefixes
      # through the hub→spoke tunnel. iBGP networks (slice 9c) skip the
      # static fold-in; FRR injects routes dynamically.
      def hub_view(self_peer)
        peer_entries = @peers.reject { |p| p.id == self_peer.id }.filter_map do |other|
          key = other.keys.find { |k| k.revoked_at.nil? }
          next unless key

          allowed = [other.assigned_address]
          allowed += Array(other.lan_subnets) if static_subnet_routing?
          # Slice 9b — VIPs held by `other` route through `other`.
          allowed += Array(@vips_by_holder[other.id]) if static_subnet_routing?
          build_peer_entry(other, key, allowed_ips: allowed.uniq,
                                       keepalive: other.publicly_reachable ? DEFAULT_PERSISTENT_KEEPALIVE : nil)
        end

        user_device_entries = @user_devices.map do |dev|
          {
            peer_id: dev.id,
            public_key: dev.public_key,
            endpoint: nil,                          # clients connect outbound; hub doesn't dial them
            endpoint_family: nil,
            fallback_endpoint: nil,
            allowed_ips: [dev.assigned_address],
            persistent_keepalive: nil,              # client-side handles its own keepalive
            kind: "user_device"                     # hint for the agent + UI
          }
        end

        peer_entries + user_device_entries
      end

      # The spoke sees only the hubs. AllowedIPs covers the full /64 so
      # overlay traffic routes through the hub. In static-routing mode,
      # we ALSO include the union of every other peer's lan_subnets — so
      # spoke A knows to send packets for "10.50.0.0/16" through a hub
      # (which then forwards to whichever spoke owns that prefix).
      def spoke_view(self_peer)
        external_subnets = static_subnet_routing? ? other_peers_lan_subnets : []
        # Slice 9b — every VIP is reachable through any hub; the hub
        # forwards it on to the actual holder.
        vip_cidrs = static_subnet_routing? ? all_vip_cidrs : []
        # K3s overlay — when the network carries flannel pod traffic
        # and this spoke is a k3s host, route the cluster's pod CIDR
        # through every hub. The hub then forwards pod packets to the
        # correct holder via the per-peer /128 + flannel host-gw kernel
        # routes that flannel installs on each k3s node from the K8s
        # API. Non-k3s spokes don't carry pod-CIDR routes (no business
        # with pod IPs).
        pod_cidrs = pod_subnet_cidrs_for(self_peer)
        @hubs.filter_map do |hub|
          key = hub.keys.find { |k| k.revoked_at.nil? }
          next unless key
          next unless hub.primary_endpoint

          allowed = [@network.cidr_64] + external_subnets + vip_cidrs +
                    (static_subnet_routing? ? Array(hub.lan_subnets) : []) +
                    pod_cidrs
          build_peer_entry(hub, key, allowed_ips: allowed.uniq,
                                     keepalive: DEFAULT_PERSISTENT_KEEPALIVE)
        end
      end

      # Returns [pod_subnet_prefix] when the network carries flannel pod
      # traffic AND this peer is a k3s host; otherwise []. The pod CIDR
      # routed through hubs lets the spoke's kernel direct pod-egress
      # packets into the WireGuard tunnel rather than the host primary
      # NIC. Returns an empty list (no behavior change) for any combination
      # that doesn't enable pod overlay routing.
      def pod_subnet_cidrs_for(peer)
        return [] unless @network.respond_to?(:pod_subnet_prefix)
        return [] if @network.pod_subnet_prefix.blank?
        return [] unless peer&.respond_to?(:k3s_host?) && peer.k3s_host?

        [@network.pod_subnet_prefix]
      end

      def static_subnet_routing?
        @network.respond_to?(:static_routing?) ? @network.static_routing? : true
      end

      def other_peers_lan_subnets
        @peers.flat_map { |p| Array(p.lan_subnets) }.uniq
      end

      # Slice 9b — { peer_id => [vip_cidr, ...] }. Static mode picks the
      # primary holder (head of holder_peer_ids); anycast mode (slice 9c
      # BGP) populates every holder so all of them advertise the VIP.
      def build_vips_by_holder_map
        return {} unless @network.respond_to?(:virtual_ips)

        @network.virtual_ips.where(state: %w[active pending]).each_with_object({}) do |vip, acc|
          holders = Array(vip.holder_peer_ids)
          next if holders.empty?

          target = vip.anycast? ? holders : [holders.first]
          target.each do |peer_id|
            acc[peer_id] ||= []
            acc[peer_id] << vip.cidr
          end
        end
      end

      # All VIP CIDRs in the network — used for spoke AllowedIPs so
      # spokes know to route any VIP traffic through the hub.
      def all_vip_cidrs
        return [] unless @network.respond_to?(:virtual_ips)

        @network.virtual_ips.where(state: %w[active pending]).pluck(:cidr).uniq
      end

      # Slice 7a: emits a single-Endpoint [Peer] entry (WireGuard's protocol
      # accepts only one Endpoint per [Peer]) plus a fallback_endpoint hint
      # that the agent uses when the primary's reachability fails.
      def build_peer_entry(peer, key, allowed_ips:, keepalive:)
        primary = peer.primary_endpoint
        fallback = peer.fallback_endpoint
        {
          peer_id: peer.id,
          public_key: key.public_key,
          endpoint: primary && "#{primary[:host]}:#{primary[:port]}",
          endpoint_family: primary && primary[:family].to_s,
          fallback_endpoint: fallback && {
            host: fallback[:host],
            port: fallback[:port],
            family: fallback[:family].to_s
          },
          allowed_ips: allowed_ips,
          persistent_keepalive: keepalive
        }
      end
    end
  end
end
