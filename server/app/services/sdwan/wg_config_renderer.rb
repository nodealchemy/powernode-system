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
    DEFAULT_PERSISTENT_KEEPALIVE = 25

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
                      # NOTE: the render loop below dereferences primary_endpoint without a nil guard — it depends on this filter.
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

      @hubs.each do |hub|
        key = hub.active_key
        next unless key

        primary = hub.primary_endpoint
        fallback = hub.fallback_endpoint
        out.puts "[Peer]"
        out.puts "# Hub: #{hub_label(hub)} (#{primary[:family]} primary)"
        # IMP-651ec6336654: WireGuard requires PublicKey in every [Peer]
        # section — clients reject the config without it. This is the hub's
        # PUBLIC key (column-stored, non-secret); the private half never
        # leaves Vault.
        out.puts "PublicKey  = #{key.public_key}"
        # Slice 7a: when both v6 and v4 endpoints are configured, the v6
        # one is the canonical Endpoint; the v4 alternative is documented
        # in a comment so operators (or a smart WG client) can swap to
        # it manually if v6 reachability breaks. Stock WG itself only
        # reads one Endpoint line; the comment is operator-facing.
        out.puts "Endpoint   = #{Peer.format_host_port(primary[:host], primary[:port])}"
        out.puts "# Fallback (IPv4): #{fallback[:host]}:#{fallback[:port]}" if fallback
        out.puts "AllowedIPs = #{allowed_ips.join(', ')}"
        out.puts "PersistentKeepalive = #{DEFAULT_PERSISTENT_KEEPALIVE}"
        out.puts ""
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
