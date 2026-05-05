# frozen_string_literal: true

module System
  class ProviderConnectionSerializer
    def initialize(connection)
      @connection = connection
    end

    def as_json
      {
        id: @connection.id,
        name: @connection.name,
        description: @connection.description,
        endpoint_url: @connection.endpoint_url,
        tenant: @connection.tenant,
        enabled: @connection.enabled,
        status: @connection.status,
        config: @connection.config,
        provider_id: @connection.provider_id,
        provider_name: @connection.provider&.name,
        provider_type: @connection.provider&.provider_type,
        last_tested_at: @connection.last_tested_at,
        last_test_status: @connection.last_test_status,
        last_test_message: @connection.last_test_message,
        # Don't expose credentials. Read raw ciphertext column without
        # triggering Rails-encrypts + Vault peppered decryption — listing
        # N connections would otherwise force N Vault round-trips just to
        # render boolean badges. Columns renamed by migration
        # 20260430210000 (was `*_ciphertext`, now matches `encrypts` API).
        has_access_key: @connection.read_attribute_before_type_cast(:access_key).present?,
        has_secret_key: @connection.read_attribute_before_type_cast(:secret_key).present?,
        created_at: @connection.created_at,
        updated_at: @connection.updated_at
      }
    end
  end
end
