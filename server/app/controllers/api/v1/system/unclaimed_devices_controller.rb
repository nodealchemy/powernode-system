# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for the unclaimed-devices queue.
      #
      # Index lists devices currently polling /node_api/claim that the
      # operator hasn't yet bound to a NodeInstance. The :claim member
      # action is what completes the physical-enrollment loop —
      # confirming "this MAC is the device I created NodeInstance X for"
      # marks the row claimed and the device's next poll receives a
      # bootstrap token.
      #
      # Reference: docs/plans/wondrous-yawning-anchor.md §5 + §11.
      class UnclaimedDevicesController < BaseController
        before_action :set_unclaimed_device, only: %i[show claim destroy]

        # GET /api/v1/system/unclaimed_devices
        def index
          require_permission("system.unclaimed_devices.read")

          devices = current_account.system_unclaimed_devices.active
                     .order(last_seen_at: :desc)
          devices = paginate(devices)

          render_success(
            unclaimed_devices: devices.map { |d| serialize(d) },
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/unclaimed_devices/:id
        def show
          require_permission("system.unclaimed_devices.read")
          render_success(unclaimed_device: serialize(@unclaimed_device))
        end

        # POST /api/v1/system/unclaimed_devices/:id/claim
        # Body: { node_instance_id }
        def claim
          require_permission("system.instances.claim")

          node_instance_id = params[:node_instance_id].to_s
          return render_error("node_instance_id is required", 400) if node_instance_id.blank?

          # Scope to the operator's account via the Node FK chain to prevent
          # cross-tenant claim.
          instance = ::System::NodeInstance
                       .joins(:node)
                       .where(system_nodes: { account_id: current_account.id })
                       .find_by(id: node_instance_id)
          return render_not_found("NodeInstance") unless instance

          result = ::System::PhysicalEnrollmentService.confirm_claim!(
            unclaimed:     @unclaimed_device,
            node_instance: instance,
            by_user:       current_user
          )

          if result.ok?
            render_success(
              unclaimed_device: serialize(@unclaimed_device.reload),
              node_instance_id: instance.id,
              node_instance_name: instance.name
            )
          else
            render_error(result.error, 422)
          end
        end

        # DELETE /api/v1/system/unclaimed_devices/:id
        def destroy
          require_permission("system.unclaimed_devices.discard")
          @unclaimed_device.destroy!
          render_success(message: "Unclaimed device dismissed",
                         unclaimed_device_id: params[:id])
        end

        private

        def set_unclaimed_device
          @unclaimed_device = current_account.system_unclaimed_devices.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("UnclaimedDevice")
        end

        def serialize(device)
          {
            id:                  device.id,
            claim_code:          device.claim_code,
            discovered_mac:      device.discovered_mac,
            discovered_dmi_uuid: device.discovered_dmi_uuid,
            discovered_hostname: device.discovered_hostname,
            agent_version:       device.agent_version,
            architecture:        device.architecture,
            platform_hint:       device.platform_hint,
            first_seen_at:       device.first_seen_at,
            last_seen_at:        device.last_seen_at,
            expires_at:          device.expires_at,
            claimed_at:          device.claimed_at,
            claimed_node_instance_id: device.claimed_node_instance_id
          }
        end
      end
    end
  end
end
