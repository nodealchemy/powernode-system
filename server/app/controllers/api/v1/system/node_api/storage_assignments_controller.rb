# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Agent-facing endpoint for storage assignments. Authenticated via
        # the instance JWT (X-Instance-Token or Bearer; type: "instance");
        # current_instance is provided by BaseController.
        class StorageAssignmentsController < BaseController
          before_action :set_assignment, only: %i[update_status credential encryption_key]

          # GET /api/v1/system/node_api/storage_assignments
          # List enabled assignments for the calling instance.
          def index
            assignments = ::System::StorageAssignment
              .where(node_instance_id: current_instance.id, enabled: true)
              .includes(:sdwan_virtual_ip)

            render_success(
              assignments: assignments.map { |a| serialize_for_agent(a) },
              count: assignments.size
            )
          end

          # POST /api/v1/system/node_api/storage_assignments/:id/status
          # Agent reports mount lifecycle: { status:, error_message?, mounted_at?, capacity? }
          def update_status
            new_status = params[:status].to_s
            unless ::System::StorageAssignment::STATUSES.include?(new_status)
              return render_error("Invalid status: #{new_status}", status: :unprocessable_entity)
            end

            @assignment.mark_status!(new_status, error_message: params[:error_message])
            render_success(assignment_id: @assignment.id, status: @assignment.status)
          end

          # GET /api/v1/system/node_api/storage_assignments/:id/credential
          # Vault round-trip — returns decrypted credential material for
          # the active credential. Use Model.find (not .reload) to bypass
          # the @vault_credentials cache reload bug.
          def credential
            credential = ::System::StorageCredential.find(@assignment.active_credential&.id)
            return render_error("No active credential", status: :not_found) unless credential

            material = credential.vault_credentials || {}
            render_success(
              kind: credential.kind,
              credential_id: credential.id
            ).tap { |_r|
              # Merge the decrypted material into the success envelope's
              # data hash. render_success builds {"success":true,"data":{...}};
              # since we want a flat payload the agent's FetchCredential
              # decodes, we expose the credential fields at the top level.
            } if false # noop — kept for documentation
            payload = material.merge(kind: credential.kind, credential_id: credential.id)
            render json: { success: true, data: payload }
          end

          # GET /api/v1/system/node_api/storage_assignments/:id/encryption_key
          # Returns the active mount encryption key material.
          def encryption_key
            key = ::System::MountEncryptionKey.find(
              @assignment.mount_encryption_keys.active.order(created_at: :desc).pick(:id)
            )
            return render_error("No active encryption key", status: :not_found) unless key

            material = key.vault_credentials || {}
            payload = material.merge(key_id: key.id, algorithm: key.algorithm)
            render json: { success: true, data: payload }
          rescue ActiveRecord::RecordNotFound
            render_error("No active encryption key", status: :not_found)
          end

          private

          def set_assignment
            @assignment = ::System::StorageAssignment.find_by!(
              id: params[:id],
              node_instance_id: current_instance.id
            )
          rescue ActiveRecord::RecordNotFound
            render_error("Storage assignment not found", status: :not_found)
          end

          def serialize_for_agent(a)
            {
              id: a.id,
              mount_path: a.mount_path,
              status: a.status,
              encryption_mode: a.effective_encryption_mode,
              auto_mount: a.auto_mount,
              read_only: a.read_only,
              enabled: a.enabled,
              file_storage_id: a.file_storage_id,
              # The agent fetches credential + recipe via dedicated endpoints —
              # this index endpoint is a manifest only, not a full payload.
              credential_url: "/api/v1/system/node_api/storage_assignments/#{a.id}/credential",
              encryption_key_url: a.effective_encryption_mode == "none" ? nil : "/api/v1/system/node_api/storage_assignments/#{a.id}/encryption_key"
            }
          end
        end
      end
    end
  end
end
