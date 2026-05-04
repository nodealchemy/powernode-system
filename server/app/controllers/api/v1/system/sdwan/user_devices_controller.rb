# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::UserDevice. Issuing a device returns
# the bootstrap_token in the create response — operators copy it to the
# user via any channel (Slack, email, signal). The token URL is
# single-use; the user fetches once at /sdwan/bootstrap/<token> and the
# WG config text is rendered.
#
# Slice 4 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class UserDevicesController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_network
          before_action :set_grant
          before_action :set_device, only: %i[show destroy revoke]

          def index
            require_permission("sdwan.user_devices.manage")
            devices = @grant.user_devices.order(created_at: :desc)
            render_success(user_devices: devices.map { |d| serialize_device(d) }, count: devices.size)
          end

          def show
            require_permission("sdwan.user_devices.manage")
            render_success(user_device: serialize_device(@device))
          end

          # Issues a new device + bootstrap token. The token is shown ONCE
          # in the response; we don't persist it (it's recoverable from the
          # device by re-issuing if lost, since each issuance creates a
          # NEW UserDevice with a fresh keypair — old keys remain auditable).
          def create
            require_permission("sdwan.user_devices.manage")
            attrs = device_params

            result = ::Sdwan::UserDeviceIssuer.issue!(grant: @grant, label: attrs[:label])
            device = result[:device]

            render_success({
              user_device: serialize_device(device),
              bootstrap: {
                token: result[:bootstrap_token],
                url: bootstrap_url(result[:bootstrap_token]),
                expires_at: result[:expires_at]
              }
            }, status: :created)
          rescue ::Sdwan::UserDeviceIssuer::GrantError => e
            render_error(e.message, status: :unprocessable_entity)
          rescue ActiveRecord::RecordInvalid => e
            render_validation_error(e.record)
          end

          def destroy
            require_permission("sdwan.user_devices.manage")
            @device.destroy!
            render_success(deleted: true, id: @device.id)
          end

          # POST /user_devices/:id/revoke — soft revoke, keeps the row for audit.
          def revoke
            require_permission("sdwan.user_devices.manage")
            @device.revoke!(reason: params[:reason])
            render_success(user_device: serialize_device(@device.reload), revoked: true)
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_grant
            @grant = @network.access_grants.find(params[:access_grant_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Access Grant")
          end

          def set_device
            @device = @grant.user_devices.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN User Device")
          end

          def device_params
            params.require(:user_device).permit(:label)
          end

          def bootstrap_url(token)
            "/api/v1/system/sdwan/bootstrap/#{token}"
          end

          def serialize_device(d)
            {
              id: d.id,
              access_grant_id: d.sdwan_access_grant_id,
              network_id: d.network.id,
              label: d.label,
              public_key: d.public_key,
              assigned_address: d.assigned_address,
              downloadable: d.downloadable?,
              last_downloaded_at: d.last_downloaded_at&.iso8601,
              last_seen_at: d.last_seen_at&.iso8601,
              revoked_at: d.revoked_at&.iso8601,
              created_at: d.created_at.iso8601
            }
          end
        end
      end
    end
  end
end
