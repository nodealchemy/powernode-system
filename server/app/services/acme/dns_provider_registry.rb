# frozen_string_literal: true

module Acme
  # Registry of supported DNS providers for ACME DNS-01 challenges.
  # Each entry declares:
  #
  #   - lego_id: the provider identifier the Lego library expects
  #   - required_fields: credential fields the operator must supply
  #     (validated before issuance — missing fields = hard failure)
  #   - description: operator-facing label for the dashboard
  #   - production_ready: whether the provider is wired end-to-end through
  #     the on-node ACME issuer (agent/internal/acme/issuer.go). A provider
  #     that is advertised but not ready can be configured nowhere in the UI:
  #     the credential would be accepted and then fail at first issuance.
  #     This lives here, not in the frontend, so enabling a provider is a
  #     backend change and per-deployment readiness can differ.
  #
  # Adding a new provider:
  #   1. Add the entry below (production_ready: false until the agent-side
  #      issuer is verified end-to-end against it)
  #   2. Add the slug to System::AcmeDnsCredential::SUPPORTED_PROVIDERS
  #   3. (Optional) wire a network-validation probe in
  #      `validate_credentials_via_api!` for the new provider
  #   4. Update docs/federation/REVERSE_PROXY_GUIDE.md
  #
  # Plan reference: Decentralized Federation §J + P2.5.4.
  class DnsProviderRegistry
    class ProviderError < StandardError; end
    class UnknownProviderError < ProviderError; end

    PROVIDERS = {
      "cloudflare" => {
        lego_id: "cloudflare",
        required_fields: %w[api_token],
        description: "Cloudflare DNS via API token (Zone:Read + Zone:Edit scopes)",
        # Verified end-to-end through the on-node issuer.
        production_ready: true
      },
      "route53" => {
        lego_id: "route53",
        required_fields: %w[access_key_id secret_access_key region],
        description: "AWS Route53 via IAM access key + secret",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      },
      "gcloud" => {
        lego_id: "gcloud",
        required_fields: %w[service_account_json project_id],
        description: "Google Cloud DNS via service-account JSON",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      },
      "digitalocean" => {
        lego_id: "digitalocean",
        required_fields: %w[auth_token],
        description: "DigitalOcean DNS via personal access token",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      },
      "hetzner" => {
        lego_id: "hetzner",
        required_fields: %w[api_token],
        description: "Hetzner DNS Console via API token",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      },
      "porkbun" => {
        lego_id: "porkbun",
        required_fields: %w[api_key secret_api_key],
        description: "Porkbun DNS via API key + secret API key",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      },
      "ovh" => {
        lego_id: "ovh",
        required_fields: %w[application_key application_secret consumer_key endpoint],
        description: "OVH DNS via application credentials (ovh-eu / ovh-us / ovh-ca)",
        # Registry entry only — not yet wired through the on-node issuer.
        production_ready: false
      }
    }.freeze

    class << self
      def supported?(slug)
        PROVIDERS.key?(slug.to_s)
      end

      def lookup(slug)
        PROVIDERS[slug.to_s] or
          raise UnknownProviderError, "Unknown DNS provider: #{slug.inspect} " \
                                       "(supported: #{all_slugs.inspect})"
      end

      def all_slugs
        PROVIDERS.keys
      end

      # Whether the provider is usable for real issuance today. Unknown
      # slugs are NOT ready — an unrecognised provider can never have been
      # verified, so answering false is the safe reading and spares every
      # caller a rescue around `lookup`.
      def production_ready?(slug)
        PROVIDERS.dig(slug.to_s, :production_ready) == true
      end


      def lego_id_for(slug)
        lookup(slug)[:lego_id]
      end

      # Validates that a credentials hash has all required fields for its
      # provider. Does NOT perform a network probe — that's the
      # responsibility of `validate_credentials_via_api!` (P2.5.4
      # follow-up) which actually hits the provider's API.
      def validate_credential_shape!(slug:, credentials_hash:)
        provider = lookup(slug)
        creds = (credentials_hash || {}).transform_keys(&:to_s)
        missing = provider[:required_fields].reject { |f| creds[f].to_s.strip.present? }

        if missing.any?
          raise ProviderError, "Provider #{slug.inspect} missing required fields: #{missing.inspect}"
        end
        true
      end
    end
  end
end
