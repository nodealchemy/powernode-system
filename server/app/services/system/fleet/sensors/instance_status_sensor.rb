# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects instances marked `running` whose last_heartbeat_at is older
      # than 3 × the expected heartbeat interval (default heartbeat is 30s →
      # silent threshold is 90s).
      #
      # Emits `system.instance_silent` signals, which the DecisionEngine
      # binds to the drift_remediate skill (the most informative diagnostic
      # response) and ultimately to the system.instance_reprovision action
      # if drift remediation cannot recover the instance.
      class InstanceStatusSensor < BaseSensor
        # Conservative — assumes 30s heartbeat * 3 + 30s grace.
        # Tuned to agree with CapacityRecommendExecutor::SILENT_HEARTBEAT_AGE.
        SILENT_THRESHOLD = 3.minutes

        def sense
          cutoff = Time.current - SILENT_THRESHOLD
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: %w[running starting])
            .where("last_heartbeat_at < ? OR last_heartbeat_at IS NULL", cutoff)
            .find_each.map do |inst|
            signal(
              kind: "system.instance_silent",
              severity: severity_for(inst, cutoff),
              payload: {
                instance_id: inst.id,
                node_id: inst.node_id,
                last_heartbeat_at: inst.last_heartbeat_at&.iso8601,
                threshold_seconds: SILENT_THRESHOLD.to_i
              },
              fingerprint: "instance_silent:#{inst.id}"
            )
          end
        end

        private

        # No heartbeat ever vs. recently silent. The first means the instance
        # never enrolled successfully (or is mid-bootstrap); the second means
        # an in-flight workload likely just lost connectivity. Severity tracks
        # the difference so DecisionEngine can route accordingly.
        def severity_for(instance, cutoff)
          return :high if instance.last_heartbeat_at.nil?
          return :critical if instance.last_heartbeat_at < cutoff - 30.minutes
          :medium
        end
      end
    end
  end
end
