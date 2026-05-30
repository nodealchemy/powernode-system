# frozen_string_literal: true

# Full-mesh topology strategy. Every peer in the network connects directly
# to every OTHER peer — no hub forwarding, no spoke funnelling. Each peer's
# view contains one [Peer] entry per sibling, with that sibling's full /128
# AllowedIPs (plus its lan_subnets / held VIPs in static-routing mode) so
# the kernel routes overlay packets straight to the owning host.
#
# Contrast with HubAndSpoke (same module, sibling file):
#   - Hub/spoke splits the fleet into forwarders (hubs) + leaves (spokes);
#     a spoke only ever talks to a hub and the hub relays.
#   - Full-mesh gives every peer a direct tunnel to every other peer. There
#     is no relay hop, so intra-overlay latency is minimal — at the cost of
#     O(n^2) tunnels, which is why hub_and_spoke remains the default for
#     large fleets and full_mesh suits small, latency-sensitive sets
#     (the `mesh`/`full_mesh` option exposed by
#     ConfigureSdwanForProjectExecutor + SdwanFederationComposeExecutor).
#
# NAT traversal: a peer sitting behind NAT must keep its mapping warm toward
# any peer that owns a dialable endpoint. We therefore set
# PersistentKeepalive on every entry whose target is `publicly_reachable`
# (i.e. advertises an endpoint) — mirroring the hub-directed keepalive in
# HubAndSpoke#hub_view. Peers with no endpoint are dialled outbound by the
# reachable side, so no keepalive is emitted toward them.
#
# A peer with no usable endpoint anywhere in the mesh still receives the
# full sibling list; tunnels to other unreachable peers simply never
# complete a handshake until at least one side gains a public endpoint —
# the same isolation semantics HubAndSpoke documents for hub-less networks.
#
# Mirrors the HubAndSpoke strategy contract: `initialize(network:,
# federation_prefixes:)` +
# `peers_for(peer)` returning the per-peer [Peer] entry list that
# Sdwan::TopologyCompiler#compile_peer_view folds into `peers:`.
module Sdwan
  module TopologyStrategies
    class FullMesh
      DEFAULT_PERSISTENT_KEEPALIVE = 25

      def initialize(network:, federation_prefixes: [])
        @network = network
        @peers = network.peers.includes(:keys).to_a
        # Slice 4: user-VPN clients ride the mesh too — every mesh peer can
        # reach an active user_device directly (clients dial outbound, so
        # no endpoint/keepalive on the device entries).
        @user_devices = network.respond_to?(:user_devices) ? network.user_devices.active.to_a : []
        # Slice 9b — VIPs are reachable through their holder peers.
        # peer_id => [vip_cidrs] map; computed once per compile.
        @vips_by_holder = build_vips_by_holder_map
        # Phase 3 — federated remote prefixes (from
        # Sdwan::FederationPrefixResolver), owned by remote federated
        # Powernode installs. A full mesh has no hub relay, so federated
        # traffic egresses through ONE designated publicly_reachable peer
        # (the mesh analog of HubAndSpoke's hub egress). We fold the prefixes
        # into ONLY that single egress peer's AllowedIPs — folding into every
        # public peer would list the same prefix under multiple [Peer] keys on
        # one WireGuard interface, whose cryptokey routing requires AllowedIPs
        # disjoint across peers (the kernel silently assigns the prefix to
        # whichever peer was configured last). The egress is chosen
        # deterministically (lowest peer id) so every peer's view agrees on the
        # same next hop. Empty list = no federation = no change.
        @federation_prefixes = Array(federation_prefixes).reject(&:blank?).uniq
        @federation_egress_peer_id =
          @federation_prefixes.empty? ? nil : @peers.select(&:publicly_reachable).min_by(&:id)&.id
      end

      # Every peer sees every OTHER peer directly, plus every active
      # user_device. There is no hub/spoke asymmetry: the view is identical
      # in shape for every peer, differing only in which sibling is excluded
      # (self) and which VIPs/subnets each sibling carries.
      def peers_for(self_peer)
        peer_entries = @peers.reject { |p| p.id == self_peer.id }.filter_map do |other|
          key = other.keys.find { |k| k.revoked_at.nil? }
          next unless key

          allowed = [ other.assigned_address ]
          if static_subnet_routing?
            allowed += Array(other.lan_subnets)
            # Slice 9b — VIPs held by `other` route directly to `other`.
            allowed += Array(@vips_by_holder[other.id])
            # K3s overlay — when the network carries flannel pod traffic and
            # `other` is a k3s host, route its pod CIDR straight to it. In a
            # full mesh there's no hub to relay through, so each k3s peer's
            # pod CIDR is reachable directly via that peer's tunnel.
            allowed += pod_subnet_cidrs_for(other)
          end
          # Phase 3 — federated remote prefixes egress through the single
          # designated egress peer (@federation_egress_peer_id). Not gated on
          # static_subnet_routing?: WG AllowedIPs is a cryptographic routing
          # filter, so the prefix must be permitted on the egress peer's entry
          # even when FRR distributes the route dynamically. Folding into one
          # peer (not every public one) keeps AllowedIPs disjoint per interface.
          allowed += @federation_prefixes if @federation_egress_peer_id && other.id == @federation_egress_peer_id

          build_peer_entry(other, key, allowed_ips: allowed.uniq,
                                       keepalive: other.publicly_reachable ? DEFAULT_PERSISTENT_KEEPALIVE : nil)
        end

        peer_entries + user_device_entries
      end

      private

      def user_device_entries
        @user_devices.map do |dev|
          {
            peer_id: dev.id,
            public_key: dev.public_key,
            endpoint: nil,                          # clients connect outbound; mesh peers don't dial them
            endpoint_family: nil,
            fallback_endpoint: nil,
            allowed_ips: [ dev.assigned_address ],
            persistent_keepalive: nil,              # client-side handles its own keepalive
            kind: "user_device"                     # hint for the agent + UI
          }
        end
      end

      # Returns [pod_subnet_prefix] when the network carries flannel pod
      # traffic AND `peer` is a k3s host; otherwise []. Identical predicate
      # to HubAndSpoke#pod_subnet_cidrs_for — full-mesh just routes the CIDR
      # to the owning peer directly rather than through a hub.
      def pod_subnet_cidrs_for(peer)
        return [] unless @network.respond_to?(:pod_subnet_prefix)
        return [] if @network.pod_subnet_prefix.blank?
        return [] unless peer&.respond_to?(:k3s_host?) && peer.k3s_host?

        [ @network.pod_subnet_prefix ]
      end

      def static_subnet_routing?
        @network.respond_to?(:static_routing?) ? @network.static_routing? : true
      end

      # Slice 9b — { peer_id => [vip_cidr, ...] }. Static mode picks the
      # primary holder (head of holder_peer_ids); anycast mode (slice 9c
      # BGP) populates every holder so all of them advertise the VIP.
      def build_vips_by_holder_map
        return {} unless @network.respond_to?(:virtual_ips)

        @network.virtual_ips.where(state: %w[active pending]).each_with_object({}) do |vip, acc|
          holders = Array(vip.holder_peer_ids)
          next if holders.empty?

          target = vip.anycast? ? holders : [ holders.first ]
          target.each do |peer_id|
            acc[peer_id] ||= []
            acc[peer_id] << vip.cidr
          end
        end
      end

      # Slice 7a: emits a single-Endpoint [Peer] entry (WireGuard's protocol
      # accepts only one Endpoint per [Peer]) plus a fallback_endpoint hint
      # that the agent uses when the primary's reachability fails. Identical
      # to HubAndSpoke#build_peer_entry — the entry SHAPE is strategy-agnostic.
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
