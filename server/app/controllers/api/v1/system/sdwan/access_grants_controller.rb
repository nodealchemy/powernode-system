# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::AccessGrant. Granting a user access to
# a network is a precondition for issuing them a UserDevice — without
# the grant, the issuer raises GrantError and the bootstrap path is
# unreachable.
#
# Slice 4 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class AccessGrantsController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_network
          before_action :set_grant, only: %i[show update destroy revoke]

          def index
            require_permission("sdwan.user_devices.manage")
            grants = @network.access_grants.includes(:user, :user_devices).order(created_at: :desc)
            render_success(access_grants: grants.map { |g| serialize_grant(g) }, count: grants.size)
          end

          def show
            require_permission("sdwan.user_devices.manage")
            render_success(access_grant: serialize_grant_full(@grant))
          end

          def create
            require_permission("sdwan.user_devices.manage")
            attrs = grant_params

            user = ::User.where(account_id: @account.id).find(attrs[:user_id])
            grant = @network.access_grants.find_or_initialize_by(user_id: user.id)
            grant.assign_attributes(
              account_id: @account.id,
              status: "active",
              granted_by_id: current_user&.id,
              granted_at: Time.current,
              tags: attrs[:tags] || [],
              revoked_at: nil,
              revocation_reason: nil
            )

            if grant.save
              render_success({ access_grant: serialize_grant_full(grant) }, status: :created)
            else
              render_validation_error(grant)
            end
          rescue ActiveRecord::RecordNotFound
            render_not_found("User")
          end

          def update
            require_permission("sdwan.user_devices.manage")
            if @grant.update(grant_update_params)
              render_success(access_grant: serialize_grant_full(@grant.reload))
            else
              render_validation_error(@grant)
            end
          end

          def destroy
            require_permission("sdwan.user_devices.manage")
            @grant.destroy!
            render_success(deleted: true, id: @grant.id)
          end

          # POST /access_grants/:id/revoke — softer than DELETE; preserves
          # the row + its devices for audit, just flips status.
          def revoke
            require_permission("sdwan.user_devices.manage")
            @grant.revoke!(reason: params[:reason], by_user: current_user)
            render_success(access_grant: serialize_grant_full(@grant.reload), revoked: true)
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_grant
            @grant = @network.access_grants.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Access Grant")
          end

          def grant_params
            params.require(:access_grant).permit(:user_id, tags: [])
          end

          def grant_update_params
            params.require(:access_grant).permit(:status, tags: [])
          end

          def serialize_grant(g)
            {
              id: g.id,
              network_id: g.sdwan_network_id,
              user_id: g.user_id,
              user_email: g.user&.email,
              status: g.status,
              tags: g.tags,
              granted_at: g.granted_at&.iso8601,
              granted_by_user_id: g.granted_by_id,
              revoked_at: g.revoked_at&.iso8601,
              device_count: g.user_devices.size
            }
          end

          def serialize_grant_full(g)
            serialize_grant(g).merge(
              revocation_reason: g.revocation_reason,
              metadata: g.metadata,
              created_at: g.created_at.iso8601
            )
          end
        end
      end
    end
  end
end
