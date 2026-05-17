# frozen_string_literal: true

require "net/http"
require "uri"

module Acme
  # Verifies that an operator-supplied DNS provider credential is
  # currently valid by calling each provider's "whoami / verify token"
  # endpoint. Called:
  #
  #   - At create-time (frontend "Test connectivity" button) so the
  #     operator gets immediate feedback before a real cert request
  #     fails 30 seconds in.
  #   - Periodically by the renewal sweep (P2.5.5) to revalidate
  #     credentials that haven't been probed in 24h.
  #
  # Each adapter takes the credential plaintext (already pulled from
  # Vault) and returns Result.new(ok?: true|false, message:, details:).
  # Failures distinguish auth errors (invalid token), permission
  # errors (token works but lacks required scopes), and transport
  # errors (network unreachable, provider 5xx) so the operator UI
  # can surface a specific remediation.
  #
  # Plan reference: Decentralized Federation §J + P2.5.
  class DnsCredentialValidator
    class UnsupportedProviderError < StandardError; end

    Result = Struct.new(:ok?, :message, :details, keyword_init: true) do
      def self.ok(message: "Verified", details: {})
        new(ok?: true, message: message, details: details)
      end

      def self.fail(message:, details: {})
        new(ok?: false, message: message, details: details)
      end
    end

    DEFAULT_TIMEOUT = 10 # seconds

    def initialize(http_client: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
      @http_client = http_client
      @timeout = timeout
      @logger = logger || ::Rails.logger
    end

    # Verifies a credential by provider. `credentials` is the Hash that
    # would otherwise live in Vault — keys per
    # Acme::DnsProviderRegistry.PROVIDERS[provider][:required_fields].
    def verify(provider:, credentials:)
      unless ::Acme::DnsProviderRegistry.supported?(provider)
        return Result.fail(message: "Unsupported provider: #{provider.inspect}")
      end

      missing = required_fields(provider) - credentials.keys.map(&:to_s)
      unless missing.empty?
        return Result.fail(
          message: "Missing required field(s): #{missing.join(', ')}"
        )
      end

      case provider.to_s
      when "cloudflare"  then verify_cloudflare(credentials)
      when "digitalocean" then verify_digitalocean(credentials)
      when "hetzner"     then verify_hetzner(credentials)
      else
        # For providers without a cheap whoami endpoint (route53, gcloud,
        # ovh, porkbun) we accept "looks well-formed" as the operator's
        # word — Lego will surface the real failure at issuance time.
        Result.ok(
          message: "Credentials accepted (provider has no verify endpoint; " \
                   "real check happens on first issuance)",
          details: { skipped: true }
        )
      end
    rescue StandardError => e
      @logger.warn("[Acme::DnsCredentialValidator] #{e.class}: #{e.message}")
      Result.fail(message: "Verification raised: #{e.message}")
    end

    private

    def required_fields(provider)
      ::Acme::DnsProviderRegistry::PROVIDERS[provider.to_s][:required_fields]
    end

    # Cloudflare API token verification.
    #
    # `GET /client/v4/user/tokens/verify` returns 200 + `{success:true,
    # result:{status:"active"}}` when the token is live. The token must
    # additionally carry `Zone:Read` + `Zone:DNS:Edit` permissions for
    # ACME DNS-01 to function, but Cloudflare's verify endpoint doesn't
    # echo scopes — we can only confirm the token is valid. Lego will
    # surface an Authentication/Permission failure at issuance time if
    # the scopes are wrong.
    def verify_cloudflare(creds)
      token = creds["api_token"] || creds[:api_token]
      uri = URI("https://api.cloudflare.com/client/v4/user/tokens/verify")
      response = http_get(uri, "Authorization" => "Bearer #{token}")

      if response.is_a?(Net::HTTPSuccess)
        parsed = parse_json(response.body)
        if parsed.dig("success") == true && parsed.dig("result", "status") == "active"
          Result.ok(
            message: "Cloudflare token verified (status=active). " \
                     "Lego will validate Zone:Read + Zone:DNS:Edit scopes on first issuance.",
            details: { token_id: parsed.dig("result", "id") }
          )
        else
          Result.fail(
            message: "Cloudflare reported token inactive or invalid.",
            details: { response: parsed }
          )
        end
      elsif response.code.to_i == 401 || response.code.to_i == 403
        Result.fail(message: "Cloudflare rejected the token (HTTP #{response.code}). " \
                             "Check that you copied the full token and that it has not been revoked.")
      else
        Result.fail(message: "Cloudflare verify failed: HTTP #{response.code} — #{response.body.to_s[0, 200]}")
      end
    end

    # DigitalOcean: `GET /v2/account` returns 200 when the token works.
    def verify_digitalocean(creds)
      token = creds["auth_token"] || creds[:auth_token]
      uri = URI("https://api.digitalocean.com/v2/account")
      response = http_get(uri, "Authorization" => "Bearer #{token}")

      if response.is_a?(Net::HTTPSuccess)
        Result.ok(message: "DigitalOcean token verified.")
      elsif [ 401, 403 ].include?(response.code.to_i)
        Result.fail(message: "DigitalOcean rejected the token (HTTP #{response.code}).")
      else
        Result.fail(message: "DigitalOcean verify failed: HTTP #{response.code}")
      end
    end

    # Hetzner DNS Console: `GET /api/v1/zones?per_page=1` is a cheap probe.
    def verify_hetzner(creds)
      token = creds["api_token"] || creds[:api_token]
      uri = URI("https://dns.hetzner.com/api/v1/zones?per_page=1")
      response = http_get(uri, "Auth-API-Token" => token)

      if response.is_a?(Net::HTTPSuccess)
        Result.ok(message: "Hetzner token verified.")
      elsif [ 401, 403 ].include?(response.code.to_i)
        Result.fail(message: "Hetzner rejected the token (HTTP #{response.code}).")
      else
        Result.fail(message: "Hetzner verify failed: HTTP #{response.code}")
      end
    end

    def http_get(uri, headers = {})
      if @http_client
        @http_client.call(uri, headers)
      else
        ::Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                          open_timeout: @timeout, read_timeout: @timeout) do |http|
          req = ::Net::HTTP::Get.new(uri.request_uri)
          headers.each { |k, v| req[k] = v }
          http.request(req)
        end
      end
    end

    def parse_json(body)
      ::JSON.parse(body.to_s)
    rescue ::JSON::ParserError
      {}
    end
  end
end
