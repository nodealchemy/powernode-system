# frozen_string_literal: true

module System
  # Caller-safe replacements for raw exception text, shared by every Route 2
  # producer this file's sibling services fix (IMP-7e549d7506cf).
  #
  # EXTENSION-OWNED, not Ai::Tools::BaseTool::DISPATCH_FALLBACK_GENERIC_MESSAGE
  # (review round, HIGH): these System::* services are domain services that
  # also serve REST controllers and worker callers, not just the AI tool
  # layer — they should not reference an Ai::Tools:: constant at all. Worse,
  # that constant is core, versioned code: on a core release before it
  # existed, every one of these "sanitize and degrade gracefully" rescue arms
  # would itself raise NameError, INSIDE the rescue meant to prevent exactly
  # that class of failure from reaching the caller. An extension-owned
  # constant has no such coupling.
  module CallerFacingMessages
    GENERIC = "An internal error occurred processing this request."

    # Classifies a Providers::BaseProvider::ProviderError (or a subclass) into
    # a STATIC, CLASS-KEYED phrase — never the exception's own #message, which
    # can carry raw upstream driver/API text (e.g. base_provider.rb's own
    # `raise ProviderError, error.message`, or pro_cloud_provider.rb's
    # "pro_cloud upstream error: #{error.message}"). `case/when` against the
    # actual exception classes (not a Hash#fetch on exception.class) so a
    # FUTURE subclass of one of these four is still classified correctly via
    # `===`, without this method needing to know about it. Shared by every
    # producer that rescues Providers::BaseProvider::ProviderError, so a
    # caller sees the SAME phrase for the SAME provider failure regardless of
    # which service (Volume, InstanceControl, ...) hit it.
    def self.for_provider_error(exception)
      case exception
      when ::System::Providers::BaseProvider::AuthenticationError
        "provider authentication failed"
      when ::System::Providers::BaseProvider::RateLimitError
        "provider rate limit exceeded"
      when ::System::Providers::BaseProvider::QuotaExceededError
        "provider quota exceeded"
      when ::System::Providers::BaseProvider::ResourceNotFoundError
        "provider resource not found"
      else
        GENERIC
      end
    end
  end
end
