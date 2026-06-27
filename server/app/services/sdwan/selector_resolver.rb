# frozen_string_literal: true

# Turns Sdwan::FirewallRule's JSONB selector primitives into nft match
# clauses. Four selector kinds (locked-in for v1):
#
#   { "peer_id": "<uuid>" }    → "ip6 saddr fdf8:.../128"
#   { "cidr": "fd...::/64" }   → "ip6 saddr fd...::/64"
#   { "tag": "<label>" }       → "ip6 saddr { <addrs of tagged peers> }"
#   { "all": true }            → nil  (no clause emitted = wildcard)
#
# FAIL-CLOSED contract (security boundary): a selector that is meant to
# RESTRICT but resolves to the empty set (a tag with no members, or a
# peer_id pointing at a deleted peer) returns the MATCH_NOTHING sentinel —
# NOT nil. nil means "no constraint (wildcard)"; MATCH_NOTHING means "this
# rule can never match". The compiler drops any rule whose selector is
# MATCH_NOTHING, so a restrict-rule whose target set is empty grants nothing
# instead of silently matching every peer (the previous fail-OPEN behavior).
#
# Tag resolution is forward-compatible: it filters the network's peers by a
# `tags` attribute when that column exists, and otherwise resolves to the
# empty set (→ MATCH_NOTHING). Wiring the peer-tag write path (column +
# controller/MCP) activates real tag matching with no change here.
#
# Side parameter (`:saddr` | `:daddr`) determines which nft direction
# clause we emit — saddr for src_selectors, daddr for dst_selectors.
module Sdwan
  class SelectorResolver
    SUPPORTED_KINDS = %w[peer_id tag cidr all].freeze

    # Sentinel: the selector is a restriction that resolves to the empty set,
    # so the rule must match nothing (fail-closed). Distinct from nil.
    MATCH_NOTHING = :__match_nothing__

    # Returns the nft match fragment as a String, MATCH_NOTHING when the
    # selector restricts to the empty set, or nil when no clause is required
    # (wildcard). Callers must treat MATCH_NOTHING as "drop the rule" and
    # .compact-out the nils when joining rule pieces.
    #
    # @param network [Sdwan::Network, nil] scopes tag resolution to this network
    def self.to_nft_match(selector, side:, network: nil)
      return nil if selector.blank?
      return nil unless selector.is_a?(Hash)

      raise ArgumentError, "side must be :saddr or :daddr" unless %i[saddr daddr].include?(side)

      return nil if selector["all"] || selector[:all]

      if (peer_id = selector["peer_id"] || selector[:peer_id])
        peer = ::Sdwan::Peer.find_by(id: peer_id)
        # Deleted/unknown peer: fail closed, NOT wildcard.
        return MATCH_NOTHING unless peer

        return "ip6 #{side} #{peer.assigned_address}"
      end

      if (cidr = selector["cidr"] || selector[:cidr])
        return "ip6 #{side} #{cidr}"
      end

      if (tag = selector["tag"] || selector[:tag])
        addresses = addresses_for_tag(tag, network: network)
        # A tag that matches no peers is a restriction to the empty set →
        # fail closed rather than emitting a wildcard rule.
        return MATCH_NOTHING if addresses.empty?

        return "ip6 #{side} { #{addresses.join(', ')} }"
      end

      nil
    end

    # Resolves a tag label to the assigned /128 addresses of the peers that
    # carry it, scoped to the network when given. Forward-compatible: returns
    # [] until the peer-tag column exists.
    def self.addresses_for_tag(tag, network: nil)
      tagged_peers(tag, network: network).map(&:assigned_address).compact.uniq
    end

    def self.tagged_peers(tag, network: nil)
      return [] unless ::Sdwan::Peer.column_names.include?("tags")

      scope = network ? ::Sdwan::Peer.where(sdwan_network_id: network.id) : ::Sdwan::Peer.all
      scope.with_tag(tag).to_a
    end
  end
end
