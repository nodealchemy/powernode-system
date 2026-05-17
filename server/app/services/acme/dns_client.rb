# frozen_string_literal: true

module Acme
  # Factory + shared contract for provider-specific DNS clients.
  #
  # The records controller (and any other caller) constructs a client
  # via:
  #
  #   client = Acme::DnsClient.for(provider: "cloudflare", api_token: token)
  #   client.list_zones
  #
  # Each adapter — Cloudflare, DigitalOcean, Hetzner, Route53 — exposes
  # the same Result-shaped methods so callers never branch on provider
  # name after construction.
  #
  # ── Contract ────────────────────────────────────────────────────────
  # Every adapter MUST implement:
  #
  #   #list_zones(name: nil, per_page: 50, page: 1)
  #   #get_zone(zone_id)
  #   #list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
  #   #get_record(zone_id, record_id)
  #   #create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
  #   #update_record(zone_id, record_id, attrs)
  #   #delete_record(zone_id, record_id)
  #
  # Each MUST return Result.new(ok:, data:, error:, http_status:,
  # cf_errors:) — even non-Cloudflare adapters use the same struct
  # (the `cf_errors` field is generically a provider-specific error
  # list; the name is historical).
  #
  # Plan reference: E1 (multi-provider DNS adapters).
  module DnsClient
    Result = ::Acme::Cloudflare::DnsClient::Result

    class UnsupportedProviderError < StandardError; end

    PROVIDER_CLASSES = {
      "cloudflare"  => "Acme::Cloudflare::DnsClient",
      "digitalocean" => "Acme::DigitalOcean::DnsClient",
      "hetzner"     => "Acme::Hetzner::DnsClient",
      "route53"     => "Acme::Route53::DnsClient"
    }.freeze

    class << self
      def for(provider:, api_token:, **opts)
        provider_str = provider.to_s
        klass_name = PROVIDER_CLASSES[provider_str]
        unless klass_name
          raise UnsupportedProviderError,
                "Unsupported DNS provider #{provider.inspect}. Supported: #{PROVIDER_CLASSES.keys.inspect}"
        end
        klass = klass_name.constantize
        klass.new(api_token: api_token, **opts)
      end

      def supported?(provider)
        PROVIDER_CLASSES.key?(provider.to_s)
      end

      def supported_providers
        PROVIDER_CLASSES.keys
      end
    end
  end
end
