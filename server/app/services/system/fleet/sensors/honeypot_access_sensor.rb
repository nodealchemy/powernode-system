# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects access to honeypot canary modules within the lookback window.
      # Reads from the FleetEvent log (system.honeypot_triggered events that
      # CanaryModuleService.observe_access! emits) — this sensor's role is
      # to elevate them into the autonomy decision pipeline so the
      # operator's approval queue lights up immediately.
      #
      # Severity is always :critical — a canary access is by definition
      # an indicator of compromise.
      class HoneypotAccessSensor < BaseSensor
        LOOKBACK = 15.minutes

        def sense
          return [] unless defined?(::System::FleetEvent)

          ::System::FleetEvent
            .where(account: account, kind: "system.honeypot_triggered")
            .where("emitted_at >= ?", LOOKBACK.ago)
            .find_each.flat_map { |event| signals_for(event) }
        end

        private

        # Quarantine needs a target (F3-08): resolve the running instances on
        # nodes whose enabled assignments include the accessed canary module
        # and emit one signal per instance, so the bound
        # system.instance_terminate approval carries the instance to
        # terminate and dedups per instance. Falls back to a single
        # instance-less signal (module_id keys the approval dedup) when
        # nothing currently hosts the module.
        def signals_for(event)
          base_payload = {
            module_id: event.node_module_id,
            source: event.payload["source"],
            event_id: event.id,
            emitted_at: event.emitted_at.iso8601
          }

          instances = hosting_instances(event.node_module_id)
          if instances.empty?
            return [ signal(
              kind: "system.honeypot_access",
              severity: :critical,
              payload: base_payload,
              fingerprint: "honeypot_access:#{event.id}"
            ) ]
          end

          instances.map do |instance|
            signal(
              kind: "system.honeypot_access",
              severity: :critical,
              payload: base_payload.merge(instance_id: instance.id, node_id: instance.node_id),
              fingerprint: "honeypot_access:#{event.id}:#{instance.id}"
            )
          end
        end

        def hosting_instances(module_id)
          return [] if module_id.blank?

          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: "running")
            .where(node_id: ::System::NodeModuleAssignment.enabled
                                                          .where(node_module_id: module_id)
                                                          .select(:node_id))
        end
      end
    end
  end
end
