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
      #
      # `swap_into_place` (IMP-e025722ef14e) is the OPT-IN that finishes a
      # copy restore: the service detaches the source from its instance and
      # attaches the copy at the same device, so the instance runs on the
      # restored disk. Off by default — it detaches a live disk. A swap that
      # fails midway is reported as a FAILURE step naming the stage, while the
      # copy the provider made is still named in the outputs: a restore whose
      # data exists somewhere the caller cannot find is worse than no restore.
      class RestoreVolumeExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "restore_volume",
          description: "Restore a ProviderVolume from one of its completed snapshots. Read restored_in_place in the outputs: true means the volume was rolled back and writes made since the snapshot are DISCARDED; false means the provider copied the snapshot into a new volume (restored_volume_id) and the source volume is unchanged — pass swap_into_place to have the copy swapped onto the source's instance and device (swapped in the outputs). Optionally takes a fresh snapshot first so the pre-restore state stays recoverable. Refuses on providers with no snapshot or no restore primitive rather than reporting a restore that did not happen.",
          category: "devops",
          inputs: {
            snapshot_id: { type: "string", required: true,
                           description: "System::ProviderVolumeSnapshot to restore from (must be status 'completed')" },
            take_snapshot_first: { type: "boolean", required: false, default: true,
                                   description: "Snapshot the volume's CURRENT state before restoring, so the pre-restore data stays recoverable" },
            swap_into_place: { type: "boolean", required: false, default: false,
                               description: "Copy-restore only: detach the source volume from its instance and attach the restored copy at the same device. Ignored on an in-place restore and when the source is not attached" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no snapshot, no restore, no swap" }
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
              restored_volume_id: :string,
              swapped: :boolean
            },
            failures: [ :object ],
            partial: :boolean
          },
          requires_approval: true,
          blast_radius: :high
        )

        # HIER-P2C: bound to the Storage Manager, the agent whose set declares
        # `system.restore_volume` (PolicyDeclarations::STORAGE_MANAGER_POLICIES),
        # so the gate above resolves the owner's row when run as that agent.
        # Fleet Autonomy no longer binds it — no sensor of its remaining set
        # routes here (DecisionEngine::SIGNAL_BINDINGS names no restore skill).
        binds_to "storage_manager"

        protected

        def perform(snapshot_id:, take_snapshot_first: true, swap_into_place: false, dry_run: false, **_extras)
          # BaseSkillExecutor coerces nothing — #validate_inputs! checks
          # presence only and #perform receives the raw input — so a JSON- or
          # LLM-supplied string "false" arrives truthy here. The service casts
          # it too (that is the boundary every door shares), but the DRY-RUN
          # plan below never reaches the service, and a plan announcing a swap
          # the real run would not perform is a plan of a different operation.
          swap_into_place = ::ActiveModel::Type::Boolean.new.cast(swap_into_place) == true
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
                                          take_snapshot_first: take_snapshot_first,
                                          swap_into_place: swap_into_place),
              outputs: { storage_volume_ids: [], restored_from_snapshot_id: snapshot.id,
                         pre_restore_snapshot_id: nil, restored_in_place: nil,
                         restored_volume_id: nil, swapped: nil },
              failures: [],
              partial: false
            )
          end

          run_restore(volume: volume, snapshot: snapshot,
                      take_snapshot_first: take_snapshot_first, swap_into_place: swap_into_place)
        end

        private

        def run_restore(volume:, snapshot:, take_snapshot_first:, swap_into_place:)
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
                restored_volume_id: nil,
                swapped: nil
              )
            end

            pre_restore_snapshot_id = pre.data[:snapshot].id
            planned_actions << { step: "pre_restore_snapshot", volume_id: volume.id,
                                 snapshot_id: pre_restore_snapshot_id }
          end

          result = ::System::VolumeManagementService.restore_snapshot(snapshot: snapshot,
                                                                      swap_into_place: swap_into_place)

          restored_in_place = nil
          restored_volume = nil
          swapped = nil

          # A failed SWAP is a restore that HAPPENED and a swap that did not:
          # the service marks that outcome with swap_stage and still carries
          # the copy, and it must be reported as exactly that — the restore
          # step done, the swap step failed — rather than as a restore that
          # never ran.
          restored = result.success? || result.data[:swap_stage].present?

          if restored
            restored_in_place = result.data[:restored_in_place]
            restored_volume = result.data[:restored_volume]
            swapped = result.data[:swapped]
            planned_actions << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id,
                                 restored_in_place: restored_in_place }
            if result.success? && swapped
              planned_actions << { step: "swap_into_place", volume_id: volume.id,
                                   restored_volume_id: restored_volume&.id,
                                   node_instance_id: result.data[:swapped_instance_id],
                                   device: result.data[:swapped_device] }
            elsif !result.success?
              failures << { step: "swap_into_place", volume_id: volume.id,
                            restored_volume_id: restored_volume&.id,
                            stage: result.data[:swap_stage], error: result.error }
            end
          else
            failures << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id,
                          error: result.error }
          end

          # The volume that actually HOLDS the restored data. On a copy-restore
          # that is the new volume, not the one the caller named. Named
          # whenever the restore step itself landed, swap or no swap.
          holder = restored_volume || volume

          finalize(
            planned_actions: planned_actions,
            failures: failures,
            restored_from_snapshot_id: snapshot.id,
            pre_restore_snapshot_id: pre_restore_snapshot_id,
            storage_volume_ids: restored ? [ holder.id ] : [],
            restored_in_place: restored_in_place,
            restored_volume_id: restored ? holder.id : nil,
            swapped: swapped,
            restored: restored
          )
        end

        def finalize(planned_actions:, failures:, restored_from_snapshot_id:,
                     pre_restore_snapshot_id:, storage_volume_ids:,
                     restored_in_place: nil, restored_volume_id: nil, swapped: nil, restored: false)
          success(
            dry_run: false,
            count: 1,
            planned_actions: planned_actions,
            outputs: {
              storage_volume_ids: storage_volume_ids,
              restored_from_snapshot_id: restored_from_snapshot_id,
              pre_restore_snapshot_id: pre_restore_snapshot_id,
              restored_in_place: restored_in_place,
              restored_volume_id: restored_volume_id,
              swapped: swapped
            },
            failures: failures,
            # A pre-restore snapshot that landed while the restore failed, or a
            # restore that landed while its swap failed, is a genuinely partial
            # outcome — the account now holds a volume or a snapshot in a
            # state the caller did not ask for by name.
            partial: failures.any? && (pre_restore_snapshot_id.present? || restored)
          )
        end

        def build_plan(volume:, snapshot:, take_snapshot_first:, swap_into_place: false)
          steps = []
          steps << { step: "pre_restore_snapshot", volume_id: volume.id } if take_snapshot_first
          steps << { step: "restore_volume", volume_id: volume.id, snapshot_id: snapshot.id }
          steps << { step: "swap_into_place", volume_id: volume.id } if swap_into_place
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
