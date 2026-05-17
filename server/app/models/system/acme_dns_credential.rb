# frozen_string_literal: true

module System
  # Per-account DNS provider credentials used by the ACME DNS-01
  # challenge during TLS cert issuance/renewal. Provider API tokens
  # live in Vault (type: "acme_dns"); this row carries identification,
  # validation state, and the Vault path.
  #
  # Supported providers map to the Lego library's DNS-01 plugins.
  # Adding a new provider requires:
  #   1. Add the slug to SUPPORTED_PROVIDERS here
  #   2. Wire the provider's credentials schema into
  #      Acme::DnsProviderRegistry (P2.5.4)
  #
  # Plan reference: Decentralized Federation §J + P2.5.
  class AcmeDnsCredential < ApplicationRecord
    self.table_name = "system_acme_dns_credentials"

    include VaultCredential

    self.vault_credential_type = "acme_dns"

    # The VaultCredential concern + Security::VaultCredentialProvider
    # assume a generic `vault_path` column. This table was created with a
    # more specific name (`vault_path_credentials`) so multi-path callers
    # could coexist; the alias bridges the two so the provider's
    # `record.vault_path` / `record.update!(vault_path: ...)` dispatches
    # to the real column. Generates `vault_path?` predicate too, which
    # the concern's `after_destroy :cleanup_vault_secret, if: :vault_path?`
    # hook needs.
    alias_attribute :vault_path, :vault_path_credentials

    # Whitelist of providers this platform can use. Adding to this list
    # without also wiring DnsProviderRegistry (P2.5.4) results in
    # validation-pass but issuance-fail.
    SUPPORTED_PROVIDERS = %w[
      cloudflare route53 gcloud digitalocean hetzner porkbun ovh
    ].freeze

    STATUSES = %w[untested valid invalid expired].freeze

    # Validation freshness — credentials older than this should be
    # re-tested by the renewal job before being used to solve a
    # challenge. Prevents wasted ACME attempts on stale tokens.
    VALIDATION_FRESHNESS = 24.hours

    belongs_to :account
    has_many :acme_certificates,
             class_name: "System::AcmeCertificate",
             foreign_key: :dns_credential_id,
             dependent: :nullify

    attribute :metadata, :jsonb, default: -> { {} }

    validates :name, presence: true, length: { maximum: 255 }
    validates :provider, presence: true, inclusion: { in: SUPPORTED_PROVIDERS }
    validates :status, inclusion: { in: STATUSES }
    validates :name, uniqueness: { scope: :account_id }

    scope :valid_creds, -> { where(status: "valid") }
    scope :needs_revalidation, ->(threshold = VALIDATION_FRESHNESS.ago) {
      where("last_validated_at IS NULL OR last_validated_at < ?", threshold)
    }

    def provider_credentials_valid?
      status == "valid"
    end

    def needs_revalidation?(threshold: VALIDATION_FRESHNESS.ago)
      last_validated_at.nil? || last_validated_at < threshold
    end

    # Marks the credential as validated. Called by Acme::DnsProviderRegistry
    # after a successful API probe.
    def mark_validated!
      update!(status: "valid", last_validated_at: Time.current)
    end

    def mark_invalid!(reason: nil)
      update!(
        status: "invalid",
        last_validated_at: Time.current,
        metadata: metadata.merge("invalid_reason" => reason.to_s.presence)
      )
    end

  end
end
