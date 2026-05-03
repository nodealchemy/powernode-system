# frozen_string_literal: true

module Api
  module V1
    module System
      class NodePlatformsController < BaseController
        before_action :set_account
        before_action :set_platform, only: [:show, :update, :destroy]

        def index
          require_permission("system.platforms.read")
          platforms = @account.system_node_platforms.includes(:node_architecture)
          platforms = apply_filters(platforms)
          platforms = paginate(platforms)
          render_success(node_platforms: serialize_collection(platforms), meta: pagination_meta)
        end

        def show
          require_permission("system.platforms.read")
          render_success(node_platform: serialize_platform(@platform))
        end

        def create
          require_permission("system.platforms.create")
          platform = @account.system_node_platforms.build(platform_params)

          if platform.save
            render_success(node_platform: serialize_platform(platform), status: :created)
          else
            render_validation_error(platform)
          end
        end

        def update
          require_permission("system.platforms.update")

          if @platform.update(platform_params)
            render_success(node_platform: serialize_platform(@platform))
          else
            render_validation_error(@platform)
          end
        end

        def destroy
          require_permission("system.platforms.delete")

          if @platform.destroy
            render_success(message: "Platform deleted successfully")
          else
            render_error("Failed to delete platform", status: :unprocessable_entity)
          end
        end

        # GET /api/v1/system/node_platforms/:id/disk_image
        # Returns a signed download URL for the generic disk image
        # built by CI for this platform. Operators flash the .img onto
        # an SD card / USB stick to provision physical devices via the
        # claim flow. See plan wondrous-yawning-anchor.md.
        def disk_image
          require_permission("system.platforms.read")
          @platform = @account.system_node_platforms.find(params[:id])

          if @platform.disk_image_file_object_id.blank?
            return render_error(
              "No disk image built for this platform yet. Trigger the build-disk-image workflow first.",
              :not_found
            )
          end

          file_object = ::FileManagement::Object.find_by(id: @platform.disk_image_file_object_id)
          return render_not_found("disk image file object") unless file_object

          url = ::FileStorageService.new(@account).file_url(
            file_object, signed: true, expires_in: 1.hour, disposition: "attachment"
          )

          # Audit-log every download via FleetEvent so the operator dashboard
          # has visibility into who pulled what (these images carry the
          # platform's CA bundle and become first-boot trust anchors).
          if defined?(::System::Fleet::EventBroadcaster)
            ::System::Fleet::EventBroadcaster.emit!(
              account: @account,
              kind: "system.disk_image_downloaded",
              severity: :low,
              source: "operator_ui",
              payload: {
                platform_id:   @platform.id,
                platform_name: @platform.name,
                by_user_id:    current_user&.id,
                sha256:        @platform.disk_image_sha256
              }
            )
          end

          render_success(
            url: url,
            expires_at: 1.hour.from_now,
            sha256: @platform.disk_image_sha256,
            size_bytes: @platform.disk_image_size_bytes,
            built_at: @platform.disk_image_built_at,
            filename: "powernode-#{@platform.name}.img"
          )
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Platform")
        end

        private

        def set_platform
          @platform = @account.system_node_platforms.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Platform")
        end

        def platform_params
          params.require(:node_platform).permit(
            :name, :description, :enabled, :public, :node_architecture_id,
            :build_script, :init_script, :sync_script
          )
        end

        def apply_filters(scope)
          scope = scope.enabled if params[:enabled] == "true"
          scope = scope.disabled if params[:enabled] == "false"
          scope = scope.public_access if params[:public] == "true"
          scope = scope.where(node_architecture_id: params[:architecture_id]) if params[:architecture_id].present?
          scope.ordered
        end

        def serialize_platform(platform)
          ::System::NodePlatformSerializer.new(platform).as_json
        end

        def serialize_collection(platforms)
          platforms.map { |p| serialize_platform(p) }
        end
      end
    end
  end
end
