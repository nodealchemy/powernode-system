# frozen_string_literal: true

module System
  class ProviderConnection < BaseRecord
    # Status constants
    STATUSES = %w[pending connected error].freeze

    # Layered encryption: Rails `encrypts` provides at-rest protection; the
    # AccountPepperedEncryption concern adds a per-account Vault transit
    # pepper layer on top. Both layers must be present to recover plaintext.
    # See docs/system/credential-restoration.md.
    include ::AccountPepperedEncryption
    encrypts :access_key
    encrypts :secret_key
    peppered_attribute :access_key, :secret_key

    # Associations
    belongs_to :account
    belongs_to :provider, class_name: 'System::Provider'

    # Validations
    validates :name, presence: true, uniqueness: { scope: :account_id }
    validates :status, presence: true, inclusion: { in: STATUSES }

    # Scopes
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :connected, -> { where(status: 'connected') }
    scope :pending, -> { where(status: 'pending') }
    scope :errored, -> { where(status: 'error') }
    scope :for_provider, ->(provider) { where(provider: provider) }

    # Config accessor
    store_accessor :config

    # Status predicates
    STATUSES.each do |status_name|
      define_method("#{status_name}?") { status == status_name }
    end

    # Mark as connected
    def mark_connected!(message = nil)
      update!(
        status: 'connected',
        last_tested_at: Time.current,
        last_test_status: 'success',
        last_test_message: message
      )
    end

    # Mark as error
    def mark_error!(message)
      update!(
        status: 'error',
        last_tested_at: Time.current,
        last_test_status: 'error',
        last_test_message: message
      )
    end

    # Live credential check against the cloud provider. Resolves the matching
    # adapter via `Providers::Registry`, calls its `test_connection`, and
    # records the outcome (status, last_tested_at, last_test_status,
    # last_test_message). Returns the adapter's result hash.
    def test_connection!
      adapter = ::System::Providers::Registry.for(self)
      result  = adapter.test_connection

      if result[:success]
        mark_connected!(result[:message])
      else
        mark_error!(result[:error] || "Provider rejected credentials")
      end

      result
    rescue ::System::Providers::Registry::UnknownProviderError => e
      mark_error!("Unknown provider: #{e.message}")
      { success: false, error: e.message }
    rescue StandardError => e
      mark_error!("Provider test failed: #{e.message}")
      { success: false, error: e.message }
    end
  end
end
