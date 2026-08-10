# frozen_string_literal: true

module System
  # Places, releases and verifies an operator hold on a NodeInstance.
  #
  # A hold means "do not start this while I am working on its disks". It is
  # recorded on the instance AND, where the provider can enforce it, pushed down
  # to the provider — because a platform-side flag only binds callers that come
  # through the platform. On 2026-07-27 the start that raced offline maintenance
  # on ops-hub was a hypervisor task; a DB column alone would not have stopped
  # it, and the resulting concurrent mount truncated a file to zero bytes in the
  # guest's view while it hashed correctly from the host's.
  #
  # It is a LEASE: who, why, and until when. Expiry ALERTS but never releases —
  # a hold that lifts itself part-way through maintenance is worse than no hold,
  # because the operator believes they are still protected.
  class InstanceOpsHoldService
    DEFAULT_TTL = 4.hours

    Result = Struct.new(:ok, :instance, :provider_state, :provider_enforced, :message, :error,
                        keyword_init: true) do
      def ok? = ok
    end

    def self.hold!(...)    = new.hold!(...)
    def self.release!(...) = new.release!(...)
    def self.status(...)   = new.status(...)

    # @param ttl [ActiveSupport::Duration] advisory lease length; expiry alerts,
    #   it does not auto-release.
    def hold!(instance:, user:, reason:, ttl: DEFAULT_TTL)
      return err(instance, "reason is required — an unattributed hold is indistinguishable from a bug later") if reason.blank?
      return err(instance, "user is required — a hold records who to ask before clearing it") if user.nil?

      if instance.ops_held?
        return err(instance, "already #{instance.ops_hold_summary}")
      end

      provider_state, enforced = push_hold_to_provider(instance, reason)

      instance.update!(
        ops_hold_at:             Time.current,
        ops_hold_expires_at:     ttl.present? ? Time.current + ttl : nil,
        ops_hold_reason:         reason,
        ops_hold_by_id:          user.id,
        ops_hold_provider_state: provider_state
      )

      Result.new(
        ok: true, instance: instance, provider_state: provider_state, provider_enforced: enforced,
        message: enforced ? "Hold placed and enforced at the provider (#{provider_state})."
                          : "Hold placed. This provider cannot enforce it, so only callers " \
                            "going through the platform are blocked — a hypervisor-side start would still succeed."
      )
    end

    def release!(instance:, user: nil)
      return err(instance, "no ops hold is in place") unless instance.ops_held?

      released = release_hold_at_provider(instance)

      instance.update!(
        ops_hold_at: nil, ops_hold_expires_at: nil, ops_hold_reason: nil,
        ops_hold_by_id: nil, ops_hold_provider_state: nil
      )

      Rails.logger.info("[InstanceOpsHoldService] hold released on #{instance.name} by #{user&.email || "system"}")
      Result.new(ok: true, instance: instance, provider_enforced: released,
                 message: "Hold released.")
    end

    # Verified by READING provider state. Never by attempting a start: a probe
    # that finds the hold broken has just started the instance you needed
    # stopped — the precise mistake that made the original incident worse.
    def status(instance:)
      provider_state = read_provider_state(instance)
      drift =
        if instance.ops_held? && provider_supports?(instance) && provider_state.blank?
          "Platform holds this instance but the provider reports no lock — a hypervisor-side " \
          "start would NOT be blocked. Re-apply the hold."
        elsif !instance.ops_held? && provider_state.present?
          "Provider reports lock #{provider_state.inspect} but the platform has no hold recorded. " \
          "Something outside the platform locked it, or a release was interrupted."
        end

      Result.new(
        ok: true, instance: instance, provider_state: provider_state,
        provider_enforced: provider_supports?(instance),
        message: instance.ops_held? ? instance.ops_hold_summary : "No ops hold.",
        error: drift
      )
    end

    private

    def err(instance, message)
      Result.new(ok: false, instance: instance, error: message)
    end

    # Memoised: hold!/status call this several times, and each miss is a
    # connection lookup. Nil is a legitimate answer (no provider connection, or
    # an instance with no provider key), so track resolution separately.
    def provider_for(instance)
      return @provider if defined?(@provider)

      @provider =
        if instance.key.blank?
          nil
        else
          ::System::Providers::Registry.for_instance(instance)
        end
    rescue StandardError => e
      Rails.logger.warn("[InstanceOpsHoldService] provider unavailable for #{instance.name}: #{e.message}")
      @provider = nil
    end

    def provider_supports?(instance)
      p = provider_for(instance)
      p.respond_to?(:supports_ops_hold?) && p.supports_ops_hold?
    end

    # Returns [provider_state, enforced]. A provider that cannot enforce is NOT
    # an error — the platform-level guard still applies — but the caller is told
    # plainly, because "held" meaning two different things depending on provider
    # is how an operator ends up trusting a hold that isn't there.
    def push_hold_to_provider(instance, reason)
      p = provider_for(instance)
      return [ nil, false ] unless p.respond_to?(:supports_ops_hold?) && p.supports_ops_hold?

      result = p.apply_ops_hold!(instance.key, reason: reason)
      return [ nil, false ] unless result.is_a?(Hash) && result[:success]

      [ result[:state].presence || read_provider_state(instance), true ]
    rescue StandardError => e
      Rails.logger.warn("[InstanceOpsHoldService] provider hold failed for #{instance.name}: #{e.message}")
      [ nil, false ]
    end

    def release_hold_at_provider(instance)
      p = provider_for(instance)
      return false unless p.respond_to?(:supports_ops_hold?) && p.supports_ops_hold?

      result = p.release_ops_hold!(instance.key)
      result.is_a?(Hash) && result[:success]
    rescue StandardError => e
      Rails.logger.warn("[InstanceOpsHoldService] provider release failed for #{instance.name}: #{e.message}")
      false
    end

    def read_provider_state(instance)
      p = provider_for(instance)
      return nil unless p.respond_to?(:ops_hold_state)

      p.ops_hold_state(instance.key)
    rescue StandardError => e
      Rails.logger.warn("[InstanceOpsHoldService] provider state read failed for #{instance.name}: #{e.message}")
      nil
    end
  end
end
