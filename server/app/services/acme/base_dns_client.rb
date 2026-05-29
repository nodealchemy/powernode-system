# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Acme
  # Shared machinery for the provider-specific DNS adapters
  # (Route53, Google Cloud, Porkbun, OVH, DigitalOcean, Hetzner, …).
  #
  # The adapters all speak the Acme::DnsClient contract and previously
  # copy-pasted: the Net::HTTP transport (use_ssl, read/open timeouts, the
  # Net::OpenTimeout/Net::ReadTimeout + StandardError rescues that return a
  # failed Result), the get/post/put/delete verb wrappers + URI building,
  # the JSON parse/decode skeleton, and a clutch of small helpers
  # (decode_blob / extract_credentials / relativize_name /
  # validate_record_type! / escape / normalize_ttl).
  #
  # This base centralises that machinery. Subclasses override ONLY the
  # provider-specific bits:
  #
  #   - provider_label            → used in error messages + log tag
  #   - auth_headers(req)         → bearer/header auth (default: none)
  #   - request transport         → most use the default; signing providers
  #                                 (Route53, OVH) override #request to add
  #                                 their per-request signature
  #   - parse_success?(response, parsed) → success predicate
  #   - extract_error(parsed, response)  → [message, cf_errors]
  #   - ALLOWED_RECORD_TYPES + normalize_ttl floor/default
  #
  # The shared Result/ApiError structs continue to live on
  # Acme::Cloudflare::DnsClient (the original home) so the historical
  # `cf_errors` field name and the cross-adapter `is_a?` checks keep
  # working unchanged.
  class BaseDnsClient
    Result = ::Acme::Cloudflare::DnsClient::Result

    class ApiError < ::Acme::Cloudflare::DnsClient::ApiError; end

    DEFAULT_TIMEOUT = 10

    # ── HTTP verb wrappers + URI building ──────────────────────────────
    #
    # Subclasses set #base_url (an instance method or constant lookup) and
    # the verbs build the URI, attach a JSON body where relevant, and hand
    # off to #request. Signing adapters that need the bare URI override the
    # verbs (Route53/OVH) — these defaults cover the token/header providers.

    def get(path, params: {})
      uri = build_uri(path)
      uri.query = URI.encode_www_form(params) if params.any?
      request(Net::HTTP::Get.new(uri))
    end

    def post(path, body:)
      uri = build_uri(path)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      request(req)
    end

    def put(path, body:)
      uri = build_uri(path)
      req = Net::HTTP::Put.new(uri)
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      request(req)
    end

    def delete(path)
      uri = build_uri(path)
      request(Net::HTTP::Delete.new(uri))
    end

    private

    def build_uri(path)
      URI("#{base_url}#{path}")
    end

    # The base URL for the provider. Subclasses MUST provide it — either
    # via a BASE_URL constant (the default lookup) or by overriding.
    def base_url
      self.class::BASE_URL
    end

    # ── Transport ──────────────────────────────────────────────────────
    #
    # Attaches provider auth headers, the standard Accept header, performs
    # the request over SSL with the configured timeouts, and funnels the
    # response through #parse_response. Transport failures become a failed
    # Result rather than a raised exception, matching every adapter's prior
    # behavior. Signing adapters override this to add their signature.

    def request(req)
      auth_headers(req)
      req["Accept"] = "application/json"

      response = http_for(req.uri).request(req)
      parse_response(response)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Result.new(ok: false, error: "#{provider_label} API timeout: #{e.message}", http_status: nil)
    rescue StandardError => e
      @logger.error("[#{log_tag}] #{e.class}: #{e.message}")
      Result.new(ok: false, error: "#{provider_label} API error: #{e.message}", http_status: nil)
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = @timeout
      http.open_timeout = @timeout
      http
    end

    # Provider auth header(s). Default is no-op (e.g. Porkbun inlines creds
    # in the body). Token/header providers override.
    def auth_headers(_req); end

    # Human label for error messages, e.g. "Route53", "DigitalOcean".
    def provider_label
      self.class.name.to_s.split("::")[-2].to_s
    end

    # Log tag, e.g. "Acme::DigitalOcean::DnsClient".
    def log_tag
      self.class.name
    end

    # ── JSON parse skeleton ────────────────────────────────────────────
    #
    # Shared envelope: 204 → empty success; parse JSON body; success
    # predicate + error extraction are provider hooks. The invalid-JSON
    # branch is identical across the JSON adapters.

    def parse_response(response)
      if response.is_a?(Net::HTTPNoContent)
        return Result.new(ok: true, data: {}, http_status: 204)
      end

      body = response.body.to_s
      parsed = body.empty? ? {} : JSON.parse(body)

      if parse_success?(response, parsed)
        Result.new(ok: true, data: success_data(parsed), http_status: response.code.to_i)
      else
        message, codes = extract_error(parsed, response)
        Result.new(ok: false, error: message, http_status: response.code.to_i, cf_errors: codes)
      end
    rescue JSON::ParserError
      Result.new(
        ok: false,
        error: "Invalid JSON from #{provider_label} (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
        http_status: response.code.to_i
      )
    end

    # Default success predicate: any 2xx. Cloudflare/Porkbun-style
    # envelopes that can return 2xx with success:false override this.
    def parse_success?(response, _parsed)
      response.is_a?(Net::HTTPSuccess)
    end

    # The data payload on success. Default returns the parsed body as-is.
    def success_data(parsed)
      parsed
    end

    # Returns [message, cf_errors] for a failed response. Subclasses
    # override to match their provider's error envelope exactly.
    def extract_error(parsed, response)
      [ "#{provider_label} API returned HTTP #{response.code}", nil ]
    end

    # ── Credential decoding (factory api_token: passthrough) ───────────
    #
    # Multi-field providers (Porkbun, OVH) accept the factory's lone
    # api_token: keyword as a JSON-encoded blob of their real fields.

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

    # ── Shared small helpers ───────────────────────────────────────────

    def escape(s)
      ERB::Util.url_encode(s.to_s)
    end

    def validate_record_type!(type)
      allowed = self.class::ALLOWED_RECORD_TYPES
      return if allowed.include?(type.to_s.upcase)
      raise self.class::ApiError,
            "Unsupported record type #{type.inspect} on #{provider_label}; allowed: #{allowed.inspect}"
    end

    # Records take the *relative* subdomain. If the caller passes a FQDN,
    # strip the zone suffix; the apex maps to a provider-specific empty
    # sentinel (default "", overridden by DigitalOcean's "@").
    def relativize_name(name, zone_id)
      zone = zone_id.to_s
      return apex_sentinel if name.empty? || name == zone || name == "@"
      return name.sub(/\.#{Regexp.escape(zone)}\z/, "") if name.end_with?(".#{zone}")
      name
    end

    def apex_sentinel
      ""
    end
  end
end
