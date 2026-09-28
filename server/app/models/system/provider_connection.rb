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
    belongs_to :provider, class_name: "System::Provider"

    # Validations
    validates :name, presence: true, uniqueness: { scope: :account_id }
    validates :status, presence: true, inclusion: { in: STATUSES }

    # Scopes
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :connected, -> { where(status: "connected") }
    scope :pending, -> { where(status: "pending") }
    scope :errored, -> { where(status: "error") }
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
        status: "connected",
        last_tested_at: Time.current,
        last_test_status: "success",
        last_test_message: message
      )
    end

    # Mark as error
    def mark_error!(message)
      update!(
        status: "error",
        last_tested_at: Time.current,
        last_test_status: "error",
        last_test_message: message
      )
    end

    # Live credential check against the cloud provider. Resolves the matching
    # adapter via `Providers::Registry`, calls its `test_connection`, and
    # records the outcome (status, last_tested_at, last_test_status,
    # last_test_message). Returns the adapter's result hash. Both this
    # method's RETURN value and the ROW it writes reach the same MCP payload
    # (system_create_provider_connection's payload[:test_result] and
    # payload[:provider_connection], the latter via
    # ProviderConnectionSerializer exposing last_test_message directly — see
    # also provider_connections_controller.rb:79's REST twin), so
    # last_test_message is NOT internal-only bookkeeping the way e.g.
    # NodeInstance#mark_provider_guest_lost!'s reason is, and must be
    # sanitized the same as the return value (IMP-88ad4adbf97d review round).
    def test_connection!
      adapter = ::System::Providers::Registry.for(self)
      result  = adapter.test_connection

      if result[:success]
        mark_connected!(result[:message])
        result
      else
        # result[:error] is expected to already be adapter-boundary-sanitized
        # (see each provider's #test_connection fix), but this is the shared
        # MCP-reachable chokepoint every adapter's test_connection feeds, so a
        # defense-in-depth scrub sits here too, same reasoning as
        # InstanceControlService/VolumeManagementService's scrub_adapter_leak
        # — and unlike those, the scrubbed value here is also what gets
        # PERSISTED, not just returned.
        raw = result[:error] || "Provider rejected credentials"
        Rails.logger.error("[ProviderConnection] test_connection! reported failure: #{raw}")
        safe = ::System::CallerFacingMessages.scrub_adapter_leak(raw, context: "test_connection")
        mark_error!(safe)
        result.merge(error: safe)
      end
    rescue ::System::Providers::Registry::UnknownProviderError => e
      Rails.logger.error("[ProviderConnection] test_connection! #{e.class}: #{e.message}")
      mark_error!("No provider adapter is configured for this connection")
      { success: false, error: "No provider adapter is configured for this connection" }
    rescue StandardError => e
      # This is the arm a network-level error that NO adapter rescue clause
      # catches lands in directly (e.g. AWS's test_connection only rescues
      # Aws::EC2::Errors::ServiceError, OpenStack's only Excon::Error) — a
      # bare Faraday/Net::HTTP connection failure here can carry the same
      # host:port shape the adapter-boundary fixes exist to withhold, so this
      # arm must be exactly as strict as the rest, never softer because it's
      # "just a rescue".
      Rails.logger.error("[ProviderConnection] test_connection! failed: #{e.class}: #{e.message}")
      mark_error!(::System::CallerFacingMessages::GENERIC)
      { success: false, error: ::System::CallerFacingMessages::GENERIC }
    end
  end
end
