# frozen_string_literal: true

# THE single WireGuard [Peer] field-set (IMP-915b24d21f4f).
#
# A [Peer] entry has two spellings in this codebase and they must never drift:
#
#   * the AGENT-FACING HASH that Sdwan::TopologyCompiler folds into `peers:`
#     and the Go agent writes verbatim into `wg setconf` (state.go →
#     wg_applier.go) — `build`;
#   * the OPERATOR-FACING INI TEXT that Sdwan::WgConfigRenderer hands a user to
#     paste into a WireGuard client — `to_ini`.
#
# Both spellings name the SAME fields, and until this class they were computed
# in three places: the renderer's inline loop and a `build_peer_entry` copied
# byte-for-byte between HubAndSpoke and FullMesh. The cost was realized twice —
# WireGuard's mandatory PublicKey line was absent from every rendered user
# config until IMP-651ec6336654 precisely because the renderer re-implemented
# what build_peer_entry always carried, and an AllowedIPs enrichment divergence
# between the renderer and HubAndSpoke#spoke_view is live today (offer
# 019ffee4-8a76-7196-9d00-1648f37d23f7).
#
# WHAT IS DELIBERATELY *NOT* HERE: the AllowedIPs list and the keepalive value.
# They stay CALLER-SUPPLIED. AllowedIPs is per-view routing policy — a hub's
# view of a spoke is that spoke's /128, a spoke's view of a hub is the whole
# /64 plus enrichment, a user device's is the grant's surface — so one builder
# cannot emit one AllowedIPs without picking a winner among three live
# behaviours. It emits the SHAPE and takes the policy as an argument; the
# renderer-vs-spoke_view divergence remains the business of its own offer.
# Likewise keepalive, which HubAndSpoke nils toward non-dialable peers.
#
# DATA-PLANE RULE: every byte below is applied to a real WireGuard interface.
# Changing what a given input renders is a data-plane change, and belongs in a
# task that says so.
module Sdwan
  module PeerEntry
    # WireGuard's own default for a NAT-keepalive tunnel. Each consumer keeps
    # its own DEFAULT_PERSISTENT_KEEPALIVE because *whether* to send one is a
    # per-view decision; this is only the shared value.
    DEFAULT_PERSISTENT_KEEPALIVE = 25

    # The canonical field set, in emission order. Pinned by peer_entry_spec so
    # a field cannot be added to one consumer alone — the whole reason this
    # class exists.
    FIELDS = %i[
      peer_id
      public_key
      endpoint
      endpoint_family
      fallback_endpoint
      allowed_ips
      persistent_keepalive
    ].freeze

    module_function

    # Slice 7a: a single-Endpoint entry (WireGuard's protocol accepts only one
    # Endpoint per [Peer]) plus a fallback_endpoint hint the agent uses when the
    # primary's reachability fails.
    def build(peer:, key:, allowed_ips:, keepalive:)
      primary  = peer.primary_endpoint
      fallback = peer.fallback_endpoint
      {
        peer_id: peer.id,
        public_key: key.public_key,
        # Consumed verbatim by the agent's `wg setconf` — HostPort.join
        # brackets IPv6 LITERALS only (a hostname may sit in the v6 column;
        # "[edge.example.net]:51820" is an address nobody can use).
        endpoint: primary && ::Sdwan::HostPort.join(primary[:host], primary[:port]),
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

    # Slice 4: a user-VPN client rides the overlay as an ordinary [Peer], but it
    # dials outbound — no endpoint to dial back on, and it runs its own
    # keepalive. `kind` is a hint for the agent + UI, and is the one field
    # outside FIELDS.
    def user_device(device)
      {
        peer_id: device.id,
        public_key: device.public_key,
        endpoint: nil,
        endpoint_family: nil,
        fallback_endpoint: nil,
        allowed_ips: [ device.assigned_address ],
        persistent_keepalive: nil,
        kind: "user_device"
      }
    end

    # The operator-facing spelling of the same entry: one WireGuard config
    # section, trailing blank line included. `hub_label` names the peer in a
    # comment above the section (omitted when nil).
    #
    # The column alignment ("PublicKey  = ", "Endpoint   = ") is the shape this
    # config has always had; it is what operators diff against.
    def to_ini(entry, hub_label: nil)
      out = +"[Peer]\n"
      out << "# Hub: #{hub_label} (#{entry[:endpoint_family]} primary)\n" if hub_label
      out << "PublicKey  = #{entry[:public_key]}\n"
      # A nil endpoint is the WG-valid "this peer dials me" case — an
      # "Endpoint   = " line with nothing after it is not config any client
      # accepts. WgConfigRenderer pre-filters its hubs on primary_endpoint, so
      # this arm is unreachable from there; it exists because to_ini is shared.
      out << "Endpoint   = #{entry[:endpoint]}\n" if entry[:endpoint]
      # Slice 7a: stock WireGuard reads one Endpoint, so the v4 alternative is
      # documented in a comment an operator (or a smart client) can swap to by
      # hand if v6 reachability breaks.
      if (fallback = entry[:fallback_endpoint])
        out << "# Fallback (IPv4): #{fallback[:host]}:#{fallback[:port]}\n"
      end
      out << "AllowedIPs = #{Array(entry[:allowed_ips]).join(', ')}\n"
      out << "PersistentKeepalive = #{entry[:persistent_keepalive]}\n" if entry[:persistent_keepalive]
      out << "\n"
    end
  end
end
