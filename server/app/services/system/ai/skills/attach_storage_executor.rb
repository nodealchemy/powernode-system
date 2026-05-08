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
      class AttachStorageExecutor
        DEFAULT_MOUNT_POINT = "/data"
        MIN_GB = 1
        MAX_GB = 16_384

        def self.descriptor
          {
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
            requires_approval: false,
            blast_radius: :low
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(instance_id:, size_gb:, volume_type: nil,
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
        rescue StandardError => e
          Rails.logger.error("[AttachStorageExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

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

          attach_result = ::System::VolumeManagementService.attach(volume: volume, instance: instance)
          unless attach_result.success?
            failures << { step: "attach_volume", volume_id: volume.id, error: attach_result.error }
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

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
