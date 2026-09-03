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

      # APO-7 SDK guard (IMP-0ddfd8a60032) — the same predicate the row
      # writers apply, here because a credential verdict is a WRITE decision:
      # a green "credentials valid" is what makes the operator persist a
      # System::ProviderCredential for a type this build cannot operate.
      #
      # This is not defence against a crash. #authenticate? on these adapters
      # reaches the AUTH SDK (Aws::STS::Client, from the bundled aws-sdk-core)
      # and never touches the constant that proves the COMPUTE gem is present,
      # so before this guard the probe answered [true, "credentials valid"]
      # for an aws provider on a build with no aws-sdk-ec2. Until now the
      # service was reachable only behind callers that hide inoperable types
      # upstream — a neighbour's guard, which expires the moment a caller
      # arrives carrying its own provider_type.
      if (refusal = sdk_refusal)
        return [ false, refusal ]
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

    # WHAT KEEPS UNREGISTERED TYPES OUT is the call ORDER, not the
    # `supported?` clause inside Registry.sdk_refusal. #test returns early
    # when Registry.adapter_for is nil, and adapter_for is nil on exactly the
    # keys `supported?` is false on — both read PROVIDER_CLASSES with the
    # same normalisation — so digitalocean/linode/vultr/custom keep the "no
    # adapter" verdict above without this helper ever running. That clause
    # therefore cannot fire from this call site: it is defence-in-depth for
    # a future caller that reaches the helper without the early return. The
    # controller door (ProvidersController#refuse_inoperable_provider_type)
    # has no such early return in front of it and the clause IS reachable
    # there — do not reason from one to the other.
    #
    # The predicate itself is Registry.sdk_refusal (IMP-4c825848bb79).
    #
    # @return [String, nil] refusal text naming the missing gem, or nil when
    #   the adapter is operable here
    def sdk_refusal
      registry = ::System::Providers::Registry
      registry.sdk_refusal(provider_type_label)
    end

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
