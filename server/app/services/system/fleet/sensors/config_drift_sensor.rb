# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeModuleAssignment rows that have changed (updated_at >
      # last task on the relevant node) but no Task has been dispatched to
      # apply the change to running instances yet. This is the gap between
      # operator intent ("assign this module") and on-node reality ("run
      # this module"). Distinct from ModuleDriftSensor — that one detects
      # *running* drift; this one detects *intent* drift.
      class ConfigDriftSensor < BaseSensor
        # Don't fire for very recent changes — the dispatch loop runs every
        # 60s, so a 5-minute window is the natural floor before this signal
        # is meaningful.
        STALE_THRESHOLD = 5.minutes

        def sense
          cutoff = Time.current - STALE_THRESHOLD
          ::System::NodeModuleAssignment
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where("system_node_module_assignments.updated_at < ?", cutoff)
            .find_each.filter_map do |asgn|
            last_apply = ::System::Task
              .where(operable_type: "System::Node", operable_id: asgn.node_id)
              .where("command LIKE ?", "system.attach%")
              .order(created_at: :desc)
              .pick(:created_at)

            next if last_apply && last_apply > asgn.updated_at

            signal(
              kind: "system.config_drift",
              severity: :medium,
              payload: {
                node_id: asgn.node_id,
                module_id: asgn.node_module_id,
                assignment_id: asgn.id,
                changed_at: asgn.updated_at.iso8601,
                last_apply_at: last_apply&.iso8601
              },
              fingerprint: "config_drift:#{asgn.id}"
            )
          end
        end
      end
    end
  end
end
