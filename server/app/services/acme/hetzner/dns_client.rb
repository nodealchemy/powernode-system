# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Acme
  module Hetzner
    # Hetzner DNS adapter. dns.hetzner.com/api/v1 — auth via the
    # `Auth-API-Token` header (NOT Bearer; intentionally distinct from
    # Hetzner Cloud's API which uses Bearer). Records live separately
    # from zones, queried via /records?zone_id=X.
    #
    # Hetzner quirks:
    #   - No "proxied" concept (raw DNS provider) — flag is ignored
    #   - TTL minimum is 60 (vs Cloudflare's 1)
    #   - Records and zones both have UUID ids
    #
    # Plan reference: E3.
    class DnsClient
      BASE_URL = "https://dns.hetzner.com/api/v1"
      DEFAULT_TIMEOUT = 10
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA PTR].freeze

      Result = ::Acme::Cloudflare::DnsClient::Result

      class ApiError < ::Acme::Cloudflare::DnsClient::ApiError; end

      def initialize(api_token:, timeout: DEFAULT_TIMEOUT, logger: nil)
        raise ArgumentError, "api_token is required" if api_token.to_s.strip.empty?
        @api_token = api_token
        @timeout = timeout
        @logger = logger || ::Rails.logger
      end

      def list_zones(name: nil, per_page: 50, page: 1)
        params = { per_page: per_page, page: page }
        params[:name] = name if name.present?
        result = get("/zones", params: params)
        return result unless result.ok?
        zones = Array(result.data["zones"]).map { |z| normalize_zone(z) }
        Result.new(ok: true, data: zones, http_status: result.http_status)
      end

      def get_zone(zone_id)
        result = get("/zones/#{escape(zone_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_zone(result.data["zone"]), http_status: result.http_status)
      end

      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        params = { zone_id: zone_id, per_page: per_page, page: page }
        result = get("/records", params: params)
        return result unless result.ok?
        recs = Array(result.data["records"]).map { |r| normalize_record(r) }
        recs = recs.select { |r| r[:type] == type.to_s.upcase } if type.present?
        recs = recs.select { |r| r[:name] == name } if name.present?
        Result.new(ok: true, data: recs, http_status: result.http_status)
      end

      def get_record(_zone_id, record_id)
        result = get("/records/#{escape(record_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["record"]), http_status: result.http_status)
      end

      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        _ = proxied
        body = {
          zone_id: zone_id,
          type: type.to_s.upcase,
          name: name.to_s,
          value: content.to_s,
          ttl: normalize_ttl(ttl)
        }
        body[:priority] = extras[:priority].to_i if extras[:priority]

        result = post("/records", body: body)
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["record"]), http_status: result.http_status)
      end

      def update_record(_zone_id, record_id, attrs)
        if attrs[:type].present?
          validate_record_type!(attrs[:type])
        end
        payload = {}
        payload[:zone_id]  = attrs[:zone_id] if attrs[:zone_id]
        payload[:type]     = attrs[:type].to_s.upcase if attrs[:type].present?
        payload[:name]     = attrs[:name] if attrs[:name].present?
        payload[:value]    = attrs[:content] if attrs[:content].present?
        payload[:ttl]      = normalize_ttl(attrs[:ttl]) if attrs[:ttl].present?
        payload[:priority] = attrs[:priority].to_i if attrs[:priority].present?

        # Hetzner requires the full record body on PUT, so re-fetch
        # missing fields if the caller did a partial update.
        if payload[:type].blank? || payload[:name].blank? || payload[:value].blank? || payload[:zone_id].blank?
          existing = get_record(nil, record_id)
          return existing unless existing.ok?
          payload[:type]    ||= existing.data[:type]
          payload[:name]    ||= existing.data[:name]
          payload[:value]   ||= existing.data[:content]
          payload[:zone_id] ||= existing.data[:zone_id]
          payload[:ttl]     ||= existing.data[:ttl]
        end

        result = put("/records/#{escape(record_id)}", body: payload)
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["record"]), http_status: result.http_status)
      end

      def delete_record(_zone_id, record_id)
        delete("/records/#{escape(record_id)}")
      end

      private

      def get(path, params: {})
        uri = URI("#{BASE_URL}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        request(Net::HTTP::Get.new(uri))
      end

      def post(path, body:)
        uri = URI("#{BASE_URL}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        request(req)
      end

      def put(path, body:)
        uri = URI("#{BASE_URL}#{path}")
        req = Net::HTTP::Put.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        request(req)
      end

      def delete(path)
        uri = URI("#{BASE_URL}#{path}")
        result = request(Net::HTTP::Delete.new(uri))
        if result.http_status&.between?(200, 204)
          Result.new(ok: true, data: { deleted: true }, http_status: result.http_status)
        else
          result
        end
      end

      def request(req)
        req["Auth-API-Token"] = @api_token
        req["Accept"] = "application/json"

        http = Net::HTTP.new(req.uri.host, req.uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        response = http.request(req)
        parse_response(response)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "Hetzner API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[Acme::Hetzner::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "Hetzner API error: #{e.message}")
      end

      def parse_response(response)
        if response.is_a?(Net::HTTPNoContent)
          return Result.new(ok: true, data: {}, http_status: 204)
        end

        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)

        if response.is_a?(Net::HTTPSuccess)
          Result.new(ok: true, data: parsed, http_status: response.code.to_i)
        else
          msg = parsed["message"] || parsed["error"] || "Hetzner returned HTTP #{response.code}"
          Result.new(ok: false, error: msg, http_status: response.code.to_i,
                      cf_errors: [ { code: response.code, message: msg } ])
        end
      rescue JSON::ParserError
        Result.new(ok: false,
                    error: "Invalid JSON from Hetzner (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
                    http_status: response.code.to_i)
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect} on Hetzner; allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end

      def normalize_ttl(ttl)
        t = ttl.to_i
        return 86_400 if t <= 1 # Hetzner min is 60, but "auto"=1 should bump to a sane default
        [ t, 60 ].max
      end

      def normalize_zone(z)
        {
          id: z["id"].to_s,
          name: z["name"].to_s,
          status: z["status"],
          ttl: z["ttl"],
          records_count: z["records_count"],
          created: z["created"],
          modified: z["modified"]
        }.compact
      end

      def normalize_record(r)
        {
          id: r["id"].to_s,
          zone_id: r["zone_id"].to_s,
          type: r["type"],
          name: r["name"],
          content: r["value"],
          ttl: r["ttl"],
          priority: r["priority"],
          proxied: false,
          created: r["created"],
          modified: r["modified"]
        }.compact
      end
    end
  end
end
