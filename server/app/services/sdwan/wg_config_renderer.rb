# frozen_string_literal: true

# Renders the WireGuard config text the user pastes into their WG client
# (iOS / macOS / Linux / Windows / Android). Each network's hub peers
# become [Peer] sections — the WG client picks the first responsive one.
#
# Spokes-only networks (no public hub) cannot serve user VPN clients.
# The renderer surfaces this case with an explicit comment so operators
# understand why connection attempts will fail.
#
# Slice 4 of the SDWAN plan.
require "stringio"

module Sdwan
  class WgConfigRenderer
    DEFAULT_PERSISTENT_KEEPALIVE = ::Sdwan::PeerEntry::DEFAULT_PERSISTENT_KEEPALIVE

    def self.render(device)
      new(device).render
    end

    def initialize(device)
      @device  = device
      @network = device.network
      # Slice 7a: hubs may have v6, v4, or legacy endpoint columns. Filter
      # by primary_endpoint presence in Ruby (can't push down to SQL across
      # the three-column read precedence). Hub count is small; cost is OK.
      @hubs = @network.peers
                      .where(publicly_reachable: true)
                      .includes(:keys)
                      .to_a
                      # LOAD-BEARING, and not merely cosmetic. Sdwan::PeerEntry.build
                      # is nil-safe now, so dropping this filter no longer crashes —
                      # it renders an endpoint-less second [Peer] carrying the SAME
                      # AllowedIPs as the real hub, and WireGuard cryptokey routing
                      # requires AllowedIPs disjoint across peers (the kernel assigns
                      # an overlapping prefix to whichever peer was configured last).
                      # An undialable hub is also nothing a client could reach. Keep it.
                      .select(&:primary_endpoint)
    end

    def render
      private_key = @device.private_key_b64
      out = StringIO.new

      out.puts "# Powernode SDWAN — generated #{Time.current.utc.iso8601}"
      out.puts "# Network: #{@network.name} (#{@network.slug})"
      out.puts "# Device:  #{@device.label}"
      out.puts "# CIDR:    #{@network.cidr_64}"
      out.puts ""
      out.puts "[Interface]"
      out.puts "PrivateKey = #{private_key || '<vault-unavailable: re-issue device to recover>'}"
      out.puts "Address    = #{@device.assigned_address}"
      out.puts ""

      if @hubs.empty?
        out.puts "# WARNING: this network has no publicly-reachable hub. Add a hub peer"
        out.puts "# (publicly_reachable: true with endpoint_host + endpoint_port) so this"
        out.puts "# user device can connect. The config below is otherwise complete."
        out.puts ""
      end

      # IMP-3b49cd166b8c: a hub can pass the @hubs filter (publicly_reachable +
      # primary_endpoint) and still have no active key — revoked mid-rotation,
      # or a genesis key not yet generated. The render loop below has to skip
      # such a hub (no PublicKey to emit), but skipping it silently produced a
      # config with zero [Peer] sections and no explanation. Compute each hub's
      # active_key ONCE here (memoized per hub) and reuse it in the loop below —
      # calling active_key again would re-walk the preloaded `keys` collection
      # needlessly, and Peer#active_key's own comment is explicit that it uses
      # keys.find (not keys.where) specifically so includes(:keys) is not
      # defeated by a second call site.
      hub_keys = @hubs.map { |hub| [ hub, hub.active_key ] }
      keyless_hubs = hub_keys.select { |(_hub, key)| key.nil? }.map(&:first)
      keyed_present = hub_keys.any? { |(_hub, key)| key }

      if keyless_hubs.any?
        names = keyless_hubs.map { |hub| hub_label(hub) }.join(", ")
        plural = keyless_hubs.size > 1
        if keyed_present
          # Degraded-redundancy notice: at least one hub still renders a usable
          # [Peer] section below, so the config connects — just with fewer
          # paths than the network's hub count implies.
          out.puts "# WARNING: #{plural ? 'hubs' : 'hub'} #{names} #{plural ? 'have' : 'has'} no active key"
          out.puts "# and #{plural ? 'were' : 'was'} excluded from this config. Other hub(s) below are"
          out.puts "# still usable, but redundancy is degraded until #{plural ? 'they are' : 'it is'} re-keyed."
          out.puts ""
        else
          # Total-failure notice: every hub that made it past the reachability
          # filter is keyless, so the loop below emits zero peer sections —
          # this config genuinely cannot connect. (Wording deliberately avoids
          # the literal "[Peer]" token — that string is also the section
          # delimiter callers split on, and using it here would fabricate a
          # phantom section out of preamble text.)
          out.puts "# WARNING: every publicly-reachable hub (#{names}) has no active key."
          out.puts "# This config has no usable peer and cannot connect until at least"
          out.puts "# one hub is re-keyed."
          out.puts ""
        end
      end

      # IMP-915b24d21f4f: the [Peer] field set is Sdwan::PeerEntry's, not this
      # renderer's. It used to be hand-built here, which is the only reason
      # IMP-651ec6336654 was possible — WireGuard requires PublicKey in every
      # section, build_peer_entry always carried it, and this loop did not.
      # AllowedIPs stays OURS (a user device's routable surface is not a node
      # spoke's) and is handed to the builder as an argument.
      hub_keys.each do |hub, key|
        next unless key

        entry = ::Sdwan::PeerEntry.build(peer: hub, key: key, allowed_ips: allowed_ips,
                                         keepalive: DEFAULT_PERSISTENT_KEEPALIVE)
        out.print ::Sdwan::PeerEntry.to_ini(entry, hub_label: hub_label(hub))
      end

      out.string
    end

    private

    # WHAT THIS CLIENT MAY ROUTE INTO THE TUNNEL (IMP-94f3ec671b15).
    #
    # AllowedIPs is a CRYPTOGRAPHIC ROUTING FILTER, not a label: a prefix absent
    # here is one the client OS never sends into the tunnel (and never accepts
    # out of it), however correct the rest of the config. This line used to be
    # the network's /64 alone, so a user device handshook fine and then silently
    # failed to reach any VirtualIp, any advertised lan_subnet, or any federated
    # prefix — while HubAndSpoke#spoke_view folds those same classes into a node
    # spoke's AllowedIPs for exactly this reason ("or the packets are dropped
    # before they reach the tunnel", its words).
    #
    # ENTITLEMENT, checked before widening: Sdwan::AccessGrant is "a user's
    # entitlement to attach VPN clients to ONE SDWAN network" and its `tags`
    # column scopes nothing (SelectorResolver resolves PEER tags; no service
    # reads grant tags). The grant's scope IS the network, and every prefix
    # below belongs to THIS network — so this widens the filter to the grant's
    # existing surface and no further. An over-wide AllowedIPs would be a
    # security regression, which is why the VIP window and the per-network
    # scoping below are asserted by their own examples.
    #
    # TWO DELIBERATE DIVERGENCES from spoke_view, both because a WG client is
    # not a spoke:
    #
    #   * POD CIDRs are excluded. spoke_view gates them on `peer.k3s_host?` — a
    #     user device is not a k3s node and has no business with pod IPs, so the
    #     same rule that includes them for a k3s spoke excludes them here.
    #   * static_subnet_routing? does NOT gate this list. That flag chooses how
    #     routes are DISTRIBUTED (statically via AllowedIPs, or dynamically via
    #     FRR/BGP), and a WireGuard client runs no routing daemon — it can only
    #     ever learn statically. spoke_view already applies exactly this
    #     reasoning to federation prefixes, which it folds in regardless of the
    #     flag for the same "the filter must permit it however the route is
    #     learned" argument.
    def allowed_ips
      @allowed_ips ||= ([ @network.cidr_64 ] + vip_cidrs + advertised_lan_subnets + federation_prefixes)
                       .map { |cidr| cidr.to_s.strip }
                       .reject(&:empty?)
                       .uniq
    end

    # Same window as HubAndSpoke#all_vip_cidrs — active/pending only. A VIP in
    # any other state is not reachable, and permitting it would widen the filter
    # past the live surface.
    def vip_cidrs
      return [] unless @network.respond_to?(:virtual_ips)

      @network.virtual_ips.where(state: %w[active pending]).pluck(:cidr)
    end

    # Same source as HubAndSpoke#other_peers_lan_subnets. "Other" is every peer
    # from a user device's point of view — it is not one of them.
    def advertised_lan_subnets
      @network.peers.flat_map { |peer| Array(peer.lan_subnets) }
    end

    # The resolver's own data-plane convenience, rather than a re-derivation:
    # `prefixes_for` exists to hand exactly this list to a folding caller,
    # de-duplicated and stable-ordered.
    def federation_prefixes
      return [] unless defined?(::Sdwan::FederationPrefixResolver)

      Array(::Sdwan::FederationPrefixResolver.prefixes_for(@network))
    end

    def hub_label(hub)
      hub.node_instance.name
    rescue StandardError
      hub.id.to_s.first(8)
    end
  end
end
