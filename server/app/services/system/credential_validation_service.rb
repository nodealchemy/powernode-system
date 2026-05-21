# frozen_string_literal: true

module System
  # Validates cloud-provider credentials by constructing a transient adapter
  # instance and running its cheap auth probe. Used by the M2 BYOC
  # onboarding flow (POST /api/v1/system/provider_credentials/test) before
  # persisting credentials to System::ProviderCredential.
  #
  # Returns a [Boolean, String] tuple — success flag + human-readable
  # message that the onboarding UI can surface verbatim.
  #
  # Reference: Self-Serve Hardening Plan M2, slice A (cloud cred wiring).
  class CredentialValidationService
    # @param provider [System::Provider, String, Symbol] Provider record or
    #   provider_type identifier
    # @param credentials [Hash] Plaintext credential payload (string-keyed)
    # @return [Array(Boolean, String)] Tuple of (valid?, message)
    def self.test(provider:, credentials:)
      new(provider: provider, credentials: credentials).test
    end

    def initialize(provider:, credentials:)
      @provider = provider
      @credentials = credentials || {}
    end

    def test
      adapter_class = ::System::Providers::Registry.adapter_for(@provider)
      unless adapter_class
        return [ false, "no adapter for provider_type=#{provider_type_label}" ]
      end

      # Merge persisted Provider.config (endpoint_url, verify_ssl, region,
      # etc.) UNDER the form's credentials. Form-supplied keys win; provider
      # config fills config-scope fields that the UI Credentials tab excludes
      # (those live on the General tab and are already persisted on Provider).
      # Without this, adapters like ProxmoxProvider that require endpoint_url
      # bail with "Missing credentials" because with_credentials zeros the
      # @connection and the inheritance fallback can't reach Provider.config.
      instance = adapter_class.with_credentials(effective_credentials)

      if instance.authenticate?
        [ true, "credentials valid" ]
      else
        [ false, instance.last_authentication_error || "authentication failed" ]
      end
    rescue StandardError => e
      [ false, e.message ]
    end

    private

    def effective_credentials
      provider_config_hash.merge(stringified_credentials)
    end

    def provider_config_hash
      return {} unless @provider.respond_to?(:config)
      cfg = @provider.config
      return {} unless cfg.is_a?(Hash)
      cfg.transform_keys(&:to_s)
    end

    def stringified_credentials
      (@credentials || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    def provider_type_label
      @provider.respond_to?(:provider_type) ? @provider.provider_type : @provider.to_s
    end
  end
end
