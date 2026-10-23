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

    # Authored, caller-facing text for a failure raised AROUND #test (e.g. by a
    # caller's own plumbing), with the raw message logged redacted. Callers must
    # use this instead of echoing the exception's #message.
    #
    # @return [String]
    def self.safe_error_text(error, provider:)
      new(provider: provider, credentials: {}).send(:safe_error_text, error)
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
      [ false, safe_error_text(e) ]
    end

    # Authored, caller-facing text for each probe failure an operator can act
    # on. The onboarding UI shows the tuple's message verbatim, so a caught
    # exception's own #message never goes there: a driver's names the upstream
    # host and port, an SDK's can echo request detail.
    #
    # Matched by ancestor NAME, not by constant: the SDK and HTTP-client gems
    # behind these classes are optional per build (see #sdk_refusal), and a
    # bare constant for an absent gem would raise NameError inside the very
    # rescue meant to stop a raw failure reaching the caller. Matching
    # ancestors also classifies a future subclass. Timeouts are tested before
    # connection failures because Faraday::TimeoutError is not one, but
    # Net::OpenTimeout and Errno::ETIMEDOUT read as either.
    ERROR_CATEGORIES = [
      [ %w[Timeout::Error Net::OpenTimeout Net::ReadTimeout Net::WriteTimeout Errno::ETIMEDOUT Faraday::TimeoutError],
        "credential check timed out: the provider endpoint did not answer in time. Check the endpoint URL and " \
        "that this platform can reach it, then retry." ],
      [ %w[SocketError Errno::ECONNREFUSED Errno::EHOSTUNREACH Errno::ENETUNREACH Errno::ECONNRESET
           Errno::EADDRNOTAVAIL OpenSSL::SSL::SSLError Faraday::ConnectionFailed Faraday::SSLError
           Seahorse::Client::NetworkingError],
        "provider endpoint unreachable: check the endpoint URL, DNS, firewall rules and the TLS setting " \
        "(verify_ssl) for this provider." ],
      [ %w[System::Providers::BaseProvider::AuthenticationError Faraday::UnauthorizedError Faraday::ForbiddenError
           Aws::Errors::MissingCredentialsError Signet::AuthorizationError],
        "the provider rejected the credentials: check the key or token, that it has not expired, and that it " \
        "is allowed to authenticate." ],
      [ %w[JSON::ParserError Faraday::ParsingError],
        "the provider returned a response this platform could not parse: check that the endpoint URL points at " \
        "the provider's API and not at a proxy or login page." ]
    ].freeze

    UNCATEGORISED_ERROR = "credential check failed with an unexpected error; the server log has the details. " \
                          "Check the provider settings and retry."

    private

    # The withheld text is recorded server-side only, redacted, so an operator
    # can still find out what failed.
    def safe_error_text(error)
      Rails.logger.error(
        "[#{self.class.name}] credential probe for provider_type=#{provider_type_label} withheld " \
        "#{error.class}: #{::System::ShellOutputSanitizer.redact(error.message.to_s)}"
      )
      ancestors = error.class.ancestors.map(&:name)
      category = ERROR_CATEGORIES.find { |names, _| names.intersect?(ancestors) }
      category ? category.last : UNCATEGORISED_ERROR
    end

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
