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

      instance = adapter_class.with_credentials(@credentials)

      if instance.authenticate?
        [ true, "credentials valid" ]
      else
        [ false, instance.last_authentication_error || "authentication failed" ]
      end
    rescue StandardError => e
      [ false, e.message ]
    end

    private

    def provider_type_label
      @provider.respond_to?(:provider_type) ? @provider.provider_type : @provider.to_s
    end
  end
end
