# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeModuleAssignment rows that have changed (updated_at >
      # the last apply that landed on the relevant node) but no Task has been
      # dispatched to apply the change to running instances yet. This is the
      # gap between operator intent ("assign this module") and on-node reality
      # ("run this module"). Distinct from ModuleDriftSensor — that one detects
      # *running* drift; this one detects *intent* drift.
      class ConfigDriftSensor < BaseSensor
        # Don't fire for very recent changes — the dispatch loop runs every
        # 60s, so a 5-minute window is the natural floor before this signal
        # is meaningful.
        STALE_THRESHOLD = 5.minutes

        # IMP-a99067b836bf: the apply probe used to look for
        # operable_type "System::Node" + command LIKE "system.attach%".
        # Neither half could ever match — System::Task::COMMANDS is a hard
        # allowlist with no "system.attach*" entry (nothing in the repo
        # produces one), and the remediation this signal actually triggers is
        # dispatched onto a System::NodeInstance. So the guard was
        # structurally dead: every assignment past STALE_THRESHOLD re-emitted
        # config_drift on every 60s tick forever, no matter how many times it
        # had been applied successfully (~500 signals/tick on ops-hub, +4 per
        # newly provisioned node, permanently).
        #
        # Source of truth for this pair is DecisionEngine::REMEDIATION_APPLIERS
        # ("system.config_drift" => { command: "apply_config" }) plus
        # DecisionEngine#dispatch_reconcile_task, which resolves the payload's
        # instance_ids to a NodeInstance and creates the task against it.
        # Mirrored rather than referenced: sensors are read-side and must not
        # depend on the engine that consumes them.
        APPLY_COMMAND = "apply_config"
        APPLIED_STATUS = "complete"

        def sense
          cutoff = Time.current - STALE_THRESHOLD
          stale = ::System::NodeModuleAssignment
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where("system_node_module_assignments.updated_at < ?", cutoff)

          last_apply_by_node = last_apply_at_by_node(stale)

          stale.find_each.filter_map do |asgn|
            last_apply = last_apply_by_node[asgn.node_id]

            next if last_apply && last_apply > asgn.updated_at

            # A node with nothing running has no apply target and no on-node
            # state that can be out of compliance, so this assignment cannot
            # be "drifted" in any actionable sense. Emitting anyway produced a
            # signal the only actuator refuses (see instance_ids below):
            # dispatch_reconcile_task resolves Array(payload["instance_ids"]).first
            # and returns applied:false "instance not found", so every such
            # signal minted a permanently ineffective RemediationOutcome —
            # 115 of ops-hub's 135 nodes are terminated CI-pool shells inside
            # the 7-day retention window, each still carrying 4 assignments.
            #
            # NOT a coverage deletion, in two halves — the distinction matters,
            # because only the first half is re-routed and claiming both would
            # overstate it. (a) An instance that is coming up but not up YET is
            # a LIVENESS condition signalled elsewhere: InstanceStatusSensor
            # watches running AND starting (system.instance_silent, :high when
            # it never heartbeat), InstancePoolService's warming-timeout reaper
            # errors a stuck pool member, and DecisionEngine#reap_presumed_dead!
            # flips a long-silent one. (b) For every other status (stopped,
            # pending, provisioning, terminated, error) nothing signals — but
            # nothing did before either: `running` has ALWAYS been the payload
            # scope, so the applier refused those nodes already. This skip
            # stops emitting a signal that was discarded downstream; it does
            # not stop anything from being acted on.
            #
            # And nothing latches: the
            # sensor is rebuilt from the DB on every 60s tick
            # (FleetAutonomyService#collect_signals) and holds no state, so a
            # skipped assignment re-enters the candidate set the moment its
            # node's first instance reaches `running`.
            instance_ids = ::System::NodeInstance.running.where(node_id: asgn.node_id).pluck(:id)
            next if instance_ids.empty?

            signal(
              kind: "system.config_drift",
              severity: :medium,
              payload: {
                node_id: asgn.node_id,
                module_id: asgn.node_module_id,
                assignment_id: asgn.id,
                # F3-09: the decision engine resolves the remediation target
                # (DriftRemediateExecutor + apply_config reconcile task) from
                # the payload's instance ids — without them every invocation
                # ran with instance_id: nil. The engine's find_by(id:) carries
                # NO status filter, so the `running` scope above is the only
                # gate on which statuses can ever become an apply target —
                # mirrored, not referenced, exactly like APPLY_COMMAND.
                instance_ids: instance_ids,
                changed_at: asgn.updated_at.iso8601,
                last_apply_at: last_apply&.iso8601
              },
              fingerprint: "config_drift:#{asgn.id}"
            )
          end
        end

        private

        # ONE grouped query for the whole candidate set, keyed by node id.
        # The probe this replaces ran per-assignment inside find_each; ops-hub
        # carries ~450 assignments, so a per-row subquery would have traded a
        # signal flood for a query flood.
        #
        # Scoped through the assignments' own nodes (not every node in the
        # account) so the aggregate stays proportional to the candidate set,
        # and account-scoped on the task itself so a foreign tenant's row can
        # never suppress our drift — operable_type/operable_id is an open
        # polymorphic pair and System::Task does not validate that the
        # operable's owner matches its own account.
        # The status filter is load-bearing and not redundant with the
        # timestamp: System::Task stamps completed_at on fail!/abort!/cancel!
        # as well as complete! (task.rb:127/137/147/157), so an apply that
        # ERRORED carries one too. Filtering on the timestamp alone would read
        # a failed apply as "applied" and go quiet — the over-suppression
        # failure mode, which is silent where over-signalling is merely loud.
        #
        # completed_at is bounded to now for the same reason: the internal
        # task-report endpoint writes it straight from request params with no
        # upper bound (api/v1/internal/system/tasks_controller.rb), so a skewed
        # or buggy worker could stamp a future time and silence that node's
        # drift permanently. The old probe read created_at, which is
        # DB-stamped and not reachable that way; this one has to say so.
        def last_apply_at_by_node(stale_scope)
          ::System::Task
            .joins("INNER JOIN system_node_instances ON system_node_instances.id = system_tasks.operable_id")
            .where(account_id: account.id,
                   operable_type: "System::NodeInstance",
                   command: APPLY_COMMAND,
                   status: APPLIED_STATUS)
            .where("system_tasks.completed_at <= ?", Time.current)
            .where(system_node_instances: { node_id: stale_scope.select("system_node_module_assignments.node_id") })
            .group("system_node_instances.node_id")
            .maximum("system_tasks.completed_at")
        end
      end
    end
  end
end
