# frozen_string_literal: true

require "socket"
require "uri"

module Federation
  # Walks a FederationPeer's advertised endpoints in priority order
  # with fast-fail (200ms) connect probes, returning the first
  # reachable endpoint. The reverse of "let DNS pick a single host" —
  # peers explicitly advertise multiple paths (LAN / SDWAN / WAN) and
  # the prober chooses the best available at call time.
  #
  # Endpoint hash shape (FederationPeer.endpoints_jsonb):
  #   {
  #     "url":      "https://hub.lan:443",       # required
  #     "scope":    "lan" | "sdwan" | "wan",     # required
  #     "priority": 1,                           # smaller = preferred
  #     "cidr_hint": "192.168.1.0/24",           # optional — only probe
  #                                              #   if our local IP is in this range
  #     "last_verified_at": "2026-05-15T...",    # written by this prober
  #     "last_failure_at":  "2026-05-15T...",    # written by this prober
  #     "status":           "reachable" | "unreachable"
  #   }
  #
  # Plan reference: Decentralized Federation §J + Locked Decision #11 + P2.5.6.
  class EndpointProber
    Result = Struct.new(:ok?, :endpoint, :probed, :all_failed?, :error,
                        keyword_init: true)

    DEFAULT_TIMEOUT_MS = 200
    MAX_PROBES = 10  # safety cap — peers shouldn't advertise more than this

    class << self
      def probe!(peer:, scope_filter: nil, timeout_ms: DEFAULT_TIMEOUT_MS)
        new(peer: peer, scope_filter: scope_filter, timeout_ms: timeout_ms).probe!
      end
    end

    def initialize(peer:, scope_filter:, timeout_ms:)
      @peer = peer
      @scope_filter = scope_filter # nil = all scopes; or array like %w[lan sdwan]
      @timeout_ms = timeout_ms
    end

    def probe!
      endpoints = filter_and_sort(Array(@peer.endpoints))
      return Result.new(ok?: false, all_failed?: true, error: "no advertised endpoints", probed: []) if endpoints.empty?

      probed = []
      endpoints.first(MAX_PROBES).each do |endpoint|
        attempt = probe_one(endpoint)
        probed << attempt

        if attempt[:reachable]
          record_outcome!(endpoint, success: true)
          return Result.new(ok?: true, endpoint: endpoint, probed: probed, all_failed?: false)
        else
          record_outcome!(endpoint, success: false, error: attempt[:error])
        end
      end

      Result.new(ok?: false, endpoint: nil, probed: probed,
                 all_failed?: true, error: "all #{probed.size} endpoints unreachable")
    end

    private

    def filter_and_sort(endpoints)
      scope_set = @scope_filter ? Set.new(Array(@scope_filter).map(&:to_s)) : nil
      endpoints
        .select { |e| e.is_a?(Hash) && e["url"].is_a?(String) }
        .select { |e| scope_set.nil? || scope_set.include?(e["scope"].to_s) }
        .sort_by { |e| e["priority"].to_i }
    end

    def probe_one(endpoint)
      url = endpoint["url"]
      uri = URI.parse(url)
      host = uri.host
      port = uri.port || (uri.scheme == "https" ? 443 : 80)

      start = Time.current
      timeout_secs = @timeout_ms / 1000.0

      sock = ::Socket.tcp(host, port, connect_timeout: timeout_secs)
      sock.close

      elapsed_ms = ((Time.current - start) * 1000).round
      { url: url, reachable: true, elapsed_ms: elapsed_ms }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::ETIMEDOUT, SocketError, URI::InvalidURIError, IOError => e
      { url: endpoint["url"], reachable: false, error: "#{e.class}: #{e.message}" }
    rescue StandardError => e
      # Catch-all for unexpected exceptions (e.g. provider-specific
      # Resolv timeouts). Same record-failure-and-move-on semantics.
      { url: endpoint["url"], reachable: false, error: "#{e.class}: #{e.message}" }
    end

    def record_outcome!(endpoint, success:, error: nil)
      idx = @peer.endpoints.index { |e| e["url"] == endpoint["url"] }
      return unless idx

      now_iso = Time.current.iso8601
      if success
        @peer.endpoints[idx]["last_verified_at"] = now_iso
        @peer.endpoints[idx]["status"] = "reachable"
        @peer.endpoints[idx].delete("last_failure_error")
      else
        @peer.endpoints[idx]["last_failure_at"] = now_iso
        @peer.endpoints[idx]["last_failure_error"] = error.to_s[0, 200]
        # status stays untouched on a single failure — a separate
        # observability layer can downgrade after N consecutive failures.
      end

      # endpoints is a jsonb column; AR's dirty-tracking sees the
      # array-mutation, but we must explicitly mark dirty + save.
      @peer.endpoints_will_change!
      @peer.save!
    end
  end
end
