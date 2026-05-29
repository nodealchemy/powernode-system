# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "digest/sha1"

module Acme
  module Ovh
    # OVH DNS adapter. Conforms to the Acme::DnsClient contract so the
    # records controller doesn't branch on provider.
    #
    # OVH is unlike the token-based providers: every request is signed
    # with the operator's application credentials. There is no single
    # bearer token — instead each call carries:
    #
    #   X-Ovh-Application : application_key
    #   X-Ovh-Consumer    : consumer_key
    #   X-Ovh-Timestamp   : server time (seconds)
    #   X-Ovh-Signature   : "$1$" + SHA1(secret+consumer+METHOD+URL+BODY+TS)
    #
    # so this client takes the four-field credentials hash rather than a
    # lone api_token. It still accepts the `api_token:` keyword the
    # Acme::DnsClient factory always passes (treated as a JSON-encoded
    # credentials blob when present) so it slots into the existing
    # factory without a bespoke construction path.
    #
    # OVH quirks:
    #   - "Zones" are bare domain names — the id IS the name (like DO).
    #   - Listing records returns only record IDs; content requires a
    #     per-record GET. We hydrate each id so callers get the same
    #     shape Cloudflare returns from a single list call.
    #   - No "proxied" concept (raw DNS provider) — flag is ignored.
    #   - Mutations are staged; a POST /domain/zone/{zone}/refresh is
    #     required to apply them. We refresh after every create/update/
    #     delete so callers don't have to.
    #   - Record content lives in the `target` field; subdomain is the
    #     relative name (apex = empty string).
    #
    # Plan reference: E6 (OVH DNS adapter).
    class DnsClient < ::Acme::BaseDnsClient
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA PTR].freeze

      # Named OVH API endpoints → base URL. A full URL is accepted as-is.
      ENDPOINTS = {
        "ovh-eu" => "https://eu.api.ovh.com/1.0",
        "ovh-us" => "https://api.us.ovhcloud.com/1.0",
        "ovh-ca" => "https://ca.api.ovh.com/1.0"
      }.freeze

      class ApiError < ::Acme::BaseDnsClient::ApiError; end

      # Accepts either:
      #   new(application_key:, application_secret:, consumer_key:, endpoint:)
      #   new(credentials_hash)                        # positional hash
      #   new(api_token: <json-blob>)                  # factory passthrough
      #
      # The factory (Acme::DnsClient.for) always passes api_token:; when
      # that carries a JSON object of the four fields we decode it.
      # Explicit keyword fields take precedence over anything in the blob.
      def initialize(credentials = nil, application_key: nil, application_secret: nil,
                     consumer_key: nil, endpoint: nil, api_token: nil,
                     timeout: DEFAULT_TIMEOUT, logger: nil)
        creds = extract_credentials(credentials, api_token)

        @application_key    = (application_key    || creds["application_key"]).to_s
        @application_secret = (application_secret || creds["application_secret"]).to_s
        @consumer_key       = (consumer_key       || creds["consumer_key"]).to_s
        endpoint_value      = (endpoint           || creds["endpoint"]).to_s

        %w[application_key application_secret consumer_key].each do |field|
          value = instance_variable_get("@#{field}")
          raise ArgumentError, "#{field} is required" if value.strip.empty?
        end
        raise ArgumentError, "endpoint is required" if endpoint_value.strip.empty?

        @base_url = resolve_base(endpoint_value)
        @timeout  = timeout
        @logger   = logger || ::Rails.logger
        @time_drift = nil
      end

      def list_zones(name: nil, per_page: 50, page: 1)
        _ = [ per_page, page ] # OVH returns the full list; no server-side paging
        result = get("/domain/zone")
        return result unless result.ok?

        zones = Array(result.data).map { |z| normalize_zone(z) }
        zones = zones.select { |z| z[:name] == name } if name.present?
        Result.new(ok: true, data: zones, http_status: result.http_status)
      end

      def get_zone(zone_id)
        # OVH zones are addressed by their domain name. Confirm the zone
        # exists via its SOA endpoint so a bad id surfaces as 404.
        result = get("/domain/zone/#{escape(zone_id)}/soa")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_zone(zone_id), http_status: result.http_status)
      end

      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        _ = [ per_page, page ]
        params = {}
        params[:fieldType] = type.to_s.upcase if type.present?
        # OVH filters by relative subDomain, not FQDN.
        params[:subDomain] = relativize_name(name.to_s, zone_id) if name.present?

        result = get("/domain/zone/#{escape(zone_id)}/record", params: params)
        return result unless result.ok?

        # The list endpoint returns only record IDs; hydrate each one so
        # callers get full content in a single call (matches Cloudflare).
        ids = Array(result.data)
        records = []
        ids.each do |id|
          rec = get("/domain/zone/#{escape(zone_id)}/record/#{escape(id)}")
          return rec unless rec.ok?
          records << normalize_record(rec.data, zone_id)
        end
        Result.new(ok: true, data: records, http_status: result.http_status)
      end

      def get_record(zone_id, record_id)
        result = get("/domain/zone/#{escape(zone_id)}/record/#{escape(record_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data, zone_id), http_status: result.http_status)
      end

      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        _ = [ proxied, extras ] # OVH has no proxied/priority-as-field concept here
        body = {
          fieldType: type.to_s.upcase,
          subDomain: relativize_name(name.to_s, zone_id),
          target: content.to_s,
          ttl: normalize_ttl(ttl)
        }

        result = post("/domain/zone/#{escape(zone_id)}/record", body: body)
        return result unless result.ok?

        refreshed = refresh_zone(zone_id)
        return refreshed unless refreshed.ok?

        Result.new(ok: true, data: normalize_record(result.data, zone_id), http_status: result.http_status)
      end

      def update_record(zone_id, record_id, attrs)
        validate_record_type!(attrs[:type]) if attrs[:type].present?
        payload = {}
        # OVH's record PUT only accepts subDomain, target, ttl — fieldType
        # is immutable, so a type change is silently unsupported (matches
        # the contract: only supplied fields change).
        payload[:subDomain] = relativize_name(attrs[:name].to_s, zone_id) if attrs[:name].present?
        payload[:target]    = attrs[:content].to_s if attrs[:content].present?
        payload[:ttl]       = normalize_ttl(attrs[:ttl]) if attrs[:ttl].present?

        result = put("/domain/zone/#{escape(zone_id)}/record/#{escape(record_id)}", body: payload)
        return result unless result.ok?

        refreshed = refresh_zone(zone_id)
        return refreshed unless refreshed.ok?

        # PUT returns 200 with no body; re-fetch so callers get the
        # updated record in the standard shape.
        get_record(zone_id, record_id)
      end

      def delete_record(zone_id, record_id)
        result = delete("/domain/zone/#{escape(zone_id)}/record/#{escape(record_id)}")
        return result unless result.ok?

        refreshed = refresh_zone(zone_id)
        return refreshed unless refreshed.ok?

        Result.new(ok: true, data: { deleted: true }, http_status: result.http_status)
      end

      private

      # POST /domain/zone/{zone}/refresh — applies staged record changes.
      def refresh_zone(zone_id)
        post("/domain/zone/#{escape(zone_id)}/refresh", body: nil)
      end

      def get(path, params: {})
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        request(Net::HTTP::Get.new(uri), uri)
      end

      def post(path, body:)
        uri = URI("#{@base_url}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.nil? ? "" : body.to_json
        request(req, uri)
      end

      def put(path, body:)
        uri = URI("#{@base_url}#{path}")
        req = Net::HTTP::Put.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.nil? ? "" : body.to_json
        request(req, uri)
      end

      def delete(path)
        uri = URI("#{@base_url}#{path}")
        result = request(Net::HTTP::Delete.new(uri), uri)
        if result.http_status&.between?(200, 204)
          Result.new(ok: true, data: { deleted: true }, http_status: result.http_status)
        else
          result
        end
      end

      def request(req, uri)
        full_url = uri.to_s
        body = req.body.to_s
        timestamp = ovh_timestamp(uri)

        req["X-Ovh-Application"] = @application_key
        req["X-Ovh-Consumer"]    = @consumer_key
        req["X-Ovh-Timestamp"]   = timestamp.to_s
        req["X-Ovh-Signature"]   = sign(req.method, full_url, body, timestamp)
        req["Content-Type"]    ||= "application/json"
        req["Accept"] = "application/json"

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        response = http.request(req)
        parse_response(response)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "OVH API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[#{log_tag}] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "OVH API error: #{e.message}")
      end

      # X-Ovh-Signature = "$1$" + SHA1(
      #   application_secret + "+" + consumer_key + "+" + METHOD + "+" +
      #   FULL_URL + "+" + BODY + "+" + TIMESTAMP
      # )
      def sign(method, full_url, body, timestamp)
        digest = Digest::SHA1.hexdigest(
          [ @application_secret, @consumer_key, method.to_s.upcase, full_url, body, timestamp ].join("+")
        )
        "$1$#{digest}"
      end

      # OVH validates the timestamp against its own clock (±~30s). We
      # fetch the server time once and cache the drift relative to the
      # local clock so subsequent requests stay aligned without an extra
      # round-trip each time.
      #
      # A *successful* probe caches the drift (even a legitimate 0-second
      # drift — `0` is a real, cacheable value). A *failed* probe leaves
      # @time_drift nil and falls back to local time for THIS request only,
      # so the next call re-attempts the sync rather than permanently
      # pinning to a possibly-skewed local clock.
      def ovh_timestamp(current_uri)
        return Time.now.to_i + @time_drift unless @time_drift.nil?

        # Avoid infinite recursion: the /auth/time probe is unsigned and
        # must not re-enter the signed request path.
        time_uri = URI("#{@base_url}/auth/time")
        return Time.now.to_i if same_path?(current_uri, time_uri)

        http = Net::HTTP.new(time_uri.host, time_uri.port)
        http.use_ssl = (time_uri.scheme == "https")
        http.read_timeout = @timeout
        http.open_timeout = @timeout
        response = http.request(Net::HTTP::Get.new(time_uri))

        if response.is_a?(Net::HTTPSuccess)
          server_time = response.body.to_s.strip.to_i
          @time_drift = server_time - Time.now.to_i
          server_time
        else
          # Probe failed: do NOT pin @time_drift — retry on the next call.
          Time.now.to_i
        end
      rescue StandardError => e
        @logger&.warn("[#{log_tag}] time sync failed: #{e.message}")
        # Transport failure: leave @time_drift nil so we re-sync later.
        Time.now.to_i
      end

      def same_path?(a, b)
        a.host == b.host && a.path == b.path
      end

      # OVH errors: { "message": "...", "class": "..." }
      def extract_error(parsed, response)
        msg = (parsed.is_a?(Hash) && (parsed["message"] || parsed["error"])) ||
              "OVH API returned HTTP #{response.code}"
        err_class = parsed.is_a?(Hash) ? parsed["class"] : nil
        [ msg, [ { code: err_class || response.code, message: msg } ] ]
      end

      # Error/log strings spell the provider "OVH", not the "Ovh" the
      # class-name default would produce.
      def provider_label
        "OVH"
      end

      def base_url
        @base_url
      end

      def resolve_base(endpoint)
        value = endpoint.to_s.strip
        return ENDPOINTS[value] if ENDPOINTS.key?(value)
        return value.chomp("/") if value.start_with?("http://", "https://")
        raise ArgumentError,
              "Unknown OVH endpoint #{endpoint.inspect}; expected one of #{ENDPOINTS.keys.inspect} or a full URL"
      end

      # OVH TTL minimum is 60; the Cloudflare "auto"=1 sentinel maps to a
      # sane default of 3600.
      def normalize_ttl(ttl)
        t = ttl.to_i
        return 3600 if t <= 1
        [ t, 60 ].max
      end

      # OVH list_zones returns bare domain strings; id == name (like DO).
      def normalize_zone(zone_name)
        {
          id: zone_name.to_s,
          name: zone_name.to_s,
          status: "active"
        }.compact
      end

      # OVH record shape:
      #   { id:, zone:, fieldType:, subDomain:, target:, ttl: }
      def normalize_record(r, zone_id)
        rel = r["subDomain"].to_s
        fqdn = rel.empty? ? zone_id.to_s : "#{rel}.#{zone_id}"
        {
          id: r["id"].to_s,
          zone_id: zone_id.to_s,
          zone_name: zone_id.to_s,
          type: r["fieldType"],
          name: fqdn,
          content: r["target"],
          ttl: r["ttl"],
          proxied: false
        }.compact
      end
    end
  end
end
