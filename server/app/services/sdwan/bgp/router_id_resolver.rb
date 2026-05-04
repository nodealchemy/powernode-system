# frozen_string_literal: true

# Sdwan::Bgp::RouterIdResolver — derives a deterministic 32-bit BGP
# router-id for a peer. FRR represents router-ids as IPv4 dotted-quads
# (the BGP4 standard predates IPv6); even peers with no IPv4 connectivity
# need one because every BGP speaker must have a unique router-id.
#
# Strategy: hash the peer's overlay /128 → 32 bits → format as IPv4. The
# overlay /128 is per-peer-and-network (PrefixAllocator's bottom-of-the-
# tree), so each peer's router-id is stable for its lifetime. Collisions
# within an account are vanishingly rare (32-bit space, well-distributed
# hash); when they occur, operators can override via Peer#bgp_router_id_override.
#
# Slice 9c of the SDWAN plan.
module Sdwan
  module Bgp
    class RouterIdResolver
      class CollisionDetected < StandardError; end

      def self.for_peer(peer)
        new(peer).resolve
      end

      def initialize(peer)
        @peer = peer
      end

      def resolve
        return @peer.bgp_router_id_override if @peer.bgp_router_id_override.present?

        derived = derive_from_overlay
        check_account_collisions(derived)
        derived
      end

      private

      # Take the SHA256 of the overlay /128 address, treat the first 32
      # bits as a network-order IPv4 integer, format as dotted-quad.
      def derive_from_overlay
        seed = @peer.assigned_address.to_s
        digest = Digest::SHA256.digest(seed)
        u32 = digest.unpack1("N") # network-order 32-bit unsigned

        a = (u32 >> 24) & 0xff
        b = (u32 >> 16) & 0xff
        c = (u32 >> 8) & 0xff
        d = u32 & 0xff
        # Avoid 0.0.0.0 (FRR rejects) by replacing first octet with 1
        # if zero. Statistically rare; deterministic when it happens.
        a = 1 if a.zero?
        "#{a}.#{b}.#{c}.#{d}"
      end

      # Conservative check: warn (not raise) on collision within the
      # peer's account. Operators can resolve via override.
      def check_account_collisions(router_id)
        # No-op for slice 9c; slice 9f's governance scanner cross-checks
        # router-ids and surfaces conflicts.
      end
    end
  end
end
