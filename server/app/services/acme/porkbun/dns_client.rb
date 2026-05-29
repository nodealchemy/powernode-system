# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Acme
  module Porkbun
    # Porkbun DNS adapter. Conforms to the Acme::DnsClient contract so the
    # records controller doesn't branch on provider.
    #
    # Porkbun quirks:
    #   - No header auth. EVERY request is a POST whose JSON body carries
    #     {"apikey": ..., "secretapikey": ...} — so this client takes two
    #     credential fields (api_key + secret_api_key), not a single token.
    #   - "Zones" are domains; the id IS the domain name (no opaque uuid),
    #     so we use the name as zone_id everywhere (like DigitalOcean).
    #   - Records use integer ids returned as strings; we keep them as
    #     strings at the contract boundary.
    #   - Porkbun's record "name" is the *subdomain* (relative), and the
    #     API returns the FQDN. We relativize on write and expose the FQDN
    #     on read, matching the other adapters' contract.
    #   - No "proxied" concept (raw DNS provider) — flag is ignored.
    #   - Error envelope is {"status":"ERROR","message":...}; success is
    #     {"status":"SUCCESS", ...}.
    #
    # Plan reference: E (multi-provider DNS adapters).
    class DnsClient
      BASE_URL = "https://porkbun.com/api/json/v3"
      DEFAULT_TIMEOUT = 10
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA ALIAS TLSA].freeze

      Result = ::Acme::Cloudflare::DnsClient::Result

      class ApiError < ::Acme::Cloudflare::DnsClient::ApiError; end

      # Accepts either:
      #   new(api_key: "pk...", secret_api_key: "sk...")
      #   new(credentials: { "api_key" => "pk...", "secret_api_key" => "sk..." })
      #   new({ "api_key" => "pk...", "secret_api_key" => "sk..." })  # positional hash
      #   new(api_token: <json-blob>)                                 # factory passthrough
      #
      # Porkbun needs two fields (api_key + secret_api_key), not a lone
      # token. The factory (Acme::DnsClient.for) always passes api_token:;
      # mirroring the OVH adapter, when that carries a JSON object of the
      # two fields we decode it so this client slots into the existing
      # factory without a bespoke construction path. Explicit keyword
      # fields take precedence over anything in the blob. Both string and
      # symbol credential keys are honored.
      def initialize(positional_credentials = nil, api_key: nil, secret_api_key: nil,
                     credentials: nil, api_token: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        creds = extract_credentials(credentials || positional_credentials, api_token)
        @api_key        = (api_key || creds["api_key"]).to_s
        @secret_api_key = (secret_api_key || creds["secret_api_key"]).to_s
        raise ArgumentError, "api_key is required" if @api_key.strip.empty?
        raise ArgumentError, "secret_api_key is required" if @secret_api_key.strip.empty?
        @timeout = timeout
        @logger = logger || ::Rails.logger
      end

      # ── Zones ────────────────────────────────────────────────────────

      # POST /domain/listAll — Porkbun returns {"domains":[{"domain": "...", ...}]}.
      # The domain name is the id. Porkbun has no server-side name filter,
      # so we client-filter to match the contract.
      def list_zones(name: nil, per_page: 50, page: 1)
        # Porkbun paginates listAll via a "start" offset (string).
        start = ((page.to_i - 1) * per_page.to_i)
        result = post("/domain/listAll", body: { start: start.to_s })
        return result unless result.ok?

        zones = Array(result.data["domains"]).map { |d| normalize_zone(d) }
        zones = zones.select { |z| z[:name] == name } if name.present?
        Result.new(ok: true, data: zones, http_status: result.http_status)
      end

      # Porkbun has no single-domain fetch; derive the zone from listAll.
      def get_zone(zone_id)
        result = list_zones
        return result unless result.ok?

        zone = Array(result.data).find { |z| z[:name] == zone_id.to_s }
        unless zone
          return Result.new(ok: false, error: "Zone #{zone_id.inspect} not found", http_status: 404)
        end
        Result.new(ok: true, data: zone, http_status: result.http_status)
      end

      # ── DNS Records ──────────────────────────────────────────────────

      # POST /dns/retrieve/:domain — records live under "records".
      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        _ = per_page
        _ = page
        result = post("/dns/retrieve/#{escape(zone_id)}", body: {})
        return result unless result.ok?

        recs = Array(result.data["records"]).map { |r| normalize_record(r, zone_id) }
        recs = recs.select { |r| r[:type] == type.to_s.upcase } if type.present?
        recs = recs.select { |r| r[:name] == name || r[:name] == "#{name}.#{zone_id}" } if name.present?
        Result.new(ok: true, data: recs, http_status: result.http_status)
      end

      # POST /dns/retrieve/:domain/:id — single record (also nested under "records").
      def get_record(zone_id, record_id)
        result = post("/dns/retrieve/#{escape(zone_id)}/#{escape(record_id)}", body: {})
        return result unless result.ok?

        rec = Array(result.data["records"]).first
        unless rec
          return Result.new(ok: false, error: "Record #{record_id.inspect} not found", http_status: 404)
        end
        Result.new(ok: true, data: normalize_record(rec, zone_id), http_status: result.http_status)
      end

      # POST /dns/create/:domain — body: { name (subdomain only), type, content, ttl }.
      # Porkbun returns {"status":"SUCCESS","id":<int>} on create.
      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        _ = proxied
        body = {
          name: relativize_name(name.to_s, zone_id),
          type: type.to_s.upcase,
          content: content.to_s,
          ttl: normalize_ttl(ttl)
        }
        body[:prio] = extras[:priority].to_i if extras[:priority]

        result = post("/dns/create/#{escape(zone_id)}", body: body)
        return result unless result.ok?

        # Create only returns the new id; re-read for a normalized record.
        new_id = result.data["id"]
        return get_record(zone_id, new_id) if new_id

        Result.new(ok: true, data: { id: nil, zone_id: zone_id.to_s }, http_status: result.http_status)
      end

      # POST /dns/edit/:domain/:id — Porkbun requires the full record body
      # (name, type, content, ttl). Re-fetch any field the caller omitted.
      def update_record(zone_id, record_id, attrs)
        if attrs[:type].present?
          validate_record_type!(attrs[:type])
        end

        body = {}
        body[:name]    = relativize_name(attrs[:name].to_s, zone_id) if attrs[:name].present?
        body[:type]    = attrs[:type].to_s.upcase if attrs[:type].present?
        body[:content] = attrs[:content].to_s if attrs[:content].present?
        body[:ttl]     = normalize_ttl(attrs[:ttl]) if attrs[:ttl].present?
        body[:prio]    = attrs[:priority].to_i if attrs[:priority].present?

        if body[:type].blank? || body[:content].blank?
          existing = get_record(zone_id, record_id)
          return existing unless existing.ok?
          body[:name]    = relativize_name(existing.data[:name].to_s, zone_id) if body[:name].nil?
          body[:type]    ||= existing.data[:type]
          body[:content] ||= existing.data[:content]
          body[:ttl]     ||= existing.data[:ttl]
        end

        result = post("/dns/edit/#{escape(zone_id)}/#{escape(record_id)}", body: body)
        return result unless result.ok?
        get_record(zone_id, record_id)
      end

      # POST /dns/delete/:domain/:id
      def delete_record(zone_id, record_id)
        result = post("/dns/delete/#{escape(zone_id)}/#{escape(record_id)}", body: {})
        return result unless result.ok?
        Result.new(ok: true, data: { deleted: true }, http_status: result.http_status)
      end

      private

      # Porkbun has no GET endpoints — everything is an authenticated POST.
      def post(path, body:)
        uri = URI("#{BASE_URL}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = auth_body(body).to_json
        request(req)
      end

      # Every request body carries the credentials — Porkbun's only auth.
      def auth_body(body)
        { apikey: @api_key, secretapikey: @secret_api_key }.merge(body || {})
      end

      def request(req)
        http = Net::HTTP.new(req.uri.host, req.uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        response = http.request(req)
        parse_response(response)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "Porkbun API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[Acme::Porkbun::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "Porkbun API error: #{e.message}")
      end

      # Porkbun envelope:
      #   success → {"status":"SUCCESS", ...}
      #   failure → {"status":"ERROR","message": "..."}  (often with HTTP 400)
      def parse_response(response)
        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)

        if response.is_a?(Net::HTTPSuccess) && parsed["status"] == "SUCCESS"
          Result.new(ok: true, data: parsed, http_status: response.code.to_i)
        else
          msg = parsed["message"] || "Porkbun API returned HTTP #{response.code}"
          Result.new(ok: false, error: msg, http_status: response.code.to_i,
                      cf_errors: [ { code: response.code, message: msg } ])
        end
      rescue JSON::ParserError
        Result.new(ok: false,
                    error: "Invalid JSON from Porkbun (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
                    http_status: response.code.to_i)
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      # Resolve the credentials hash from an explicit hash or the factory's
      # api_token: JSON blob, stringifying keys for indifferent lookup.
      def extract_credentials(credentials, api_token)
        source = credentials
        source ||= decode_blob(api_token)
        return {} unless source.respond_to?(:transform_keys)
        source.transform_keys(&:to_s)
      end

      # The factory only knows api_token:; accept a JSON-encoded blob there.
      def decode_blob(api_token)
        return nil if api_token.nil?
        return api_token if api_token.respond_to?(:transform_keys)

        str = api_token.to_s.strip
        return nil if str.empty?
        parsed = JSON.parse(str)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect} on Porkbun; allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end

      # Porkbun's default/min TTL is 600. The Cloudflare convention of
      # `1 = automatic` gets mapped to 600 (Porkbun's floor).
      def normalize_ttl(ttl)
        t = ttl.to_i
        return 600 if t <= 1
        [ t, 600 ].max
      end

      # Porkbun records take the *subdomain* (relative) name. If the caller
      # passes a FQDN, strip the zone suffix; an empty name or the bare
      # zone represents the apex (empty subdomain for Porkbun).
      def relativize_name(name, zone_id)
        zone = zone_id.to_s
        return "" if name.empty? || name == zone || name == "@"
        return name.sub(/\.#{Regexp.escape(zone)}\z/, "") if name.end_with?(".#{zone}")
        name
      end

      # Translate Porkbun's domain shape to the same envelope as the others.
      def normalize_zone(d)
        {
          id: d["domain"].to_s, # Porkbun uses the domain name as the id
          name: d["domain"].to_s,
          status: d["status"],
          tld: d["tld"],
          create_date: d["createDate"],
          expire_date: d["expireDate"]
        }.compact
      end

      # Translate Porkbun's record shape so callers see consistent fields.
      # Porkbun returns the FQDN in "name"; we pass it through (already the
      # contract's expected shape).
      def normalize_record(r, zone_id)
        {
          id: r["id"].to_s,
          zone_id: zone_id.to_s,
          zone_name: zone_id.to_s,
          type: r["type"],
          name: r["name"].to_s,
          content: r["content"],
          ttl: r["ttl"].to_i,
          priority: r["prio"],
          proxied: false, # Porkbun doesn't support proxied
          notes: r["notes"]
        }.compact
      end
    end
  end
end
