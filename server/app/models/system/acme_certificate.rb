# frozen_string_literal: true

module System
  # TLS certificate issued by an ACME server (Let's Encrypt by default),
  # used by Traefik for TLS termination on the platform's public
  # listeners. Cert material (PEM, private key, chain, ACME account key)
  # lives in Vault under VaultCredential type "acme_certificate";
  # this row carries identification, lifecycle state, and Vault paths.
  #
  # Lifecycle state machine:
  #
  #   pending ─→ issuing ─→ valid ⇄ renewing ─→ valid
  #         │           ↘     ↓        ↘
  #         │            failed         failed
  #         │              ↑              ↑
  #         └──────────────┴──────────────┘
  #                                     │
  #                                     ▼
  #                                  revoked (terminal)
  #
  # Renewal cadence: AcmeCertificateRenewalJob (P2.5.5) ticks every 6
  # hours and triggers renewing on certs with expires_at within
  # RENEWAL_WINDOW (30 days) of now. Successful renewal returns to
  # `valid`; failure goes through `failed` and retries on next tick.
  #
  # Plan reference: Decentralized Federation §J + P2.5.
  class AcmeCertificate < ApplicationRecord
    self.table_name = "system_acme_certificates"

    include VaultCredential

    self.vault_credential_type = "acme_certificate"

    # The concern + Security::VaultCredentialProvider call into a generic
    # `vault_path` accessor. This table doesn't store data at any one
    # leaf path — Acme::CertificateManager#store_to_vault! writes the
    # cert + private_key + chain + account_key as a SINGLE bundle to the
    # provider's convention path (acme-certificates/<account_id>/<cert_id>),
    # and the four `vault_path_*` columns are operator-visible LABELS
    # (cert vs key vs chain vs account_key) — not actual distinct
    # Vault entries.
    #
    # Returning nil from vault_path forces VaultCredentialProvider#get_credential
    # past its "read by record.vault_path" branch and into the convention
    # lookup, which actually works. The no-op setter accepts (and
    # discards) the provider's `record.update!(vault_path: ...)` call
    # that happens after a successful store. The predicate is false so
    # the concern's `after_destroy :cleanup_vault_secret, if: :vault_path?`
    # hook stays out of the way — Vault cleanup is the controller's
    # responsibility.
    def vault_path; nil; end
    def vault_path=(_value); end
    def vault_path?; false; end

    ISSUERS = %w[letsencrypt-prod letsencrypt-staging internal-ca].freeze
    CHALLENGE_TYPES = %w[dns-01 http-01 tls-alpn-01].freeze
    STATUSES = %w[pending issuing valid renewing expired revoked failed].freeze

    TERMINAL_STATUSES = %w[revoked].freeze

    TRANSITIONS = {
      "pending"  => %w[issuing failed],
      "issuing"  => %w[valid failed],
      "valid"    => %w[renewing expired revoked],
      "renewing" => %w[valid failed],
      "expired"  => %w[renewing revoked],
      "failed"   => %w[issuing renewing revoked],
      "revoked"  => []
    }.freeze

    # Trigger renewal when remaining lifetime drops below this.
    # 30 days gives several retry windows before Let's Encrypt's
    # 90-day cert expiry.
    RENEWAL_WINDOW = 30.days

    belongs_to :account
    belongs_to :dns_credential,
               class_name: "System::AcmeDnsCredential",
               optional: true

    attribute :sans,     :jsonb, default: -> { [] }
    attribute :metadata, :jsonb, default: -> { {} }

    validates :common_name, presence: true, length: { maximum: 255 }
    # Scope uniqueness to non-terminal rows so re-issuing for a domain
    # after revocation succeeds. Without the conditions, an operator
    # couldn't issue a fresh cert for the same hostname even though
    # the old row is logically dead — caught during P2.5.7 acceptance.
    validates :common_name,
              uniqueness: {
                scope: :account_id,
                conditions: -> { where.not(status: TERMINAL_STATUSES) }
              }
    validates :issuer, inclusion: { in: ISSUERS }
    validates :challenge_type, inclusion: { in: CHALLENGE_TYPES }
    validates :status, inclusion: { in: STATUSES }

    validate :dns_credential_required_for_dns01

    scope :issued,         -> { where(status: "valid") }
    scope :pending_issue,  -> { where(status: %w[pending failed]) }
    scope :needs_renewal,  ->(window = RENEWAL_WINDOW) {
      where(status: "valid").where("expires_at < ?", window.from_now)
    }
    scope :expired_certs,  -> { where(status: "expired") }
    scope :active_certs,   -> { where.not(status: TERMINAL_STATUSES) }

    def can_transition_to?(new_status)
      TRANSITIONS.fetch(status, []).include?(new_status.to_s)
    end

    def transition_to!(new_status, error_message: nil, attrs: {})
      return false unless can_transition_to?(new_status)

      merged = attrs.merge(status: new_status.to_s)
      merged[:last_renewal_error] = error_message if error_message
      merged[:last_renewal_error] = nil if new_status.to_s == "valid"
      if %w[issuing renewing failed].include?(new_status.to_s)
        merged[:last_renewal_attempt_at] = Time.current
      end

      update!(merged)
      true
    end

    def expiring_within?(window = RENEWAL_WINDOW)
      expires_at.present? && expires_at < window.from_now
    end

    def expired?
      status == "expired" || (expires_at.present? && expires_at < Time.current)
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    private

    # DNS-01 challenge requires a DNS provider credential to publish
    # the validation record. HTTP-01 + TLS-ALPN-01 don't need one
    # (port 80 / 443 reachability handles validation directly).
    def dns_credential_required_for_dns01
      return unless challenge_type == "dns-01"
      return if dns_credential_id.present?

      errors.add(:dns_credential_id, "is required for dns-01 challenge")
    end
  end
end
