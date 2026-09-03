# frozen_string_literal: true

module System
  # Manages cloud storage volumes (provision/attach/detach/delete/check) via
  # provider adapters. Public methods return System::Runtime::Result.
  class VolumeManagementService
    class VolumeError < StandardError; end

    # Restore modes BaseProvider#volume_snapshot_restore_mode may declare.
    # Anything else (including the :none default) means the provider has no
    # restore primitive and #restore_snapshot refuses rather than calling it.
    RESTORE_MODES = %i[in_place copy].freeze

    def self.attach(volume:, instance:, device: nil)
      new.attach(volume: volume, instance: instance, device: device)
    end

    def self.detach(volume:, force: false)
      new.detach(volume: volume, force: force)
    end

    def self.provision(account:, region:, volume_type:, size_gb:, options: {})
      new.provision(account: account, region: region, volume_type: volume_type, size_gb: size_gb, options: options)
    end

    def self.delete(volume:)
      new.delete(volume: volume)
    end

    def self.check(volume:)
      new.check(volume: volume)
    end

    def self.snapshot(volume:, name: nil, description: nil)
      new.snapshot(volume: volume, name: name, description: description)
    end

    def self.list_snapshots(volume:, reconcile: false)
      new.list_snapshots(volume: volume, reconcile: reconcile)
    end

    def self.delete_snapshot(snapshot:)
      new.delete_snapshot(snapshot: snapshot)
    end

    def self.restore_snapshot(snapshot:, swap_into_place: false)
      new.restore_snapshot(snapshot: snapshot, swap_into_place: swap_into_place)
    end

    # === Snapshot schedule evaluation (IMP-e025722ef14e, APO-5 remainder) ===
    #
    # The READ-SIDE half of scheduled project snapshots. A project
    # (Ai::Mission) declares `snapshot_interval_hours` / `snapshot_retention
    # _count` in its watch_policies (Ai::Mission#snapshot_policy resolves the
    # ladder); this answers, for that project's volumes, which are DUE a
    # snapshot and which completed snapshots exceed retention and are
    # PRUNABLE. It mutates nothing — the BaseSensor contract — so the sensor
    # that emits from it and the appliers that act on its answer can each be
    # reasoned about alone. Taking the snapshot is #snapshot; pruning MUST ask
    # the SAME approval-gated delete the MCP verb goes through
    # (system.volume_snapshot_delete → #delete_snapshot on approval), so one
    # operator row governs a delete whichever door it arrives through.
    #
    # NOTHING CALLS THIS YET, and that is a KNOWN GAP, not a finished lane: a
    # declared schedule is evaluated only by whoever calls the service until a
    # sensor emits from it. The sensor, its FleetAutonomyService::SENSORS
    # registration, its DecisionEngine::SIGNAL_BINDINGS entries, its
    # FLEET_SENSORS.md rows and the snapshot-taking applier must land in ONE
    # change (spec/docs/fleet_sensors_signal_kinds_spec.rb equates the doc's
    # declared kinds with the emitted set), and the sensors directory belonged
    # to another lane in this batch — so it is tracked as improvement
    # 01a065df-4ab7-7a04-8293-8069d805b0b1 rather than left as a comment.
    #
    # `due` entries:      { volume:, mission:, interval_hours:, last_snapshot_at: }
    # `prunable` entries: { snapshot:, volume:, mission:, retention_count: }
    #
    # A project's volumes are the ones attached to the instances its plan
    # provisioned — resolved through System::ProjectMetricsCollector's own
    # walk of the plan's recorded step outputs, never a re-implementation of
    # it (a copy shares none of the shapes that resolver has learned to read).
    SnapshotSchedule = Struct.new(:mission, :policy, :due, :prunable, keyword_init: true)

    def self.snapshot_schedule_for(mission:, now: Time.current)
      new.snapshot_schedule_for(mission: mission, now: now)
    end

    def attach(volume:, instance:, device: nil)
      validate_volume!(volume)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Volume has no cloud volume ID") unless volume.external_id.present?
      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?
      return Runtime::Result.err(error: "Volume is already attached") if volume.attached?

      Rails.logger.info("[VolumeManagementService] Attaching volume #{volume.name} to #{instance.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      device ||= next_available_device(instance)
      result = provider_adapter.attach_volume(volume.external_id, instance.cloud_instance_id, device: device)

      if result[:success]
        attached_device = result[:device] || device

        unless volume.attach_to!(instance, attached_device)
          return Runtime::Result.err(error: "Volume cannot be attached (status=#{volume.status}, attached=#{volume.attached?})")
        end

        Runtime::Result.ok(data: { device: attached_device })
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError, VolumeError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Attach failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def detach(volume:, force: false)
      validate_volume!(volume)

      return Runtime::Result.err(error: "Volume has no cloud volume ID") unless volume.external_id.present?

      return Runtime::Result.ok(data: { message: "Volume is not attached" }) unless volume.attached?

      Rails.logger.info("[VolumeManagementService] Detaching volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.detach_volume(volume.external_id, force: force)

      if result[:success]
        volume.detach!
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Detach failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def provision(account:, region:, volume_type:, size_gb:, options: {})
      validate_region!(region)

      Rails.logger.info("[VolumeManagementService] Provisioning #{size_gb}GB volume in #{region.name}")

      connection = Providers::Registry.find_connection_for_region(region, account)
      return Runtime::Result.err(error: "No provider connection available") unless connection

      provider_adapter = begin
        Providers::Registry.for(connection, region: region)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      # Capability gate (F4-06) — refuse BEFORE creating the volume row;
      # an unsupported adapter used to strand the row in "creating".
      unless provider_adapter.supports?(:volumes)
        return Runtime::Result.err(error: "Provider #{provider_adapter.provider_type} does not support volumes")
      end

      volume = ::System::ProviderVolume.create!(
        name: options[:name] || "volume-#{Time.current.strftime('%Y%m%d%H%M%S')}",
        account: account,
        provider_region: region,
        volume_type: volume_type,
        size_gb: size_gb,
        status: "creating"
      )

      provider_params = {
        name: volume.name,
        size_gb: size_gb,
        volume_type: volume_type&.name,
        availability_zone: options[:availability_zone],
        encrypted: options[:encrypted],
        kms_key_id: options[:kms_key_id],
        iops: options[:iops],
        throughput: options[:throughput]
      }.compact

      result = provider_adapter.create_volume(provider_params)

      if result[:success]
        volume.update!(external_id: result[:volume_id], status: "available")
        Runtime::Result.ok(data: { volume: volume })
      else
        # "failed" is not in ProviderVolume::STATUSES — writing it raised
        # RecordInvalid and stranded the row in "creating" (F4-09).
        volume.update!(status: "error")
        Runtime::Result.err(error: result[:error], data: { volume: volume })
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Provision failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def delete(volume:)
      validate_volume!(volume)

      unless volume.external_id.present?
        volume.destroy!
        return Runtime::Result.ok
      end

      return Runtime::Result.err(error: "Volume is attached, detach first") if volume.attached?

      Rails.logger.info("[VolumeManagementService] Deleting volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.delete_volume(volume.external_id)

      if result[:success]
        volume.destroy!
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    def check(volume:)
      validate_volume!(volume)

      unless volume.external_id.present?
        return Runtime::Result.ok(data: { status: volume.status, health: "unknown", message: "No cloud volume" })
      end

      Rails.logger.info("[VolumeManagementService] Checking volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.get_volume(volume.external_id)

      if result[:success]
        volume.update!(status: result[:status]) if result[:status] != volume.status

        Runtime::Result.ok(data: {
          status: result[:status],
          size_gb: result[:size_gb],
          volume_type: result[:volume_type],
          attached_to: result[:attached_to],
          device: result[:device]
        })
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    # === Volume snapshots (APO-5 / DR-2) ===
    #
    # Project data protection. Before this the only backup the platform had was
    # its OWN database (worker's Maintenance::ScheduledBackupJob) — a project's
    # volumes had no snapshot and no restore. The REST twin
    # (provider_volumes#snapshot) INSERTed a "pending" row and returned 201
    # without asking any provider, so a snapshot row was never evidence that a
    # restore point existed.
    #
    # The rule these methods keep: the ROW never claims more than the PROVIDER
    # did. A provider that cannot snapshot leaves no row at all (nothing to
    # mistake for a restore point); a provider whose snapshot call FAILS leaves
    # an "error" row (the attempt is on the record, and #can_restore? is false
    # for it); only a provider that reports success yields "completed".
    def snapshot(volume:, name: nil, description: nil)
      validate_volume!(volume)

      return Runtime::Result.err(error: "Volume has no cloud volume ID") if volume.external_id.blank?

      adapter = resolve_adapter(volume)
      return adapter if adapter.is_a?(Runtime::Result)

      unless adapter.supports_volume_snapshots?
        return Runtime::Result.err(
          error: "Provider #{provider_label(volume)} does not support volume snapshots — this volume is not protected by snapshots"
        )
      end

      snapshot_name = name.presence || default_snapshot_name(volume)

      record = volume.account.system_provider_volume_snapshots.create!(
        name: snapshot_name,
        description: description,
        volume: volume,
        size_gb: volume.size_gb,
        encrypted: volume.encrypted,
        status: "creating",
        progress: 0
      )

      Rails.logger.info("[VolumeManagementService] Snapshotting volume #{volume.name} as #{snapshot_name}")

      result = adapter.create_volume_snapshot(volume.external_id,
                                              name: snapshot_name,
                                              description: description)

      if result[:success] && result[:snapshot_id].present?
        record.update!(status: "completed", progress: 100, external_id: result[:snapshot_id])
        Runtime::Result.ok(data: { snapshot: record.reload })
      elsif result[:success]
        # Success with no provider-side id is NOT a restore point: #can_restore?
        # would be true while #restore_snapshot could never run, which is the
        # fake-restore-point shape this whole seam exists to remove. The
        # BaseProvider contract promises :snapshot_id on success, so an adapter
        # that omits it is failing, not succeeding.
        record.update!(status: "error")
        Runtime::Result.err(
          error: "Provider #{provider_label(volume)} reported a snapshot but named no snapshot id — not recorded as a restore point"
        )
      else
        # An attempt that reached the provider and failed is recorded, not
        # erased: an operator investigating a missing restore point needs to
        # see that the platform tried.
        record.update!(status: "error")
        Runtime::Result.err(error: result[:error] || "Snapshot failed")
      end
    rescue ActiveRecord::RecordInvalid => e
      Runtime::Result.err(error: e.record.errors.full_messages.join(", "))
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      record&.update(status: "error")
      Runtime::Result.err(error: e.message)
    rescue StandardError => e
      # The sibling lifecycle methods all carry this arm. Without it a
      # timeout or an adapter NoMethodError strands the row in "creating" —
      # in_progress? forever, neither restorable nor (before this) deletable.
      Rails.logger.error("[VolumeManagementService] Snapshot failed: #{e.class}: #{e.message}")
      record&.update(status: "error")
      Runtime::Result.err(error: e.message)
    end

    # The DB rows are the platform's RECORD; the provider is the AUTHORITY on
    # whether a restore point still exists. A row whose provider-side snapshot
    # was deleted out-of-band is a fake restore point of exactly the kind this
    # increment removes, so `reconcile: true` asks the provider and reports
    # which rows it still holds.
    #
    # `reconciled: false` when the provider could not be asked (no adapter, no
    # snapshot support, or the listing call failed) — never a guess, and never
    # a claim that a missing row is present.
    def list_snapshots(volume:, reconcile: false)
      validate_volume!(volume)

      rows = volume.snapshots.recent.to_a
      return unreconciled(rows) unless reconcile

      adapter = resolve_adapter(volume)
      return unreconciled(rows) if adapter.is_a?(Runtime::Result) || !adapter.supports_volume_snapshots?

      listing = adapter.list_volume_snapshots(volume.external_id)
      return unreconciled(rows) unless listing[:success]

      provider_ids = Array(listing[:snapshots]).filter_map do |snap|
        (snap[:snapshot_id] || snap["snapshot_id"]).presence&.to_s
      end.to_set

      present = rows.each_with_object({}) do |row, acc|
        acc[row.id] = provider_ids.include?(row.external_id.to_s) if row.external_id.present?
      end

      Runtime::Result.ok(data: { snapshots: rows, reconciled: true, present_at_provider: present })
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.warn("[VolumeManagementService] Snapshot reconcile failed: #{e.message}")
      unreconciled(volume.snapshots.recent.to_a)
    rescue StandardError => e
      Rails.logger.warn("[VolumeManagementService] Snapshot reconcile failed: #{e.class}: #{e.message}")
      unreconciled(volume.snapshots.recent.to_a)
    end

    def delete_snapshot(snapshot:)
      validate_snapshot!(snapshot)

      volume = snapshot.volume
      # A snapshot whose volume row is gone, or that never reached a provider,
      # has nothing provider-side to remove — drop the row and say so. This is
      # checked BEFORE #can_delete? on purpose: the rows the old fabricating
      # endpoint minted are status "pending", which #can_delete? excludes, and
      # ProviderVolume has_many :snapshots is dependent: :restrict_with_error —
      # so a fake row that was never a restore point would otherwise block
      # deletion of its volume forever, at every surface.
      if volume.nil? || snapshot.external_id.blank?
        snapshot.destroy!
        return Runtime::Result.ok(data: { provider_deleted: false })
      end

      unless snapshot.can_delete?
        return Runtime::Result.err(error: "Snapshot cannot be deleted in status #{snapshot.status}")
      end

      adapter = resolve_adapter(volume)
      return adapter if adapter.is_a?(Runtime::Result)

      unless adapter.supports_volume_snapshots?
        return Runtime::Result.err(
          error: "Provider #{provider_label(volume)} does not support volume snapshots — refusing to drop the row while the provider-side snapshot may still exist"
        )
      end

      snapshot.update!(status: "deleting")
      result = adapter.delete_volume_snapshot(snapshot.external_id)

      if result[:success]
        snapshot.destroy!
        Runtime::Result.ok(data: { provider_deleted: true })
      else
        # Back to a state #can_delete? admits, so a retry is possible.
        snapshot.update!(status: "error")
        Runtime::Result.err(error: result[:error] || "Snapshot delete failed")
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    # Restore from this snapshot, per the provider's declared restore MODE.
    #
    # Two genuinely different outcomes, and the result says WHICH:
    #   :in_place — the volume itself is rolled back. DESTRUCTIVE: every write
    #               since the snapshot is discarded.
    #   :copy     — the provider creates a NEW volume from the snapshot and
    #               leaves the source untouched (Azure). Nothing is discarded,
    #               and the restored data is only reachable through the copy —
    #               so the copy is RECORDED as a ProviderVolume here. Without
    #               that row it is unattachable and undeletable through the
    #               platform: an untracked, billable orphan, while every
    #               surface above reports the source volume as restored.
    #
    # `restored_in_place` and `restored_volume` in the payload are what callers
    # must report on; "restored" said of the source volume is false on a :copy
    # provider.
    #
    # `swap_into_place` (IMP-e025722ef14e) is OPT-IN and applies to the :copy
    # outcome only: after the copy is recorded, detach the source from its
    # instance and attach the copy at the same device, so the instance runs on
    # the restored disk. Off by default because it detaches a live disk. The
    # result reports `swapped` (true/false) and, when nothing was swapped
    # because there was nothing to swap out of, `swap_skipped` says why. A
    # swap that fails MIDWAY is a FAILURE that names the stage (`swap_stage`)
    # and the state it left — never a success with a footnote.
    def restore_snapshot(snapshot:, swap_into_place: false)
      # CAST AT THE SHARED BOUNDARY, not at each door. Every caller above this
      # one carries untyped JSON — an MCP argument, a skill input, a
      # controller param — and the string "false" is truthy in Ruby, so an
      # uncast door would detach a live disk for a caller that said NO in the
      # only vocabulary it has. This is the one boundary all of them pass
      # through.
      swap = ::ActiveModel::Type::Boolean.new.cast(swap_into_place) == true
      validate_snapshot!(snapshot)

      unless snapshot.can_restore?
        return Runtime::Result.err(
          error: "Snapshot #{snapshot.name} cannot be restored — status is #{snapshot.status}, only a completed snapshot is a restore point"
        )
      end

      volume = snapshot.volume
      return Runtime::Result.err(error: "Snapshot has no volume to restore onto") if volume.nil?
      return Runtime::Result.err(error: "Snapshot has no provider-side id") if snapshot.external_id.blank?

      adapter = resolve_adapter(volume)
      return adapter if adapter.is_a?(Runtime::Result)

      unless adapter.supports_volume_snapshots?
        return Runtime::Result.err(
          error: "Provider #{provider_label(volume)} does not support volume snapshots — no restore path exists for this volume"
        )
      end

      mode = adapter.volume_snapshot_restore_mode
      unless RESTORE_MODES.include?(mode)
        return Runtime::Result.err(
          error: "Provider #{provider_label(volume)} can snapshot but declares no restore primitive — this snapshot is not a recoverable restore point"
        )
      end

      Rails.logger.info("[VolumeManagementService] Restoring volume #{volume.name} from snapshot #{snapshot.name} (#{mode})")

      result = adapter.restore_volume_snapshot(snapshot.external_id, volume_id: volume.external_id)
      return Runtime::Result.err(error: result[:error] || "Restore failed") unless result[:success]

      if mode == :in_place
        return with_swap_skipped(restored_in_place(volume: volume, snapshot: snapshot),
                                 swap, "restored in place — the source volume itself holds the restored data")
      end

      recorded = record_restored_copy(volume: volume, snapshot: snapshot, result: result)
      return recorded unless recorded.success?
      return with_swap_skipped(recorded, false, nil) unless swap

      swap_restored_copy_into_place(source: volume, recorded: recorded)
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Restore failed: #{e.class}: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def snapshot_schedule_for(mission:, now: Time.current)
      raise ArgumentError, "Mission required" unless mission
      raise ArgumentError, "Mission must be an Ai::Mission" unless mission.is_a?(::Ai::Mission)

      policy = mission.snapshot_policy
      schedule = SnapshotSchedule.new(mission: mission, policy: policy, due: [], prunable: [])
      return schedule unless policy.scheduled? || policy.prunes?

      mission_volumes(mission).each do |volume|
        # Newest first, off the eager-loaded association (one query for every
        # volume's snapshots, not one per volume). Two kinds of row count: a
        # COMPLETED one that reached the provider (the only restore point),
        # and a CREATING one (in flight — the provider id lands on
        # completion). The legacy "pending" rows APO-5 found, and a completed
        # row with no provider id, are restore points of nothing and are not
        # read at all; an "error" row is a failed attempt and satisfies
        # nothing either.
        rows = volume.snapshots.to_a
                     .select { |r| r.creating? || (r.completed? && r.external_id.present?) }
                     .sort_by(&:created_at).reverse
        completed = rows.select(&:completed?)

        if policy.scheduled? && snapshot_due?(rows, policy, now)
          schedule.due << { volume: volume, mission: mission,
                            interval_hours: policy.interval_hours,
                            last_snapshot_at: completed.first&.created_at }
        end

        next unless policy.prunes? && completed.size > policy.retention_count

        # Beyond retention, OLDEST first: the operator approving a prune sees
        # the least valuable restore point at the top.
        completed.drop(policy.retention_count).reverse_each do |snap|
          schedule.prunable << { snapshot: snap, volume: volume, mission: mission,
                                 retention_count: policy.retention_count }
        end
      end

      schedule
    end

    private

    def validate_volume!(volume)
      raise ArgumentError, "Volume required" unless volume
      raise ArgumentError, "Volume must be a System::ProviderVolume" unless volume.is_a?(::System::ProviderVolume)
    end

    def validate_snapshot!(snapshot)
      raise ArgumentError, "Snapshot required" unless snapshot
      unless snapshot.is_a?(::System::ProviderVolumeSnapshot)
        raise ArgumentError, "Snapshot must be a System::ProviderVolumeSnapshot"
      end
    end

    # Returns the adapter, or a Runtime::Result the caller passes straight
    # through — the same rescue the other lifecycle methods do inline.
    def resolve_adapter(volume)
      Providers::Registry.for_volume(volume)
    rescue Providers::Registry::UnknownProviderError => e
      Runtime::Result.err(error: e.message)
    end

    def provider_label(volume)
      volume.provider_region&.provider&.provider_type.presence || "unknown"
    end

    def default_snapshot_name(volume)
      "#{volume.name}-snapshot-#{Time.current.strftime('%Y%m%d%H%M%S')}"
    end

    def unreconciled(rows)
      Runtime::Result.ok(data: { snapshots: rows, reconciled: false, present_at_provider: {} })
    end

    def restored_in_place(volume:, snapshot:)
      Runtime::Result.ok(data: { volume: volume.reload, snapshot: snapshot,
                                 restored_in_place: true, restored_volume: volume,
                                 restored_volume_id: volume.external_id })
    end

    # The provider made a new volume; the platform records it so it can be
    # attached and, later, deleted. A copy the platform does not know about is
    # worse than no restore: it costs money, cannot be attached (every attach
    # surface resolves a ProviderVolume) and nothing above ever learns the
    # source was not the thing restored.
    def record_restored_copy(volume:, snapshot:, result:)
      provider_volume_id = result[:volume_id].presence
      unless provider_volume_id
        return Runtime::Result.err(
          error: "Provider #{provider_label(volume)} restored by copy but named no volume — the restored data cannot be located"
        )
      end

      copy = volume.account.system_provider_volumes.create!(
        name: unique_restored_name(volume, snapshot),
        description: "Restored from snapshot #{snapshot.name} of volume #{volume.name}",
        size_gb: result[:size_gb].presence || snapshot.size_gb || volume.size_gb,
        status: "available",
        encrypted: volume.encrypted,
        external_id: provider_volume_id,
        volume_type_id: volume.volume_type_id,
        provider_region_id: volume.provider_region_id,
        availability_zone_id: volume.availability_zone_id
      )

      Runtime::Result.ok(data: { volume: volume.reload, snapshot: snapshot,
                                 restored_in_place: false, restored_volume: copy,
                                 restored_volume_id: provider_volume_id })
    rescue ActiveRecord::RecordInvalid => e
      # The provider-side disk EXISTS. Naming it in the error is the only way an
      # operator can reconcile it by hand instead of paying for an orphan.
      Runtime::Result.err(
        error: "Restore created provider volume #{provider_volume_id} but the platform could not record it " \
               "(#{e.record.errors.full_messages.join(', ')}) — reconcile it manually"
      )
    end

    # The swap. Reuses THIS service's #detach / #attach — the same provider
    # calls and the same row transitions every other surface makes — so the
    # swap cannot drift from an ordinary detach-then-attach. Both halves are
    # reported on failure with the state they left, because the two failure
    # modes leave the instance in DIFFERENT places: a detach failure leaves it
    # running on the source; an attach failure leaves it with NO disk at that
    # device and two unattached volumes.
    def swap_restored_copy_into_place(source:, recorded:)
      copy = recorded.data[:restored_volume]
      unless source.attached?
        return with_swap_skipped(recorded, true,
                                 "source volume #{source.name} is not attached — nothing to swap out of; attach #{copy.name} where it is needed")
      end

      instance = source.node_instance
      device   = source.device_name
      if instance.nil?
        return with_swap_skipped(recorded, true,
                                 "source volume #{source.name} names an instance that no longer exists — nothing to swap onto; attach #{copy.name} where it is needed")
      end

      detached = detach(volume: source)
      unless detached.success?
        return Runtime::Result.err(
          error: "Restored copy #{copy.name} is recorded but the swap failed at detach " \
                 "(#{detached.error}); #{source.name} is still attached to #{instance.name}",
          data: recorded.data.merge(swapped: false, swap_stage: "detach")
        )
      end

      # A PROVIDER-SIDE DETACH IS NOT A ROW RELEASE. ProviderVolume#detach! is
      # a no-op returning false unless the row is `in-use` AND attached, and
      # #detach drops that return value — so a source whose status drifted off
      # "in-use" (a health check writes the provider's status verbatim without
      # touching node_instance_id) keeps its instance and device here. This
      # swap's own precondition is `attached?`, strictly weaker than
      # `can_detach?`, so the release is VERIFIED rather than assumed:
      # attaching the copy at that same device would otherwise record two
      # volumes on one instance/device.
      if source.reload.node_instance_id.present?
        return Runtime::Result.err(
          error: "Restored copy #{copy.name} is recorded but the swap failed at detach — " \
                 "#{source.name} still holds #{instance.name}:#{device} " \
                 "(status #{source.status}); attach #{copy.name} by hand once #{source.name} is released",
          data: recorded.data.merge(volume: source, swapped: false, swap_stage: "detach")
        )
      end

      attached = attach(volume: copy, instance: instance, device: device)
      unless attached.success?
        return Runtime::Result.err(
          error: "Restored copy #{copy.name} is recorded but the swap failed at attach " \
                 "(#{attached.error}); #{source.name} is now DETACHED from #{instance.name} and " \
                 "#{copy.name} is unattached — attach one of them by hand",
          data: recorded.data.merge(volume: source.reload, swapped: false, swap_stage: "attach")
        )
      end

      Rails.logger.info("[VolumeManagementService] Swapped restored copy #{copy.name} into #{source.name}'s place on #{instance.name}")
      Runtime::Result.ok(data: recorded.data.merge(volume: source.reload, restored_volume: copy.reload,
                                                   swapped: true, swapped_instance_id: instance.id,
                                                   swapped_device: attached.data[:device]))
    end

    # `swapped: false` on every path that did not swap, so a caller reading
    # the key never has to distinguish "false" from "absent"; `swap_skipped`
    # names the reason only when a swap was ASKED for.
    def with_swap_skipped(result, requested, reason)
      # Never launder a failure into a success with a footnote: this rebuilds
      # its input as `ok`, so a failing result must pass straight through.
      return result unless result.success?

      data = { swapped: false }
      data[:swap_skipped] = reason if requested
      Runtime::Result.ok(data: result.data.merge(data))
    end

    # The volumes a project protects: those attached to the instances its
    # provisioning plan recorded, that reached a provider and can be
    # snapshotted. `resolvable_instance_ids` is the collector's own private
    # walk; it is reused deliberately rather than copied (see the class-level
    # comment) — promoting it to public API is the collector's to do.
    def mission_volumes(mission)
      instance_ids = ::System::ProjectMetricsCollector.new(mission: mission).send(:resolvable_instance_ids)
      return [] if instance_ids.blank?

      ::System::ProviderVolume
        .includes(:snapshots)
        .where(account_id: mission.account_id, node_instance_id: instance_ids)
        .where.not(external_id: [ nil, "" ])
        .order(:created_at)
        .select(&:can_snapshot?)
    end

    # Due when no snapshot has ever reached the provider, or the newest one
    # that is either COMPLETED or still IN FLIGHT is older than the interval.
    # An in-flight row younger than the interval is not "missing" — issuing
    # another would double the provider's work for the same restore point —
    # while an errored attempt satisfies nothing: it is not a restore point.
    def snapshot_due?(rows, policy, now)
      latest = rows.first
      return true if latest.nil?

      latest.created_at <= now - policy.interval_hours.hours
    end

    def unique_restored_name(volume, snapshot)
      base = "#{volume.name}-restored-#{Time.current.strftime('%Y%m%d%H%M%S')}"
      scope = volume.account.system_provider_volumes
      return base unless scope.where("LOWER(name) = ?", base.downcase).exists?

      (2..99).each do |n|
        candidate = "#{base}-#{n}"
        return candidate unless scope.where("LOWER(name) = ?", candidate.downcase).exists?
      end

      "#{base}-#{snapshot.id}"
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_region!(region)
      raise ArgumentError, "Region required" unless region
      raise ArgumentError, "Region must be a System::ProviderRegion" unless region.is_a?(::System::ProviderRegion)
    end

    def next_available_device(instance)
      existing = ::System::ProviderVolume.where(node_instance: instance).pluck(:device_name)

      ("b".."z").each do |letter|
        device = "/dev/sd#{letter}"
        return device unless existing.include?(device)
      end

      raise VolumeError, "No available device paths"
    end
  end
end
