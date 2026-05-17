# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Acme
  module DigitalOcean
    # DigitalOcean DNS adapter. Conforms to the Acme::DnsClient contract
    # so the records controller doesn't branch on provider.
    #
    # Notable DO quirks:
    #   - "Zones" are called "domains". The id IS the domain name (no
    #     opaque uuid), so we use the name as zone_id everywhere.
    #   - Records use integer ids, not strings — we cast to string at
    #     the contract boundary so callers get consistent shape.
    #   - DO doesn't have a "proxied" concept — that flag is ignored.
    #   - Default TTL on DO is 1800; if ttl=1 is passed (Cloudflare's
    #     "auto" sentinel) we substitute 1800 to give a sane default.
    #
    # Plan reference: E2.
    class DnsClient
      BASE_URL = "https://api.digitalocean.com/v2"
      DEFAULT_TIMEOUT = 10
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA].freeze

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
        # DO doesn't filter domains server-side by name; we client-filter
        # to match the contract.
        result = get("/domains", params: params)
        return result unless result.ok?

        domains = Array(result.data["domains"]).map { |d| normalize_zone(d) }
        domains = domains.select { |d| d[:name] == name } if name.present?
        Result.new(ok: true, data: domains, http_status: result.http_status)
      end

      def get_zone(zone_id)
        # DO uses the domain name as the identifier; pass through.
        result = get("/domains/#{escape(zone_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_zone(result.data["domain"]), http_status: result.http_status)
      end

      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        params = { per_page: per_page, page: page }
        params[:type] = type.to_s.upcase if type.present?
        result = get("/domains/#{escape(zone_id)}/records", params: params)
        return result unless result.ok?

        recs = Array(result.data["domain_records"]).map { |r| normalize_record(r, zone_id) }
        recs = recs.select { |r| r[:name] == name || r[:name] == "#{name}.#{zone_id}" } if name.present?
        Result.new(ok: true, data: recs, http_status: result.http_status)
      end

      def get_record(zone_id, record_id)
        result = get("/domains/#{escape(zone_id)}/records/#{escape(record_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["domain_record"], zone_id),
                    http_status: result.http_status)
      end

      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        body = {
          type: type.to_s.upcase,
          # DO records take the *relative* name (e.g. "www" → www.example.com).
          # Operators commonly pass the FQDN, so strip the zone suffix.
          name: relativize_name(name.to_s, zone_id),
          data: content.to_s,
          ttl: normalize_ttl(ttl)
        }
        body[:priority] = extras[:priority].to_i if extras[:priority]
        # DO has no proxied flag; silently drop
        _ = proxied

        result = post("/domains/#{escape(zone_id)}/records", body: body)
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["domain_record"], zone_id),
                    http_status: result.http_status)
      end

      def update_record(zone_id, record_id, attrs)
        if attrs[:type].present?
          validate_record_type!(attrs[:type])
        end
        payload = {}
        payload[:type]     = attrs[:type].to_s.upcase if attrs[:type].present?
        payload[:name]     = relativize_name(attrs[:name].to_s, zone_id) if attrs[:name].present?
        payload[:data]     = attrs[:content].to_s if attrs[:content].present?
        payload[:ttl]      = normalize_ttl(attrs[:ttl]) if attrs[:ttl].present?
        payload[:priority] = attrs[:priority].to_i if attrs[:priority].present?

        result = put("/domains/#{escape(zone_id)}/records/#{escape(record_id)}", body: payload)
        return result unless result.ok?
        Result.new(ok: true, data: normalize_record(result.data["domain_record"], zone_id),
                    http_status: result.http_status)
      end

      def delete_record(zone_id, record_id)
        delete("/domains/#{escape(zone_id)}/records/#{escape(record_id)}")
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
        # DO returns 204 with no body on successful delete
        if result.http_status == 204
          Result.new(ok: true, data: { deleted: true }, http_status: 204)
        else
          result
        end
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
        Result.new(ok: false, error: "DigitalOcean API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[Acme::DigitalOcean::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "DigitalOcean API error: #{e.message}")
      end

      def parse_response(response)
        # 204 No Content (used on DELETE success)
        if response.is_a?(Net::HTTPNoContent)
          return Result.new(ok: true, data: {}, http_status: 204)
        end

        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)

        if response.is_a?(Net::HTTPSuccess)
          Result.new(ok: true, data: parsed, http_status: response.code.to_i)
        else
          msg = parsed["message"] || "DigitalOcean API returned HTTP #{response.code}"
          Result.new(ok: false, error: msg, http_status: response.code.to_i,
                      cf_errors: [ { code: parsed["id"], message: msg } ])
        end
      rescue JSON::ParserError
        Result.new(ok: false,
                    error: "Invalid JSON from DigitalOcean (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
                    http_status: response.code.to_i)
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect} on DigitalOcean; allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end

      # DO's "TTL" must be a multiple of 30 seconds, minimum 30. The
      # Cloudflare convention of `1 = automatic` gets mapped to 1800
      # (DO's default).
      def normalize_ttl(ttl)
        t = ttl.to_i
        return 1800 if t <= 1
        [ t, 30 ].max
      end

      # DO records use the relative name. If the caller passes a FQDN,
      # strip the zone suffix; if they pass "@" or the bare zone, that
      # represents the apex.
      def relativize_name(name, zone_id)
        zone = zone_id.to_s
        return "@" if name.empty? || name == zone
        return name.sub(/\.#{Regexp.escape(zone)}\z/, "") if name.end_with?(".#{zone}")
        name
      end

      # Translate DO's domain shape to the same envelope Cloudflare returns.
      def normalize_zone(d)
        {
          id: d["name"].to_s, # DO uses the name as the id
          name: d["name"].to_s,
          status: "active",
          ttl: d["ttl"],
          zone_file: d["zone_file"]
        }.compact
      end

      # Translate DO's record shape so callers see consistent fields.
      def normalize_record(r, zone_id)
        rel = r["name"].to_s
        fqdn = rel == "@" ? zone_id.to_s : "#{rel}.#{zone_id}"
        {
          id: r["id"].to_s,
          zone_id: zone_id.to_s,
          zone_name: zone_id.to_s,
          type: r["type"],
          name: fqdn,
          content: r["data"],
          ttl: r["ttl"],
          priority: r["priority"],
          proxied: false # DO doesn't support proxied
        }.compact
      end
    end
  end
end
