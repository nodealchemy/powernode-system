# frozen_string_literal: true

module Api
  module V1
    module System
      class ProviderVolumesController < BaseController
        before_action :set_volume, only: [ :show, :update, :destroy, :attach, :detach, :snapshot, :snapshots, :restore ]

        # GET /api/v1/system/provider_volumes
        def index
          require_permission("system.volumes.read")

          volumes = current_account.system_provider_volumes
          volumes = apply_filters(volumes)
          volumes = paginate(volumes.includes(:volume_type, :provider_region, :node_instance).by_name)

          render_success(
            volumes: volumes.map { |v| ::System::ProviderVolumeSerializer.new(v).as_json },
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/provider_volumes/:id
        def show
          require_permission("system.volumes.read")
          render_success(volume: ::System::ProviderVolumeSerializer.new(@volume).as_json)
        end

        # POST /api/v1/system/provider_volumes
        def create
          require_permission("system.volumes.create")

          volume = current_account.system_provider_volumes.build(volume_params)

          if volume.save
            render_success(volume: ::System::ProviderVolumeSerializer.new(volume).as_json, status: :created)
          else
            render_validation_error(volume)
          end
        end

        # PATCH/PUT /api/v1/system/provider_volumes/:id
        def update
          require_permission("system.volumes.update")

          if @volume.update(volume_params)
            render_success(volume: ::System::ProviderVolumeSerializer.new(@volume).as_json)
          else
            render_validation_error(@volume)
          end
        end

        # DELETE /api/v1/system/provider_volumes/:id
        def destroy
          require_permission("system.volumes.delete")

          unless @volume.can_delete?
            return render_error("Cannot delete volume in current state", status: :unprocessable_content)
          end

          @volume.update!(status: "deleting")
          render_success(message: "Volume deletion initiated")
        end

        # POST /api/v1/system/provider_volumes/:id/attach
        def attach
          require_permission("system.volumes.update")

          instance = current_account.system_nodes
                                   .flat_map(&:node_instances)
                                   .find { |i| i.id == params[:node_instance_id] }

          unless instance
            return render_error("Node instance not found", status: :not_found)
          end

          if @volume.attach_to!(instance, params[:device_name])
            render_success(volume: ::System::ProviderVolumeSerializer.new(@volume.reload).as_json)
          else
            render_error("Cannot attach volume in current state", status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/provider_volumes/:id/detach
        def detach
          require_permission("system.volumes.update")

          if @volume.detach!
            render_success(volume: ::System::ProviderVolumeSerializer.new(@volume.reload).as_json)
          else
            render_error("Cannot detach volume in current state", status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/provider_volumes/:id/snapshot
        #
        # APO-5 / DR-2. This used to INSERT a "pending" row and return 201
        # without asking any provider anything — so the row an operator read
        # as a restore point was evidence of nothing. It now goes through
        # System::VolumeManagementService, which refuses on a provider with no
        # snapshot primitive and records "error" (never "completed") when the
        # provider call fails.
        def snapshot
          require_permission("system.volumes.snapshot")

          unless @volume.can_snapshot?
            return render_error("Cannot create snapshot in current state", status: :unprocessable_content)
          end

          result = ::System::VolumeManagementService.snapshot(
            volume: @volume, name: params[:name].presence, description: params[:description].presence
          )

          unless result.success?
            return render_error(result.error, status: :unprocessable_content)
          end

          render_success(
            snapshot: ::System::ProviderVolumeSnapshotSerializer.new(result.data[:snapshot]).as_json,
            status: :created
          )
        end

        # GET /api/v1/system/provider_volumes/:id/snapshots
        def snapshots
          require_permission("system.volumes.read")

          snaps = paginate(@volume.snapshots.recent)
          render_success(
            snapshots: snaps.map { |s| ::System::ProviderVolumeSnapshotSerializer.new(s).as_json },
            meta: pagination_meta
          )
        end

        # POST /api/v1/system/provider_volumes/:id/restore
        #
        # system.volumes.manage rather than .update — it is the broadest volume
        # grant, and this is the broadest thing that can be done to a volume's
        # contents.
        #
        # `restored_in_place` is the field a caller must read. TRUE: this volume
        # was rolled back and every write since the snapshot is DISCARDED.
        # FALSE: the provider copied the snapshot into a NEW volume (returned as
        # `restored_volume`) and THIS VOLUME IS UNCHANGED — rendering 200 with
        # only the source volume would tell an operator their data was restored
        # when it is sitting in a different disk.
        def restore
          require_permission("system.volumes.manage")

          snap = current_account.system_provider_volume_snapshots
                                .find_by(id: params[:snapshot_id], volume_id: @volume.id)
          return render_error("Snapshot not found for this volume", status: :not_found) unless snap

          # `swap_into_place` (IMP-e025722ef14e) — REST parity with the MCP
          # verb and the restore_volume executor. Copy-restore only: detach
          # the source from its instance and attach the copy at the same
          # device. The service casts it at its own boundary, so an untyped
          # param cannot opt in by accident; `swapped` is rendered on every
          # SUCCESS path (false when nothing was swapped) and `swap_skipped`
          # names the reason only when a swap was asked for. The FAILURE path
          # is #render_restore_error below — permitting the swap here is what
          # made it reachable.
          swap = ::ActiveModel::Type::Boolean.new.cast(params[:swap_into_place]) == true
          result = ::System::VolumeManagementService.restore_snapshot(snapshot: snap, swap_into_place: swap)

          return render_restore_error(result) unless result.success?

          restored = result.data[:restored_volume]
          render_success(
            volume: ::System::ProviderVolumeSerializer.new(@volume.reload).as_json,
            restored_in_place: result.data[:restored_in_place],
            restored_volume: restored ? ::System::ProviderVolumeSerializer.new(restored).as_json : nil,
            restored_from: ::System::ProviderVolumeSnapshotSerializer.new(snap).as_json,
            swapped: result.data[:swapped] == true,
            swap_skipped: result.data[:swap_skipped],
            swapped_instance_id: result.data[:swapped_instance_id],
            swapped_device: result.data[:swapped_device]
          )
        end

        private

        # A restore that failed AFTER the provider made a copy — a swap that
        # stopped at detach or attach — must not lose the copy: without its id
        # the operator holds a billable, unattached disk they cannot find.
        # Mirrors SystemFleetTool#restore_error_result on the MCP door. The
        # envelope stays an error (the request was not completed) and carries
        # what exists; a failure that created nothing renders plain, so
        # `details` never names a volume that does not exist.
        def render_restore_error(result)
          data = result.data.is_a?(Hash) ? result.data : {}
          copy = data[:restored_volume]
          return render_error(result.error, status: :unprocessable_content) unless copy

          render_error(
            result.error,
            status: :unprocessable_content,
            details: {
              restored_in_place: data[:restored_in_place],
              restored_volume: ::System::ProviderVolumeSerializer.new(copy).as_json,
              restored_volume_id: data[:restored_volume_id] || copy.id,
              swapped: data[:swapped] == true,
              swap_stage: data[:swap_stage]
            }
          )
        end

        def set_volume
          @volume = current_account.system_provider_volumes.find(params[:id])
        end

        def volume_params
          params.require(:volume).permit(
            :name, :description, :size_gb, :iops, :throughput,
            :device_name, :encrypted, :delete_on_termination,
            :volume_type_id, :provider_region_id, :availability_zone_id,
            config: {}
          )
        end

        def apply_filters(volumes)
          volumes = volumes.by_status(params[:status]) if params[:status].present?
          volumes = volumes.attached if params[:attached] == "true"
          volumes = volumes.unattached if params[:attached] == "false"
          volumes = volumes.encrypted_volumes if params[:encrypted] == "true"
          volumes = volumes.where("name ILIKE ?", "%#{params[:search]}%") if params[:search].present?
          volumes
        end
      end
    end
  end
end
