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
        # Slice 7a: when both v6 and v4 endpoints are configured, the v6
        # one is the canonical Endpoint; the v4 alternative is documented
        # in a comment so operators (or a smart WG client) can swap to
        # it manually if v6 reachability breaks. Stock WG itself only
        # reads one Endpoint line; the comment is operator-facing.
        out.puts "Endpoint   = #{primary[:host]}:#{primary[:port]}"
        out.puts "# Fallback (IPv4): #{fallback[:host]}:#{fallback[:port]}" if fallback
        out.puts "AllowedIPs = #{@network.cidr_64}"
        out.puts "PersistentKeepalive = #{DEFAULT_PERSISTENT_KEEPALIVE}"
        out.puts ""
      end

      out.string
    end

    private

    def hub_label(hub)
      hub.node_instance.name
    rescue StandardError
      hub.id.to_s.first(8)
    end
  end
end
