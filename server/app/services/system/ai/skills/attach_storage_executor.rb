# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — attach a freshly-provisioned cloud volume
      # to a running NodeInstance and mount it at the requested path.
      # Composition shape:
      #
      #   VolumeManagementService.provision    (create the cloud volume)
      #     → VolumeManagementService.attach   (associate volume + instance)
      #     → SshExecutionService.execute      (mkfs.ext4 + mkdir + mount + fstab)
      #
      # Returns the standard {dry_run, count, planned_actions, outputs,
      # failures, partial} envelope so the runner can dispatch rollback
      # uniformly. Outputs contain `storage_volume_ids` (so rollback knows
      # which volumes to delete) and a `mount` sub-hash with the device +
      # mount_point for observability.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
      class AttachStorageExecutor < BaseSkillExecutor
        DEFAULT_MOUNT_POINT = "/data"
        MIN_GB = 1
        MAX_GB = 16_384

        skill_descriptor(
          name: "attach_storage",
          description: "Provision a cloud volume, attach it to a running NodeInstance, and mount it at the requested path. Composes VolumeManagementService.provision/attach + SshExecutionService for filesystem setup.",
          category: "devops",
          inputs: {
            instance_id: { type: "string", required: true,
                           description: "System::NodeInstance to attach the volume to" },
            size_gb: { type: "integer", required: true,
                       description: "Volume size in GiB (#{MIN_GB}-#{MAX_GB})" },
            volume_type: { type: "string", required: false,
                           description: "Optional ProviderVolumeType name (e.g. 'gp3'); falls back to provider default when nil" },
            mount_point: { type: "string", required: false, default: DEFAULT_MOUNT_POINT,
                           description: "Filesystem mount path on the instance" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no volume creation, no SSH" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            planned_actions: [ :object ],
            outputs: {
              node_instance_ids: [ :string ],
              storage_volume_ids: [ :string ],
              mount: :object
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_attach_storage,
          blast_radius: :low
        )

        # HIER-P2SWEEP (driver ruling 2026-09-03): bound to the CAPACITY
        # Manager, not the Storage Manager and no longer Fleet Autonomy. This
        # executor runs DURING PROVISIONING — it is the provisioning mission's
        # adaptive-evolution step (Ai::Provisioning::AdaptationProposerService;
        # seeded by system_provisioning_skills_seed.rb under the `provisioning`
        # subdomain) — and the Capacity Manager owns the provisioning step
        # (PROVISIONING_POLICIES, scale_project, provision_full_stack). The
        # Storage Manager owns the volume DATA plane (restore, snapshot delete,
        # assignment reconcile), which a fresh attach is not. Fleet Autonomy
        # declares no provisioning category since HIER-P2DECL, so a binding
        # there would resolve any future gate against an agent that owns
        # nothing this executor does.
        binds_to "capacity_manager"

        # Rollback contract: detach (best-effort) and delete the volume(s).
        # node_instance_ids is forwarded by the runner but ignored — we do
        # NOT terminate the host instance during a storage rollback.
        def rollback_attach_storage(storage_volume_ids: [], **_extras)
          errors = []

          Array(storage_volume_ids).reverse_each do |volume_id|
            volume = ::System::ProviderVolume.find_by(id: volume_id)
            next unless volume

            detach_result = ::System::VolumeManagementService.detach(volume: volume)
            unless detach_result.success?
              # Soft-fail on detach: still attempt delete (some providers
              # auto-detach on delete; the operator audit log captures this).
              Rails.logger.warn("[AttachStorageExecutor] detach failed for volume #{volume_id}: #{detach_result.error}")
            end

            del_result = ::System::VolumeManagementService.delete(volume: volume)
            errors << { resource: "provider_volume", id: volume_id, error: del_result.error } unless del_result.success?
          rescue StandardError => e
            errors << { resource: "provider_volume", id: volume_id, error: e.message }
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(instance_id:, size_gb:, volume_type: nil,
                    mount_point: DEFAULT_MOUNT_POINT, dry_run: false, **_extras)
          size = size_gb.to_i
          return failure("size_gb must be between #{MIN_GB} and #{MAX_GB}") unless size.between?(MIN_GB, MAX_GB)

          mount = (mount_point || DEFAULT_MOUNT_POINT).to_s
          return failure("mount_point must be an absolute path") unless mount.start_with?("/")

          instance = ::System::NodeInstance.joins(:node)
                                           .where(system_nodes: { account_id: @account.id })
                                           .find_by(id: instance_id)
          return failure("instance not found: #{instance_id}") unless instance

          region = instance.provider_region
          return failure("instance has no provider_region — cannot place volume") if region.nil?

          volume_type_record = nil
          if volume_type.present?
            volume_type_record = lookup_volume_type(volume_type)
            return failure("volume_type not found: #{volume_type}") unless volume_type_record
          end

          if dry_run
            return success(
              dry_run: true,
              count: 1,
              planned_actions: build_plan(instance: instance, size: size,
                                          volume_type: volume_type, mount: mount),
              outputs: { node_instance_ids: [], storage_volume_ids: [],
                         mount: { instance_id: instance.id, mount_point: mount, device: nil } },
              failures: [],
              partial: false
            )
          end

          run_execute(instance: instance, region: region, volume_type: volume_type_record,
                      size: size, mount: mount)
        end

        private

        def run_execute(instance:, region:, volume_type:, size:, mount:)
          planned_actions = []
          failures = []
          storage_volume_ids = []
          device = nil

          prov_result = ::System::VolumeManagementService.provision(
            account: @account, region: region, volume_type: volume_type,
            size_gb: size, options: { name: "#{instance.name}-#{mount.tr('/', '-')}".gsub(/-+/, "-").gsub(/\A-|-\z/, "") }
          )
          unless prov_result.success?
            failures << { step: "provision_volume", error: prov_result.error }
            return finalize(planned_actions: planned_actions, storage_volume_ids: storage_volume_ids,
                            instance_id: instance.id, mount: mount, device: nil, failures: failures)
          end

          volume = prov_result.data[:volume]
          storage_volume_ids << volume.id
          planned_actions << { step: "provision_volume", volume_id: volume.id, size_gb: size }

          # IMP-0d9e7ca7b166 (sibling of the ProvisionFullStackExecutor fix) —
          # a raise here escapes to BaseSkillExecutor#execute, which returns a
          # BARE failure(msg) carrying no ids. rollback_step! therefore fires
          # with EMPTY kwargs and reclaims nothing, so reclaim first, then
          # re-raise, keeping the step honestly a failure.
          #
          # IMP-2182fd8fcdee note: the runner no longer reads rollback kwargs
          # ONLY from metadata["last_outputs"] — handle_failure now also
          # records a failing envelope's own outputs into
          # metadata["failure_outputs"]. That does not help HERE, because the
          # envelope this path produces is synthesised by the rescue in
          # #execute from an exception message and has no ids in it. The
          # in-branch reclaim stays load-bearing.
          begin
            attach_result = ::System::VolumeManagementService.attach(volume: volume, instance: instance)
          rescue StandardError
            reclaim_unattachable_volume!(volume: volume, instance: instance, failures: failures,
                                         storage_volume_ids: storage_volume_ids,
                                         planned_actions: planned_actions)
            raise
          end

          unless attach_result.success?
            failures << { step: "attach_volume", volume_id: volume.id, error: attach_result.error }
            # #finalize ALWAYS returns success(), so the runner marks this step
            # completed and never dispatches rollback_attach_storage — which
            # holds this very id. With node_instance_id nil the volume is also
            # invisible to the scale-in teardown and its orphan sweep, both of
            # which key on that FK. Nothing else can reach it, so reclaim here.
            reclaim_unattachable_volume!(volume: volume, instance: instance, failures: failures,
                                         storage_volume_ids: storage_volume_ids,
                                         planned_actions: planned_actions)
            return finalize(planned_actions: planned_actions, storage_volume_ids: storage_volume_ids,
                            instance_id: instance.id, mount: mount, device: nil, failures: failures)
          end

          device = attach_result.data&.dig(:device)
          planned_actions << { step: "attach_volume", volume_id: volume.id,
                               instance_id: instance.id, device: device }

          ssh_result = ::System::SshExecutionService.execute(
            instance: instance,
            command: build_mount_command(device: device, mount_point: mount),
            sudo: true
          )
          if ssh_result.success?
            planned_actions << { step: "mount_filesystem", instance_id: instance.id,
                                 device: device, mount_point: mount }
          else
            failures << { step: "mount_filesystem", instance_id: instance.id, error: ssh_result.error }
          end

          finalize(planned_actions: planned_actions, storage_volume_ids: storage_volume_ids,
                   instance_id: instance.id, mount: mount, device: device, failures: failures)
        end

        # Delete a volume this step provisioned but could not attach, and stop
        # advertising it. Deliberately the same shape as
        # ProvisionFullStackExecutor#reclaim_unattachable_volume! — the two are
        # separate methods on separate executors, so the parity is stated
        # rather than shared, matching how this file already treats its
        # rollback ordering.
        #
        # A FAILED reclaim records its own failure and KEEPS the id: if the row
        # survives, the envelope must still name it, or the guard just moves
        # the leak somewhere quieter. A SUCCESSFUL one is recorded as an action,
        # because a silent delete leaves no account of what became of the volume.
        def reclaim_unattachable_volume!(volume:, instance:, failures:, storage_volume_ids:,
                                         planned_actions:)
          if volume.attached?
            detach = ::System::VolumeManagementService.detach(volume: volume)
            unless detach.success?
              failures << { step: "reclaim_volume", instance_id: instance.id,
                            volume_id: volume.id, error: detach.error }
              return false
            end
          end

          result = ::System::VolumeManagementService.delete(volume: volume)
          if result.success?
            storage_volume_ids.delete(volume.id)
            planned_actions << { step: "reclaim_volume", instance_id: instance.id,
                                 volume_id: volume.id }
            true
          else
            failures << { step: "reclaim_volume", instance_id: instance.id,
                          volume_id: volume.id, error: result.error }
            false
          end
        rescue StandardError => e
          failures << { step: "reclaim_volume", instance_id: instance.id,
                        volume_id: volume.id, error: e.message }
          false
        end

        def finalize(planned_actions:, storage_volume_ids:, instance_id:, mount:, device:, failures:)
          success(
            dry_run: false,
            count: 1,
            planned_actions: planned_actions,
            outputs: {
              node_instance_ids: [],
              storage_volume_ids: storage_volume_ids,
              mount: { instance_id: instance_id, mount_point: mount, device: device }
            },
            failures: failures,
            partial: failures.any? && storage_volume_ids.any?
          )
        end

        def build_plan(instance:, size:, volume_type:, mount:)
          [
            { step: "provision_volume", size_gb: size, volume_type: volume_type, region_id: instance_region_id_safe(instance) },
            { step: "attach_volume", instance_id: instance.id },
            { step: "mount_filesystem", instance_id: instance.id, mount_point: mount }
          ]
        end

        def build_mount_command(device:, mount_point:)
          dev = device.presence || "/dev/sdf"
          mp  = mount_point
          # mkfs only if the device is unformatted; mount idempotently;
          # persist via fstab so survive reboot. The actual on-instance
          # path uses `blkid` to detect a pre-existing FS.
          [
            "set -e",
            "mkdir -p #{mp}",
            "if ! blkid #{dev} >/dev/null 2>&1; then mkfs.ext4 -F #{dev}; fi",
            "mount #{dev} #{mp} || true",
            "grep -q '#{dev} #{mp}' /etc/fstab || echo '#{dev} #{mp} ext4 defaults,nofail 0 2' >> /etc/fstab"
          ].join(" && ")
        end

        def instance_region_id_safe(instance)
          instance.provider_region&.id
        end

        def lookup_volume_type(name)
          ::System::ProviderVolumeType.where(account_id: @account.id).find_by(name: name)
        end
      end
    end
  end
end
