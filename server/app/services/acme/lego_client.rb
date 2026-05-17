# frozen_string_literal: true

require "open3"
require "json"

module Acme
  # ACME integration boundary — shells out to the platform's bundled
  # `powernode-acme` Go binary (extensions/system/agent/cmd/powernode-acme).
  # The binary wraps go-acme/lego internally; we never depend on a host-
  # installed `lego` package per the project's no-host-deps rule.
  #
  # Binary resolution:
  #   1. POWERNODE_ACME_BIN env (absolute path)
  #   2. <Rails.root>/../extensions/system/agent/dist/powernode-acme-linux-<arch>
  #   3. raise IntegrationError with build instructions
  #
  # Token handling: the Cloudflare API token is read from Vault on the
  # Rails side and passed to the child process via an env var. We
  # NEVER pass it as a CLI flag (would appear in `ps` listings). The
  # binary reads from the env var name we tell it.
  #
  # Tests stub via Acme::CertificateManager.new(acme_client: ...).
  #
  # Plan reference: Decentralized Federation §J + P2.5.7.
  class LegoClient
    class IntegrationError < StandardError; end

    LE_DIRECTORY = {
      "letsencrypt-prod"    => "https://acme-v02.api.letsencrypt.org/directory",
      "letsencrypt-staging" => "https://acme-staging-v02.api.letsencrypt.org/directory"
    }.freeze

    DEFAULT_TIMEOUT = 300 # seconds — covers DNS propagation + LE polling

    def initialize(binary_path: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
      @binary_path = binary_path
      @timeout = timeout
      @logger = logger || ::Rails.logger
    end

    # Issues a new certificate.
    #
    # @param common_name [String]
    # @param sans [Array<String>]
    # @param challenge [String] dns-01 (only mode wired in v1)
    # @param provider [String] DNS provider slug (cloudflare in v1)
    # @param credentials [Hash] provider credentials hash from Vault
    # @param issuer [String] letsencrypt-prod | letsencrypt-staging
    # @param email [String] ACME account email
    # @param account_key_pem [String, nil] existing account key, optional
    # @return [Hash] { ok:, cert_pem:, key_pem:, chain_pem:, account_key_pem:, issued_at:, expires_at:, ... }
    def issue(common_name:, sans: [], challenge: "dns-01", provider:, credentials:,
              issuer: "letsencrypt-prod", email:, account_key_pem: nil)
      ensure_dns01!(challenge)

      acme_server = LE_DIRECTORY[issuer.to_s] or
        raise IntegrationError, "Unknown issuer #{issuer.inspect}; supported: #{LE_DIRECTORY.keys.inspect}"

      token_env_name, child_env = build_provider_env(provider, credentials)

      argv = [
        binary_path,
        "issue",
        "--domain",       common_name,
        "--email",        email,
        "--acme-server",  acme_server,
        "--issuer",       issuer.to_s,
        "--dns",          provider.to_s,
        "--cf-token-env", token_env_name
      ]
      argv += [ "--sans", sans.join(",") ] if sans.any?
      argv += [ "--account-key-pem", account_key_pem ] if account_key_pem.present?

      @logger.info("[Acme::LegoClient] issue #{common_name} via #{provider} (#{issuer})")
      result = run_binary!(argv, env: child_env)

      unless result["ok"]
        raise IntegrationError, "powernode-acme reported failure: #{result['error']}"
      end
      result
    end

    # Renews a certificate by reissuing under the SAME ACME account key.
    # Identical to issue except the binary takes the `renew` subcommand
    # and account_key_pem is mandatory (without it, lego would register
    # a fresh LE account each cycle — burning rate limits + orphaning
    # the previous registration).
    def renew(common_name:, sans: [], provider:, credentials:, issuer:, email:, account_key_pem:)
      ensure_dns01!("dns-01")
      acme_server = LE_DIRECTORY[issuer.to_s] or
        raise IntegrationError, "Unknown issuer #{issuer.inspect}; supported: #{LE_DIRECTORY.keys.inspect}"
      raise IntegrationError, "account_key_pem required for renewal" if account_key_pem.blank?

      token_env_name, child_env = build_provider_env(provider, credentials)

      argv = [
        binary_path,
        "renew",
        "--domain",          common_name,
        "--email",           email,
        "--acme-server",     acme_server,
        "--issuer",          issuer.to_s,
        "--dns",             provider.to_s,
        "--cf-token-env",    token_env_name,
        "--account-key-pem", account_key_pem
      ]
      argv += [ "--sans", sans.join(",") ] if sans.any?

      @logger.info("[Acme::LegoClient] renew #{common_name} via #{provider} (#{issuer})")
      result = run_binary!(argv, env: child_env)

      raise IntegrationError, "powernode-acme reported failure: #{result['error']}" unless result["ok"]
      result
    end

    # Revokes a certificate at the ACME server. The cert PEM + account
    # key PEM are passed via temp files (rather than argv) because:
    # (a) PEMs are 1-5KB and ARG_MAX hangs are easier to hit than you'd
    # think, (b) anything passed in argv shows in `ps`, while temp
    # files with 0600 perms in `Dir.mktmpdir` are visible only to the
    # process owner.
    REVOKE_REASONS = {
      "unspecified"          => 0,
      "key_compromise"       => 1,
      "ca_compromise"        => 2,
      "affiliation_changed"  => 3,
      "superseded"           => 4,
      "cessation"            => 5,
      "certificate_hold"     => 6,
      "remove_from_crl"      => 8,
      "privilege_withdrawn"  => 9,
      "aa_compromise"        => 10
    }.freeze

    def revoke(certificate_pem:, account_key_pem:, issuer:, email:, reason: nil)
      acme_server = LE_DIRECTORY[issuer.to_s] or
        raise IntegrationError, "Unknown issuer #{issuer.inspect}; supported: #{LE_DIRECTORY.keys.inspect}"
      raise IntegrationError, "certificate_pem required" if certificate_pem.blank?
      raise IntegrationError, "account_key_pem required (only the issuing account can revoke)" if account_key_pem.blank?

      reason_code = case reason
                    when Integer then reason
                    when String then REVOKE_REASONS[reason] || 0
                    else 0
      end

      ::Dir.mktmpdir("powernode-acme-revoke") do |dir|
        cert_file = ::File.join(dir, "cert.pem")
        key_file  = ::File.join(dir, "account.key.pem")
        ::File.write(cert_file, certificate_pem)
        ::File.write(key_file, account_key_pem)
        ::File.chmod(0o600, cert_file)
        ::File.chmod(0o600, key_file)

        argv = [
          binary_path,
          "revoke",
          "--cert-pem-file",         cert_file,
          "--account-key-pem-file",  key_file,
          "--email",                 email,
          "--acme-server",           acme_server,
          "--issuer",                issuer.to_s,
          "--reason",                reason_code.to_s
        ]

        @logger.info("[Acme::LegoClient] revoke cert (#{issuer}, reason=#{reason_code})")
        result = run_binary!(argv, env: {})

        raise IntegrationError, "powernode-acme revoke failed: #{result['error']}" unless result["ok"]
        result
      end
    end

    private

    def ensure_dns01!(challenge)
      return if challenge.to_s == "dns-01"
      raise IntegrationError, "powernode-acme v1 only supports dns-01 (got #{challenge.inspect})"
    end

    # Resolves the env-var name for the provider's secret + builds the
    # child process env. The token plaintext lives in `credentials`
    # (from Vault); we pass it via env so it stays out of process
    # listings.
    def build_provider_env(provider, credentials)
      case provider.to_s
      when "cloudflare"
        env_name = "CLOUDFLARE_DNS_API_TOKEN"
        token = credentials["api_token"] || credentials[:api_token]
        raise IntegrationError, "credentials hash missing api_token for cloudflare" if token.blank?
        [ env_name, { env_name => token } ]
      else
        raise IntegrationError, "DNS provider #{provider.inspect} not yet wired in powernode-acme v1"
      end
    end

    def binary_path
      @binary_path ||= resolve_binary_path
    end

    def resolve_binary_path
      explicit = ENV["POWERNODE_ACME_BIN"]
      return explicit if explicit.present? && ::File.executable?(explicit)

      arch = case `uname -m`.strip
             when "x86_64" then "amd64"
             when "aarch64", "arm64" then "arm64"
             else
               raise IntegrationError, "unsupported architecture for powernode-acme: #{`uname -m`}"
             end

      candidate = ::Rails.root.join(
        "..", "extensions", "system", "agent", "dist", "powernode-acme-linux-#{arch}"
      ).to_s
      return candidate if ::File.executable?(candidate)

      raise IntegrationError, "powernode-acme binary not found. " \
        "Build it via: cd extensions/system/agent && make build-acme. " \
        "Or set POWERNODE_ACME_BIN to its absolute path."
    end

    # Invokes the binary with stdin closed, captures stdout (the JSON
    # result envelope), and parses. Stderr from lego (DNS polling logs,
    # etc.) is captured separately and surfaced in error messages.
    def run_binary!(argv, env:)
      stdout, stderr, status = ::Open3.capture3(env, *argv,
                                                 stdin_data: "")
      unless status.success?
        raise IntegrationError,
              "powernode-acme exited #{status.exitstatus}: stderr=#{stderr[0, 800]}"
      end

      ::JSON.parse(stdout)
    rescue ::JSON::ParserError => e
      raise IntegrationError, "powernode-acme stdout not valid JSON: #{e.message}; " \
                              "stdout=#{stdout.to_s[0, 400]}; stderr=#{stderr.to_s[0, 400]}"
    end
  end
end
