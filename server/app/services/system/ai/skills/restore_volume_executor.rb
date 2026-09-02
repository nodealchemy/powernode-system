# frozen_string_literal: true

module System
  module Ai
    module Skills
      # APO-5 / DR-2 (IMP-4b4bed6967ed) — the restore half of project data
      # protection.
      #
      # Until this executor there was NO restore path at any surface: not REST,
      # not MCP, not a skill. The platform's DR story was re-provision-only —
      # an instance could be replaced, its data could not be brought back. The
      # only "restore" in the tree, worker's Maintenance::DatabaseRestoreJob,
      # restores the PLATFORM database, not a project's volumes.
      #
      # DESTRUCTIVE and irreversible on an :in_place provider, so:
      #   * `requires_approval: true` — BaseSkillExecutor.gate_required? reads
      #     this, so an agent-driven restore parks for an operator.
      #   * `blast_radius: :high` — everything written to the volume since the
      #     snapshot is discarded (on providers that roll back in place).
      #   * NO `rollback:` key, deliberately. There is no inverse operation: a
      #     restore cannot be undone, and declaring a rollback that could not
      #     honour the promise would be worse than declaring none. Callers who
      #     want a way back take a snapshot FIRST — which `take_snapshot_first`
      #     does for them, and which is the default.
      #
      # Composition shape:
      #
      #   VolumeManagementService.snapshot        (optional pre-restore safety net)
      #     → VolumeManagementService.restore_snapshot
      #
      # A provider with no snapshot primitive declines at the service seam and
      # this step FAILS — it never reports a restore that did not happen.
      #
      # RESTORE SEMANTICS travel through in `restored_in_place`. On a provider
      # that restores by COPY (Azure) the source volume is untouched and the
      # restored data lands in a NEW volume, which the service records and this
      # executor reports as `restored_volume_id` — `storage_volume_ids` names
      # the volume that actually holds the restored data, which is NOT the
      # source volume in that case.
      class RestoreVolumeExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "restore_volume",
          description: "Restore a ProviderVolume from one of its completed snapshots. Read restored_in_place in the outputs: true means the volume was rolled back and writes made since the snapshot are DISCARDED; false means the provider copied the snapshot into a new volume (restored_volume_id) and the source volume is unchanged. Optionally takes a fresh snapshot first so the pre-restore state stays recoverable. Refuses on providers with no snapshot or no restore primitive rather than reporting a restore that did not happen.",
          category: "devops",
          inputs: {
            snapshot_id: { type: "string", required: true,
                           description: "System::ProviderVolumeSnapshot to restore from (must be status 'completed')" },
            take_snapshot_first: { type: "boolean", required: false, default: true,
                                   description: "Snapshot the volume's CURRENT state before restoring, so the pre-restore data stays recoverable" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no snapshot, no restore" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            planned_actions: [ :object ],
            outputs: {
              storage_volume_ids: [ :string ],
              restored_from_snapshot_id: :string,
              pre_restore_snapshot_id: :string,
              restored_in_place: :boolean,
              restored_volume_id: :string
            },
            failures: [ :object ],
            partial: :boolean
          },
          requires_approval: true,
          blast_radius: :high
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(snapshot_id:, take_snapshot_first: true, dry_run: false, **_extras)
          snapshot = lookup_snapshot(snapshot_id)
          return failure("snapshot not found: #{snapshot_id}") unless snapshot

          unless snapshot.can_restore?
            return failure("snapshot #{snapshot.name} is not a restore point (status=#{snapshot.status})")
          end

          volume = snapshot.volume
          return failure("snapshot #{snapshot.name} has no volume to restore onto") if volume.nil?

          if dry_run
            return success(
              dry_run: true,
              count: 1,
              planned_actions: build_plan(volume: volume, snapshot: snapshot,
                                          take_snapshot_first: take_snapshot_first),
              outputs: { storage_volume_ids: [], restored_from_snapshot_id: snapshot.id,
                         pre_restore_snapshot_id: nil, restored_in_place: nil,
                         restored_volume_id: nil },
              failures: [],
              partial: false
            )
          end

          run_restore(volume: volume, snapshot: snapshot, take_snapshot_first: take_snapshot_first)
        end

        private

        def run_restore(volume:, snapshot:, take_snapshot_first:)
          planned_actions = []
          failures = []
          pre_restore_snapshot_id = nil

          if take_snapshot_first
            pre = ::System::VolumeManagementService.snapshot(
              volume: volume,
              name: "#{volume.name}-pre-restore-#{Time.current.strftime('%Y%m%d%H%M%S')}",
              description: "Automatic pre-restore snapshot taken before restoring #{snapshot.name}"
            )

            # HARD STOP, not a soft-fail. The caller asked for a way back; if
            # the platform cannot make one, restoring anyway would destroy the
            # current data with no recourse on an in-place provider — the
            # precise outcome the flag was set to avoid. Not conditioned on the
            # provider's restore mode: the mode is the ADAPTER's answer at
            # restore time, and stopping is the conservative reading of a
            # caller who explicitly asked for a way back.
            unless pre.success?
              return finalize(
                planned_actions: planned_actions,
                failures: failures << { step: "pre_restore_snapshot", volume_id: volume.id, error: pre.error },
                restored_from_snapshot_id: snapshot.id,
                pre_restore_snapshot_id: nil,
                storage_volume_ids: [],
                restored_in_place: nil,
                restored_volume_id: nil
              )
            end

            pre_restore_snapshot_id = pre.data[:snapshot].id
            planned_actions << { step: "pre_restore_snapshot", volume_id: volume.id,
                                 snapshot_id: pre_restore_snapshot_id }
          end

          result = ::System::VolumeManagementService.restore_snapshot(snapshot: snapshot)

          restored_in_place = nil
          restored_volume = nil

          if result.success?
            restored_in_place = result.data[:restored_in_place]
            restored_volume = result.data[:restored_volume]
            planned_actions << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id,
                                 restored_in_place: restored_in_place }
          else
            failures << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id,
                          error: result.error }
          end

          # The volume that actually HOLDS the restored data. On a copy-restore
          # that is the new volume, not the one the caller named.
          holder = restored_volume || volume

          finalize(
            planned_actions: planned_actions,
            failures: failures,
            restored_from_snapshot_id: snapshot.id,
            pre_restore_snapshot_id: pre_restore_snapshot_id,
            storage_volume_ids: failures.empty? ? [ holder.id ] : [],
            restored_in_place: restored_in_place,
            restored_volume_id: failures.empty? ? holder.id : nil
          )
        end

        def finalize(planned_actions:, failures:, restored_from_snapshot_id:,
                     pre_restore_snapshot_id:, storage_volume_ids:,
                     restored_in_place: nil, restored_volume_id: nil)
          success(
            dry_run: false,
            count: 1,
            planned_actions: planned_actions,
            outputs: {
              storage_volume_ids: storage_volume_ids,
              restored_from_snapshot_id: restored_from_snapshot_id,
              pre_restore_snapshot_id: pre_restore_snapshot_id,
              restored_in_place: restored_in_place,
              restored_volume_id: restored_volume_id
            },
            failures: failures,
            # A pre-restore snapshot that landed while the restore failed is a
            # genuinely partial outcome — the account now holds a snapshot the
            # caller did not ask for by name.
            partial: failures.any? && pre_restore_snapshot_id.present?
          )
        end

        def build_plan(volume:, snapshot:, take_snapshot_first:)
          steps = []
          steps << { step: "pre_restore_snapshot", volume_id: volume.id } if take_snapshot_first
          steps << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id }
          steps
        end

        def lookup_snapshot(snapshot_id)
          ::System::ProviderVolumeSnapshot.includes(:volume)
                                          .find_by(id: snapshot_id, account_id: @account.id)
        end
      end
    end
  end
end
