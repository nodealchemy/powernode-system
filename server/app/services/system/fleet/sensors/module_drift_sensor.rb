# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects instances whose `running_module_digests` JSONB does not match
      # their assigned modules' current_version.oci_digest. The comparison
      # itself lives on NodeInstance#module_drift — the one definition, shared
      # with SystemFleetTool#drift_report and the deployment-scoped drift_check
      # — reached by direct AR access rather than back through the MCP tool.
      # Note #module_drift still loads each instance's assigned modules per
      # instance, so this sensor is one query per assigned module per
      # assessable instance; that is unchanged from the copy it replaced, not
      # fixed by it.
      #
      # POPULATION (IMP-f28b393916f3). The sweep walks every NON-TERMINATED
      # instance and partitions it before asking the drift question:
      #
      #   assessable  — `System::NodeInstance::ACTIVE_STATUSES`, the same
      #                 population drift_check
      #                 (PlatformMaintenanceExecutor#drift_summary_for)
      #                 assesses. The sensor used to scope to `running` alone,
      #                 so it and drift_check disagreed about the same fleet.
      #   unassessed  — `starting`/`stopping`/`rebooting`/`error`. A digest map
      #                 mid-reboot is not evidence of anything, so drift is NOT
      #                 answered for these. Two of those states are what the
      #                 platform's own remediation produces
      #                 (DecisionEngine#reboot_silent_instance issues
      #                 reboot/start), so they are not rare.
      #
      # `terminated` is neither: that replica is gone, not skipped.
      #
      # Assessable is then cut a SECOND time, exactly as drift_check cuts it:
      #
      #   reporting     — has heartbeated at least once (or is `running`, see
      #                   #answers_drift?). Drift is answered; a
      #                   system.module_drift signal may be emitted.
      #   not_reporting — a `pending`/`provisioning`/`stopped` row no agent has
      #                   ever reported for. Its `{}` digest map is the column
      #                   DEFAULT, so #module_drift would call every assigned
      #                   module "missing". That matters here more than in a
      #                   report: DecisionEngine binds system.module_drift to
      #                   DriftRemediateExecutor and REMEDIATION_APPLIERS
      #                   dispatches a `sync_modules` System::Task for it, so
      #                   answering would queue a reconcile against a node with
      #                   no agent on it, every tick.
      #
      # DISCLOSURE, AND ITS REMAINING GAP. Every emitted signal carries the
      # tick's coverage (`fleet_instance_count` / `fleet_assessed_count` /
      # `fleet_not_reporting_count` / `fleet_not_assessed_count` /
      # `fleet_not_assessed_by_status`), so a reader of any drift signal can
      # tell "3 of 10 instances were not asked" from "all 10 were asked".
      #
      # A tick that finds NO drift emits nothing and so still discloses
      # nothing. The right home for that is the tick's own event —
      # `fleet.tick_complete`, emitted by FleetAutonomyService through
      # EventBroadcaster with a free-form payload. That is a FleetEvent, NOT a
      # Signal: it needs no `DecisionEngine::SIGNAL_BINDINGS` entry and no
      # intervention-policy declaration. Threading a per-sensor coverage map
      # out of the sense pass is a change to fleet_autonomy_service.rb, which
      # IMP-f28b393916f3 neither names nor owns; the residual is recorded there
      # rather than worked around with a new signal kind.
      class ModuleDriftSensor < BaseSensor
        def sense
          # `.to_a`, not `find_each`: the sweep must partition the population
          # before asking the drift question, and a partition needs the whole
          # set. Bounded by the account's non-terminated instance count, once
          # per tick.
          all_instances = ::System::NodeInstance
                          .joins(:node)
                          .includes(:node)
                          .where(system_nodes: { account_id: account.id })
                          .where.not(status: "terminated")
                          .to_a

          assessable, unassessed =
            all_instances.partition { |inst| ::System::NodeInstance::ACTIVE_STATUSES.include?(inst.status) }

          reporting, silent = assessable.partition { |inst| answers_drift?(inst) }

          coverage = coverage_payload(all_instances, reporting, silent, unassessed)
          reporting.filter_map { |inst| drift_signal(inst, coverage) }
        end

        private

        def drift_signal(inst, coverage)
          drift = compute_drift(inst)
          return nil if drift.blank?

          signal(
            kind: "system.module_drift",
            severity: severity_for(drift),
            payload: {
              instance_id: inst.id,
              missing_count: drift[:missing].size,
              extra_count: drift[:extra].size,
              mismatched_count: drift[:mismatched].size,
              missing: drift[:missing].keys,
              extra: drift[:extra].keys,
              mismatched: drift[:mismatched].keys
            }.merge(coverage),
            fingerprint: "module_drift:#{inst.id}"
          )
        end

        # `fleet_`-prefixed because these describe the TICK, not the instance
        # the rest of the payload is about — an unprefixed `not_assessed_count`
        # next to `missing_count` reads as a property of this one instance.
        #
        # A breakdown, not a row list: the payload is carried into
        # ApprovalRequest.request_data, so it must be bounded by something
        # other than the fleet's size. `fleet_not_assessed_by_status` is
        # bounded by NodeInstance::STATUSES; the per-instance rows live in the
        # compliance snapshot's drift section, which is a document rather than
        # a per-tick approval payload.
        def coverage_payload(all_instances, reporting, silent, unassessed)
          {
            fleet_instance_count: all_instances.size,
            fleet_assessed_count: reporting.size,
            fleet_not_reporting_count: silent.size,
            fleet_not_assessed_count: unassessed.size,
            fleet_not_assessed_by_status: unassessed.group_by(&:status).transform_values(&:size)
          }
        end

        # `running` is exempt from the heartbeat cut on purpose:
        # #record_heartbeat! writes running_module_digests unconditionally, so a
        # live agent that has mounted nothing persists `{}`. The platform
        # already calls that drift — spec/services/system/fleet/sensors_spec.rb
        # pins THIS sensor emitting for exactly that row, and drift_check's own
        # comment names it as the correct emitter — so the heartbeat gate
        # applies only to the statuses this sweep added.
        def answers_drift?(inst)
          inst.last_heartbeat_at.present? || inst.status == "running"
        end

        def compute_drift(inst)
          drift = inst.module_drift
          # Named limbs, not drift.values — a fourth key added to #module_drift
          # would silently change what this sensor treats as "no drift".
          return nil if drift[:missing].empty? && drift[:extra].empty? && drift[:mismatched].empty?

          drift
        end

        def severity_for(drift)
          total = drift[:missing].size + drift[:extra].size + drift[:mismatched].size
          return :critical if total >= 5
          return :high if total >= 3
          :medium
        end
      end
    end
  end
end
