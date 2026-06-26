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
# hash) — the per-account `assigned_address` UNIQUE constraint means two
# peers can only collide through the 32-bit hash truncation, never through
# a shared seed.
#
# When a collision DOES occur we auto-resolve it deterministically: the
# colliding group is salt-perturbed so every peer keeps a stable, unique
# id. The assignment is a pure function of the account's peer-set +
# overrides — NOT of which peer triggered the compile / resolution order —
# so ids never flap between compiles (which would churn iBGP routes).
# Operators may still pin an id explicitly via Peer#bgp_router_id_override.
#
# Slice 9c of the SDWAN plan; collision auto-resolution + explicit-strategy
# fallback warning added under decision D11.
module Sdwan
  module Bgp
    class RouterIdResolver
      class CollisionDetected < StandardError; end

      # Upper bound on the salt search. The 32-bit hash space is enormous
      # relative to any plausible account peer-count, so a free salt is
      # found almost immediately; 255 is a generous ceiling that bounds the
      # work and turns a pathological (effectively impossible) saturation
      # into a loud failure rather than an infinite loop.
      MAX_SALT = 255

      def self.for_peer(peer)
        new(peer).resolve
      end

      def initialize(peer)
        @peer = peer
      end

      def resolve
        # Operator override wins outright — a fixed point, never perturbed.
        return @peer.bgp_router_id_override if @peer.bgp_router_id_override.present?

        router_id = assignment.fetch(@peer.id)
        warn_if_explicit_strategy_without_override(router_id)
        router_id
      end

      private

      # Take the SHA256 of the overlay /128 address, treat the first 32
      # bits as a network-order IPv4 integer, format as dotted-quad.
      #
      # salt 0 (the default) seeds on the bare address and reproduces the
      # historical derivation byte-for-byte — non-colliding peers are
      # unchanged. salt > 0 mixes the salt into the seed to produce a
      # different-but-still-deterministic id used only to break a collision.
      def derive_from_overlay(peer: @peer, salt: 0)
        base = peer.assigned_address.to_s
        seed = salt.zero? ? base : "#{base}##{salt}"
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

      # The per-account router-id assignment, memoized on the instance.
      # Maps peer_id => router_id for every override-less peer in the
      # account. Computed once (one query) from the full account peer-set so
      # the result for any given peer is independent of which peer is being
      # resolved.
      def assignment
        @assignment ||= compute_assignment
      end

      # Deterministic, order-independent collision resolution.
      #
      #   1. Every override is a FIXED point — always claimed, never moved.
      #   2. Walk the override-less peers in stable `id` order. For each,
      #      pick the LOWEST salt s >= 0 whose derive(peer, salt: s) is not
      #      already claimed (by an override or an earlier-assigned peer)
      #      and claim it.
      #
      # Because we always start from the full account peer-set in id order
      # (never from @peer), the outcome is the same no matter which peer
      # triggered the compile. Among a colliding group the lowest-id peer
      # keeps salt 0; the rest deterministically take the next free salt.
      def compute_assignment
        claimed = {}
        result = {}

        # Pass 1 — overrides are fixed points.
        account_peers.each do |peer|
          override = peer.bgp_router_id_override
          claimed[override] = true if override.present?
        end

        # Pass 2 — derive + perturb override-less peers in id order.
        account_peers.each do |peer|
          next if peer.bgp_router_id_override.present?

          router_id = nil
          (0..MAX_SALT).each do |salt|
            candidate = derive_from_overlay(peer: peer, salt: salt)
            next if claimed[candidate]

            router_id = candidate
            break
          end

          if router_id.nil?
            raise CollisionDetected,
                  "unable to derive a unique BGP router-id for peer #{peer.id} " \
                  "(account #{@peer.account_id}) within #{MAX_SALT + 1} salts"
          end

          claimed[router_id] = true
          result[peer.id] = router_id
        end

        result
      end

      # Load the full account peer-set in ONE query, ordered by id (stable,
      # deterministic — ids are time-ordered UUIDv7). Only the three columns
      # the assignment needs are selected. Memoized on the instance.
      #
      # NOTE: a cross-resolve (per-compile) cache would cut this to one query
      # per account per compile, but that needs config_compiler plumbing and
      # is out of scope here. One-query-per-resolve is always fresh (no
      # staleness) and acceptable.
      def account_peers
        @account_peers ||= ::Sdwan::Peer
                             .where(account_id: @peer.account_id)
                             .order(:id)
                             .select(:id, :assigned_address, :bgp_router_id_override)
                             .to_a
      end

      # Decision D11 (2): when the account's strategy is "explicit" but this
      # peer carries no override, warn and fall back to the derived id rather
      # than failing the compile. Only reached after the override early-return
      # (so override-bearing peers never warn). Default strategy → silent.
      def warn_if_explicit_strategy_without_override(router_id)
        account_bgp = ::Sdwan::AccountBgp.find_by(account_id: @peer.account_id)
        return unless account_bgp&.router_id_strategy == "explicit"

        Rails.logger.warn(
          "[Sdwan::Bgp::RouterIdResolver] peer #{@peer.id} (account #{@peer.account_id}) " \
          "router_id_strategy=explicit but has no bgp_router_id_override; " \
          "falling back to derived router-id #{router_id}"
        )
      end
    end
  end
end
