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

    # Defense-in-depth backstop (IMP-88ad4adbf97d), NOT the primary fix — the
    # primary fix is sanitizing each provider adapter's own rescue arms so a
    # raw client-error message never reaches a result hash in the first
    # place (see proxmox_provider.rb / azure_provider.rb). This exists for
    # the adapter this review did not reach, or a future one that
    # regresses the pattern (see the "grep IMPLEMENTATIONS, not just call
    # sites" lesson this family keeps re-learning — a per-adapter walk is
    # thorough today and silently stale the day a ninth adapter ships).
    #
    # Deliberately an ALLOWLIST-shaped check, not a blocklist: it does NOT
    # try to recognize "raw client text" (impossible in general — every
    # vendor SDK formats its own way), it recognizes the one STRUCTURAL
    # SHAPE every leak this family has actually found takes — a host:port
    # pair, because a driver's own connection-failure message names its
    # upstream target that way (Proxmox::Client's "PVE connection failed:
    # #{Faraday message}" carries the PVE host and port verbatim; the same
    # shape recurs across HTTP client libraries generally). A message with
    # no such substring — every legitimate, already-safe phrase in this
    # codebase today, adapter-authored or service-authored — passes through
    # untouched.
    #
    # Requires a LETTER-led host label (or a literal IPv4/bracketed IPv6) so
    # this does not fire on an ordinary "12:34" time or a "3:20" ratio
    # appearing in an otherwise-safe message.
    HOST_PORT_PATTERN = /
      \b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b   # IPv4:port
      |\[[0-9a-fA-F:]+\]:\d{2,5}\b           # [IPv6]:port
      |\b[a-zA-Z][a-zA-Z0-9.-]*:\d{2,5}\b    # hostname(.domain)?:port
    /x

    # Scrubs a caller-facing message ONLY when it structurally looks like a
    # leaked host:port. `context` is a short label (e.g. the action/method)
    # logged alongside the raw message so a scrub is investigable — a scrub
    # firing at all means the adapter-boundary fix has a gap somewhere.
    def self.scrub_adapter_leak(message, context: nil)
      return message unless message.is_a?(String) && message.match?(HOST_PORT_PATTERN)

      Rails.logger.error(
        "[CallerFacingMessages] scrubbed a host:port-shaped message reaching a caller-facing " \
        "boundary#{" (#{context})" if context}: #{message}"
      )
      GENERIC
    end

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
