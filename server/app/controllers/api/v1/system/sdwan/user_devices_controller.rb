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
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network
          before_action :set_grant
          before_action :set_device, only: %i[show destroy revoke]

          def index
            require_permission("system.sdwan.user_devices.manage")
            devices = @grant.user_devices.order(created_at: :desc)
            render_success(user_devices: devices.map { |d| serialize_device(d) }, count: devices.size)
          end

          def show
            require_permission("system.sdwan.user_devices.manage")
            render_success(user_device: serialize_device(@device))
          end

          # Issues a new device + bootstrap token. The token is shown ONCE
          # in the response; we don't persist it (it's recoverable from the
          # device by re-issuing if lost, since each issuance creates a
          # NEW UserDevice with a fresh keypair — old keys remain auditable).
          #
          # IMP-051f3811ac60: routed through Ai::AutonomyGate. Issuing mints a
          # WireGuard keypair + a bootstrap token that serves the full client
          # config, so it is at least as material as the device REVOKE below,
          # which has been gated all along. Sdwan::Executors::CreateUserDevice
          # delegates to the same UserDeviceIssuer this action used to call
          # inline, and on the :proceed branch the token rides the executor's
          # raw return — the response shape is unchanged. On :pending the
          # token is minted at approval time and reaches the approver through
          # the reveal-once slot (Ai::DeferredOperation#take_revealed_result!);
          # the persisted operation row masks it (SensitiveParams "token").
          #
          # Not gate_create!: its on_proceed renders only the serialized row,
          # and the one-shot bootstrap block would be dropped on the floor.
          #
          # Pre-checks run IN FRONT of the gate so a doomed request refuses
          # fast instead of parking an approval that can only ever fail. Only
          # label errors are read off the candidate — public_key and
          # assigned_address are legitimately absent until the issuer mints
          # them. Neither check is the enforcement: the issuer re-runs both
          # inside the executor when the operation executes.
          def create
            require_permission("system.sdwan.user_devices.manage")
            attrs = device_params

            unless @grant.active?
              return render_error("grant is not active", status: :unprocessable_content)
            end
            candidate = @grant.user_devices.new(label: attrs[:label])
            candidate.valid?
            if candidate.errors[:label].any?
              return render_error(candidate.errors.full_messages_for(:label).join("; "),
                                  status: :unprocessable_content)
            end

            gate!(
              action_category: ::Sdwan::Executors::CreateUserDevice::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::CreateUserDevice",
              params: { grant_id: @grant.id, label: attrs[:label] },
              source_type: "Sdwan::AccessGrant",
              source_id: @grant.id,
              description: "Issue SDWAN VPN device '#{attrs[:label]}' for #{@grant.user&.email || @grant.id}",
              on_proceed: lambda { |result|
                data = result.result&.dig(:data) || {}
                device = @grant.user_devices.find(data[:device_id])
                render_success({
                  user_device: serialize_device(device),
                  bootstrap: {
                    token: data[:bootstrap_token],
                    url: bootstrap_url(data[:bootstrap_token]),
                    expires_at: data[:expires_at]
                  }
                }, status: :created)
              },
              # A gate is an error-path change: AutonomyGate flattens every
              # raise into one :blocked string, so the issuer's typed errors
              # are unwrapped off Result#exception to keep the wording this
              # action returned when it called the issuer inline.
              on_blocked: lambda { |result|
                case result.exception
                when ::Sdwan::UserDeviceIssuer::GrantError
                  render_error(result.exception.message, status: :unprocessable_content)
                when ActiveRecord::RecordInvalid
                  render_validation_error(result.exception.record)
                else
                  render_error(result.error || "Action blocked by policy",
                               status: :unprocessable_content)
                end
              }
            )
          end

          def destroy
            require_permission("system.sdwan.user_devices.manage")
            id = @device.id
            label = @device.try(:label)
            gate!(
              action_category: ::Sdwan::Executors::RevokeUserDevice::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::RevokeUserDevice",
              params: { grant_id: @grant.id, device_id: id, destroy_row: true },
              source_type: "Sdwan::UserDevice",
              source_id: id,
              description: "Delete SDWAN device #{label || id}",
              # The executor destroys the row. Doing it here instead would only
              # cover the :proceed branch — gate! skips on_proceed when the action
              # is deferred for approval, and this category is require_approval.
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          # POST /user_devices/:id/revoke — soft revoke, keeps the row for audit.
          def revoke
            require_permission("system.sdwan.user_devices.manage")
            id = @device.id
            label = @device.try(:label)
            gate!(
              action_category: ::Sdwan::Executors::RevokeUserDevice::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::RevokeUserDevice",
              params: { grant_id: @grant.id, device_id: id, reason: params[:reason] },
              source_type: "Sdwan::UserDevice",
              source_id: id,
              description: "Revoke SDWAN device #{label || id}",
              on_proceed: ->(_r) { render_success(user_device: serialize_device(@device.reload), revoked: true) }
            )
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
              network_id: @grant.sdwan_network_id,
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
