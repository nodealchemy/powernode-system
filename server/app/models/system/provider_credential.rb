# frozen_string_literal: true

module System
  # Cloud-provider credential — sibling of Ai::ProviderCredential
  # (LLM-cred). Per-account by default; the platform_pool scope allows
  # operators to seed a shared cred (e.g., a Vultr API key the platform
  # uses for self-serve Pro Cloud activation) that account_owned creds
  # override.
  #
  # Encryption: Rails 7 `encrypts :credentials` on a text column. The
  # plaintext is a Ruby Hash, JSON-serialized via `serialize` BEFORE
  # `encrypts` chains its at-rest encryption. Pattern proven by
  # System::ProviderConnection (access_key / secret_key) — see
  # extensions/system/server/spec/models/system/encrypts_round_trip_spec.rb
  # for the M0.H column-name lesson.
  #
  # Lookup precedence — `for(account:, provider:)`:
  #   1. account_owned + active for that account+provider
  #   2. platform_pool + active for that provider
  #   3. nil
  class ProviderCredential < BaseRecord
    SCOPES = %w[account_owned platform_pool].freeze

    # Order matters: serialize first to register the JSON coder, then
    # encrypts wraps the column writer with at-rest encryption.
    serialize :credentials, coder: JSON
    encrypts :credentials

    # Associations
    belongs_to :account, optional: true # nil for platform_pool
    belongs_to :provider, class_name: "::System::Provider", foreign_key: "provider_id"

    # Scope enum (account_owned: 0, platform_pool: 1)
    enum :scope, { account_owned: 0, platform_pool: 1 }

    # Validations
    validates :name, presence: true, length: { maximum: 255 }
    validates :provider_id, presence: true
    validate :credentials_present
    validates :account_id, presence: true, if: :account_owned?
    validates :account_id, absence: true, if: :platform_pool?

    # Scopes
    scope :active, -> { where(is_active: true) }
    scope :inactive, -> { where(is_active: false) }
    scope :for_provider, ->(provider) {
      where(provider_id: provider.is_a?(::System::Provider) ? provider.id : provider)
    }
    scope :healthy, -> { where(consecutive_failures: 0..2) }

    # Resolve the credential to use for a given (account, provider) pair.
    # account_owned wins over platform_pool. Returns nil when neither exists.
    def self.for(account:, provider:)
      account_id = account.is_a?(::Account) ? account.id : account
      provider_id = provider.is_a?(::System::Provider) ? provider.id : provider

      where(account_id: account_id, provider_id: provider_id, scope: scopes[:account_owned]).active.first ||
        where(provider_id: provider_id, scope: scopes[:platform_pool]).active.first
    end

    # Health helpers — mirror Ai::ProviderCredential#record_success! /
    # record_failure! so the cred-management UI can talk to either model
    # uniformly.
    def record_success!
      update!(
        last_test_at: Time.current,
        last_test_status: "success",
        consecutive_failures: 0,
        last_error: nil,
        is_active: true
      )
    end

    def record_failure!(error_message = nil)
      new_failures = consecutive_failures + 1
      update!(
        last_test_at: Time.current,
        last_test_status: "failed",
        last_error: error_message&.truncate(1000),
        consecutive_failures: new_failures,
        is_active: new_failures <= 5
      )
    end

    def healthy?
      is_active? && consecutive_failures <= 2
    end

    private

    # `validates :credentials, presence: true` is unreliable through the
    # encrypts wrapper — the validator sometimes sees the encrypted
    # ciphertext and sometimes the deserialized hash. Validate against
    # the deserialized value explicitly.
    def credentials_present
      value = credentials
      return if value.is_a?(Hash) && value.any?
      return if value.is_a?(String) && value.present?

      errors.add(:credentials, "can't be blank")
    end
  end
end
