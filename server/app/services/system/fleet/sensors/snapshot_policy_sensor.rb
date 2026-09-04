# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-c22215ae9546 (APO-5 door 2) — the CONSUMER of the per-project
      # snapshot schedule.
      #
      # IMP-e025722ef14e landed the declaration and the read seam:
      # Ai::Mission#snapshot_policy resolves `snapshot_interval_hours` /
      # `snapshot_retention_count` down the ladder (mission watch_policies →
      # template → account → SiteSetting → constant 0 = off), and
      # System::VolumeManagementService.snapshot_schedule_for turns that into
      # the DUE volumes and the PRUNABLE snapshots for one mission. Nothing
      # called it. A read seam with zero production callers reads as coverage
      # while the question is never asked — the same shape as a notify lane
      # with no applier, one level up — so an operator who declared a 6-hour
      # interval got no snapshots and no error.
      #
      # This sensor asks the question on every tick. It resolves NOTHING of its
      # own: the ladder walk, the "0 means off", the due/retention arithmetic
      # and the which-rows-count-as-a-restore-point rule all live in that one
      # seam, so the sensor that fires and the appliers that act read the SAME
      # declaration (the reason the seam was put on the mission in the first
      # place).
      #
      # Pure read-side per the BaseSensor contract: it only EMITS. The
      # provider calls happen in the DecisionEngine's appliers once the gate
      # proceeds — #create_scheduled_snapshot behind
      # system.volume_snapshot_create (notify_and_proceed: the declared
      # interval IS the operator's opt-in, and they should see it firing) and
      # #prune_retained_snapshot behind the EXISTING
      # system.volume_snapshot_delete row (require_approval; destroying a
      # restore point is one control whichever door it arrives through, which
      # is what PolicyDeclarations' VOLUME_SNAPSHOT_OPERATOR_POLICIES comment
      # reserved this category for).
      #
      # SCOPE: active infrastructure missions on the account — the same scope
      # FleetAutonomyService#collect_project_metrics! sweeps, because a
      # project's volumes are exactly what that mission provisioned. A mission
      # that declared nothing costs two ladder resolutions and NO volume query
      # at all (snapshot_schedule_for returns before it touches them) — the
      # same per-mission ladder ProjectSloSensor's utilization ceilings already
      # walk on every tick, so the common case adds no new shape.
      class SnapshotPolicySensor < BaseSensor
        DUE_KIND      = "system.volume_snapshot_due"
        PRUNABLE_KIND = "system.volume_snapshot_prunable"

        def sense
          missions.flat_map { |mission| signals_for(mission) }
        end

        private

        def missions
          ::Ai::Mission.where(account_id: account.id, mission_type: "infrastructure", status: "active")
        end

        # Per-mission rescue, matching #collect_project_metrics!: one mission
        # whose plan or volumes are in a shape the seam refuses must not take
        # the whole schedule sweep — or, through BaseSensor's caller, the
        # tick's other sensors — down with it.
        def signals_for(mission)
          schedule = ::System::VolumeManagementService.snapshot_schedule_for(mission: mission)

          schedule.due.map { |entry| due_signal(entry) } +
            schedule.prunable.map { |entry| prunable_signal(entry) }
        rescue StandardError => e
          Rails.logger.warn("[SnapshotPolicySensor] mission=#{mission.id} skipped: #{e.class}: #{e.message}")
          []
        end

        # Fingerprinted per VOLUME: the condition is "this volume is overdue",
        # and it clears the moment a snapshot lands — which is what lets
        # RemediationValidator score the create as effective by the
        # fingerprint's absence on a later tick.
        def due_signal(entry)
          volume = entry[:volume]
          signal(
            kind: DUE_KIND,
            severity: :medium,
            payload: {
              "provider_volume_id" => volume.id,
              "volume_name" => volume.name,
              "mission_id" => entry[:mission].id,
              "interval_hours" => entry[:interval_hours],
              "last_snapshot_at" => entry[:last_snapshot_at]&.utc&.iso8601
            },
            fingerprint: "volume_snapshot_due:#{volume.id}"
          )
        end

        # Fingerprinted per SNAPSHOT, not per volume: each row beyond the
        # retention count is a separate destroy decision an operator approves
        # or refuses on its own, and a per-volume key would collapse them into
        # one approval that silently authorised the rest.
        def prunable_signal(entry)
          snapshot = entry[:snapshot]
          signal(
            kind: PRUNABLE_KIND,
            severity: :low,
            payload: {
              "provider_volume_snapshot_id" => snapshot.id,
              "snapshot_name" => snapshot.name,
              "provider_volume_id" => entry[:volume].id,
              "mission_id" => entry[:mission].id,
              "retention_count" => entry[:retention_count],
              "snapshot_created_at" => snapshot.created_at&.utc&.iso8601
            },
            fingerprint: "volume_snapshot_prunable:#{snapshot.id}"
          )
        end
      end
    end
  end
end
