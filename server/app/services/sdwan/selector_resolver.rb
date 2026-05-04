# frozen_string_literal: true

# Turns Sdwan::FirewallRule's JSONB selector primitives into nft match
# clauses. Four selector kinds (locked-in for v1):
#
#   { "peer_id": "<uuid>" }    → "ip6 saddr fdf8:.../128"
#   { "cidr": "fd...::/64" }   → "ip6 saddr fd...::/64"
#   { "tag": "<label>" }       → nil  (slice 5 will populate nft sets from tags)
#   { "all": true }            → nil  (no clause emitted = wildcard)
#
# Slice 2 SCOPE: tag-based selectors compile to nil (effective wildcard)
# until slice 5 wires the per-network nft set population. Operators using
# tags should expect rules to match anywhere until then; this matches
# Tailscale's "ACL groups before group population" pre-launch behavior.
#
# Side parameter (`:saddr` | `:daddr`) determines which nft direction
# clause we emit — saddr for src_selectors, daddr for dst_selectors.
#
# Slice 2 of the SDWAN plan.
module Sdwan
  class SelectorResolver
    SUPPORTED_KINDS = %w[peer_id tag cidr all].freeze

    # Returns the nft match fragment as a String, or nil if no clause is
    # required (wildcard match). Callers .compact-out the nils when joining
    # rule pieces.
    def self.to_nft_match(selector, side:)
      return nil if selector.blank?
      return nil unless selector.is_a?(Hash)

      raise ArgumentError, "side must be :saddr or :daddr" unless %i[saddr daddr].include?(side)

      return nil if selector["all"] || selector[:all]

      if (peer_id = selector["peer_id"] || selector[:peer_id])
        peer = ::Sdwan::Peer.find_by(id: peer_id)
        return nil unless peer

        return "ip6 #{side} #{peer.assigned_address}"
      end

      if (cidr = selector["cidr"] || selector[:cidr])
        return "ip6 #{side} #{cidr}"
      end

      if selector["tag"] || selector[:tag]
        # Slice 2: tag-based matching is a no-op (wildcard). Slice 5 will
        # populate nft sets per tag. Returning nil keeps the rule loose
        # until then — operators should treat tag-based rules as
        # "deferred" and not rely on them for security boundaries yet.
        return nil
      end

      nil
    end
  end
end
