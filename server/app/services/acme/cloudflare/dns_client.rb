# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Acme
  module Cloudflare
    # Thin wrapper over Cloudflare's v4 DNS API. Takes the operator-stored
    # api_token (already pulled from Vault by the caller) and exposes
    # zone + record CRUD as a small Result-shaped interface so callers
    # don't need to know about HTTP, JSON, or Cloudflare's envelope
    # quirks.
    #
    # Reuses the api_token that's already provisioned for ACME DNS-01
    # challenges — the same token has Zone:Read + Zone:DNS:Edit scopes
    # which is exactly what record management needs.
    #
    # Pagination: Cloudflare returns up to 50 records per page by
    # default; this client doesn't auto-paginate v1. Callers pass
    # explicit page/per_page when they need more than the first page.
    #
    # Plan reference: CF-DNS (Cloudflare DNS record management,
    # complements P2.5 ACME).
    class DnsClient
      BASE_URL = "https://api.cloudflare.com/client/v4"
      DEFAULT_TIMEOUT = 10 # seconds
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA PTR].freeze

      class ApiError < StandardError
        attr_reader :http_status, :cf_errors
        def initialize(message, http_status: nil, cf_errors: nil)
          super(message)
          @http_status = http_status
          @cf_errors = cf_errors
        end
      end

      Result = Struct.new(:ok, :data, :error, :http_status, :cf_errors, keyword_init: true) do
        def ok?
          ok
        end
      end

      def initialize(api_token:, timeout: DEFAULT_TIMEOUT, logger: nil)
        raise ArgumentError, "api_token is required" if api_token.to_s.strip.empty?
        @api_token = api_token
        @timeout = timeout
        @logger = logger || ::Rails.logger
      end

      # ── Zones ────────────────────────────────────────────────────────

      # GET /zones[?name=...&per_page=50]
      def list_zones(name: nil, per_page: 50, page: 1)
        params = { per_page: per_page, page: page }
        params[:name] = name if name.present?
        get("/zones", params: params)
      end

      # GET /zones/:id
      def get_zone(zone_id)
        get("/zones/#{escape(zone_id)}")
      end

      # ── DNS Records ──────────────────────────────────────────────────

      # GET /zones/:zone_id/dns_records[?type=A&name=foo.example.com&per_page=50]
      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        params = { per_page: per_page, page: page }
        params[:type] = type if type.present?
        params[:name] = name if name.present?
        get("/zones/#{escape(zone_id)}/dns_records", params: params)
      end

      # GET /zones/:zone_id/dns_records/:id
      def get_record(zone_id, record_id)
        get("/zones/#{escape(zone_id)}/dns_records/#{escape(record_id)}")
      end

      # POST /zones/:zone_id/dns_records
      # body: { type, name, content, ttl, proxied, priority?, comment?, tags? }
      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        body = {
          type: type.to_s.upcase,
          name: name.to_s,
          content: content.to_s,
          ttl: ttl,
          proxied: !!proxied
        }
        body.merge!(extras.slice(:priority, :comment, :tags)) if extras.any?
        post("/zones/#{escape(zone_id)}/dns_records", body: body)
      end

      # PATCH /zones/:zone_id/dns_records/:id  (partial update — only
      # supplied fields are changed)
      def update_record(zone_id, record_id, attrs)
        if attrs[:type].present?
          validate_record_type!(attrs[:type])
          attrs = attrs.merge(type: attrs[:type].to_s.upcase)
        end
        patch("/zones/#{escape(zone_id)}/dns_records/#{escape(record_id)}", body: attrs)
      end

      # DELETE /zones/:zone_id/dns_records/:id
      def delete_record(zone_id, record_id)
        delete("/zones/#{escape(zone_id)}/dns_records/#{escape(record_id)}")
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

      def patch(path, body:)
        uri = URI("#{BASE_URL}#{path}")
        req = Net::HTTP::Patch.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        request(req)
      end

      def delete(path)
        uri = URI("#{BASE_URL}#{path}")
        request(Net::HTTP::Delete.new(uri))
      end

      def request(req)
        req["Authorization"] = "Bearer #{@api_token}"
        req["Accept"] = "application/json"

        http = Net::HTTP.new(req.uri.host, req.uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        response = http.request(req)
        parse_response(response)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "Cloudflare API timeout: #{e.message}", http_status: nil)
      rescue StandardError => e
        @logger.error("[Acme::Cloudflare::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "Cloudflare API error: #{e.message}", http_status: nil)
      end

      # Cloudflare envelope shape:
      #   { success: bool, errors: [{code, message}], messages: [], result: <data> }
      # Even 2xx responses may have success: false (e.g. duplicate record).
      def parse_response(response)
        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)

        if response.is_a?(Net::HTTPSuccess) && parsed["success"]
          Result.new(ok: true, data: parsed["result"], http_status: response.code.to_i)
        else
          errors = Array(parsed["errors"])
          msg = errors.first&.dig("message") ||
                "Cloudflare API returned #{response.code}"
          Result.new(
            ok: false,
            error: msg,
            http_status: response.code.to_i,
            cf_errors: errors
          )
        end
      rescue JSON::ParserError
        Result.new(
          ok: false,
          error: "Invalid JSON from Cloudflare (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
          http_status: response.code.to_i
        )
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect}; allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end
    end
  end
end
