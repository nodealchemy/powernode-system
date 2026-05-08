# frozen_string_literal: true

module System
  # System::LifecycleAuditable — decorates AASM-driven NodeInstance lifecycle
  # transitions with audit-log writes for the M4 audit trail.
  #
  # Implementation notes:
  # - This module is `prepend`-ed onto the host class so the bang-method
  #   overrides take precedence over AASM's class-level methods. `super`
  #   then resolves to AASM's original implementation, runs the actual
  #   state transition, and we capture before/after status around it.
  # - This is intentionally a separate concern from the core ::Auditable
  #   module: the core concern short-circuits in `Rails.env.test?` to avoid
  #   multi-connection deadlocks; lifecycle audit writes use a single
  #   AuditLog.create! per transition and MUST be observable in specs.
  # - Logged actions follow `system.node_instance.<event>` naming.
  # - Actor (user/agent), client_ip, request_id, mission_id, and FleetEvent
  #   correlation_id are pulled from `Audit::Context.current` so callers
  #   don't have to thread audit-only kwargs through every service call.
  # - Failures are swallowed and logged so a transient audit-write hiccup
  #   never blocks a lifecycle transition.
  module LifecycleAuditable
    AUDITED_EVENTS = %w[
      start stop reboot terminate
      mark_provisioning mark_running mark_stopped mark_terminated mark_errored
    ].freeze

    AUDITED_EVENTS.each do |event_name|
      bang_method = "#{event_name}!"

      define_method(bang_method) do |*args, **kwargs, &block|
        before_state = status
        result = super(*args, **kwargs, &block)
        after_state = status

        record_lifecycle_audit!(
          event: event_name,
          before_state: before_state,
          after_state: after_state
        )

        result
      end
    end

    private

    def record_lifecycle_audit!(event:, before_state:, after_state:)
      return unless account.present?

      ctx             = ::Audit::Context.current
      correlation_id  = ctx[:correlation_id] || latest_fleet_event_correlation_id

      # NOTE: AuditLog.log_action merges options[:correlation_id] / :request_id /
      # :session_id INTO the metadata hash and then .compact's. Passing them as
      # top-level kwargs (rather than inside :metadata) is the only way to get
      # them written, since the merge would otherwise overwrite metadata keys
      # of the same name with nil. mission_id has no top-level slot, so we
      # pass it through metadata.
      ::AuditLog.log_action(
        action: "system.node_instance.#{event}",
        resource: self,
        user: ctx[:user],
        account: account,
        old_values: { "status" => before_state },
        new_values: { "status" => after_state },
        ip_address: ctx[:ip_address],
        user_agent: ctx[:user_agent],
        request_id: ctx[:request_id],
        correlation_id: correlation_id,
        source: ctx[:source] || "system",
        metadata: {
          mission_id: ctx[:mission_id],
          node_id: try(:node_id),
          instance_name: try(:name)
        }.compact
      )
    rescue StandardError => e
      Rails.logger.error(
        "Failed to write lifecycle audit for #{self.class.name}##{id} #{event}: #{e.message}"
      )
    end

    def latest_fleet_event_correlation_id
      return nil unless defined?(::System::FleetEvent)

      ::System::FleetEvent
        .where(node_instance_id: id)
        .where.not(correlation_id: nil)
        .order(emitted_at: :desc)
        .limit(1)
        .pick(:correlation_id)
    rescue StandardError
      nil
    end
  end
end
