# frozen_string_literal: true

module Api
  module V1
    module System
      # Read-only metadata view + rotate action for storage credentials.
      # NEVER serializes the credential material — only kind / status /
      # rotation cadence. Material lives in Vault and is only fetched at
      # mount time by the agent via the node_api credential endpoint.
      class StorageCredentialsController < BaseController
        before_action :set_credential, only: %i[show rotate]

        def index
          require_permission("system.storage.assignments.read")

          credentials = ::System::StorageCredential
            .joins(:storage_assignment)
            .where(system_storage_assignments: { account_id: current_account.id })
            .includes(:storage_assignment)

          credentials = credentials.where(storage_assignment_id: params[:storage_assignment_id]) if params[:storage_assignment_id]
          credentials = paginate(credentials.order(created_at: :desc))

          render_success(
            credentials: credentials.map { |c| serialize(c) },
            meta: pagination_meta
          )
        end

        def show
          require_permission("system.storage.assignments.read")
          render_success(credential: serialize(@credential))
        end

        def rotate
          require_permission("system.storage.assignments.rotate_credential")

          new_cred = ::System::Storage::CredentialIssuer
            .new(assignment: @credential.storage_assignment)
            .rotate!(@credential)
          render_success(credential: serialize(new_cred))
        end

        private

        def set_credential
          @credential = ::System::StorageCredential
            .joins(:storage_assignment)
            .where(system_storage_assignments: { account_id: current_account.id })
            .find(params[:id])
        end

        def serialize(c)
          {
            id: c.id,
            storage_assignment_id: c.storage_assignment_id,
            node_instance_id: c.node_instance_id,
            kind: c.kind,
            status: c.status,
            expires_at: c.expires_at&.iso8601,
            last_rotated_at: c.last_rotated_at&.iso8601,
            needs_rotation: c.needs_rotation?,
            metadata: c.metadata.except("peer_ip") # don't leak peer IPs to non-node callers
          }
        end
      end
    end
  end
end
