# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Agent-facing endpoint for storage assignments. Authenticated via
        # mTLS through BaseController; current_instance is resolved from
        # the forwarded client-cert CN.
        class StorageAssignmentsController < BaseController
          # credential is NOT here. update_status and encryption_key stay
          # owning-client-only; credential has its own, narrower lookup
          # (#resolve_credential) because it alone also serves a non-owning
          # requester (the SMB backend/gateway peer) — see #resolve_credential.
          before_action :set_assignment, only: %i[update_status encryption_key]

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
              return render_error("Invalid status: #{new_status}", status: :unprocessable_content)
            end

            @assignment.mark_status!(new_status, error_message: params[:error_message])
            # NOT `status:` — that is render_success's HTTP-status keyword, not a
            # data field. A live assignment status ("mounted", "mounting", ...) is
            # never a valid Rack status, so it raised ArgumentError AFTER
            # mark_status! had already committed the row: the agent's mount report
            # 500'd while the mount itself was correctly recorded. See
            # render_success_status_keyword_spec.rb.
            render_success(assignment_id: @assignment.id, assignment_status: @assignment.status)
          end

          # GET /api/v1/system/node_api/storage_assignments/:id/credential
          # GET .../credential?credential_id=<uuid> (SMB backend/gateway peer only)
          #
          # Vault round-trip — returns decrypted credential material.
          def credential
            assignment = ::System::StorageAssignment.find_by(id: params[:id])
            unless assignment && assignment.account_id == current_instance.account_id
              return render_error("Storage assignment not found", status: :not_found)
            end

            credential = resolve_credential(assignment)
            return render_error("No active credential", status: :not_found) unless credential

            material = credential.vault_credentials || {}
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

          # #credential alone also serves a requester that is NOT the
          # assignment's own client: System::Storage::SmbUserManager dispatches
          # storage.smb_user.apply to the storage's SMB backend/gateway peer, a
          # DIFFERENT node instance than the assignment's client, to actually
          # run samba-tool — that peer has no assignment of its own.
          #
          # Two DIFFERENT trust rules, not one relaxed rule:
          #   owning client  — unchanged: always the assignment's active_credential,
          #                    no credential_id needed (the existing CIFS mount
          #                    path keeps working exactly as before).
          #   SMB backend    — must name the EXACT credential id it wants
          #                    (?credential_id=) AND there must exist a LIVE
          #                    (pending/running) storage.smb_user.apply
          #                    System::Task, in the same account, whose
          #                    operable IS this requesting instance, and whose
          #                    options name that same credential id (as either
          #                    "credential" or "new_credential"). Deriving the
          #                    grant from the STORAGE'S CURRENT configuration
          #                    (e.g. "you're the configured export host") was
          #                    reviewed and rejected: it would keep granting a
          #                    peer access after a gateway reconfiguration, or
          #                    to a completed task's now-stale credential id,
          #                    long after that peer had any legitimate reason
          #                    to fetch it. A live, per-task grant expires
          #                    exactly when the work it was issued for does.
          def resolve_credential(assignment)
            if assignment.node_instance_id == current_instance.id
              return ::System::StorageCredential.find_by(id: assignment.active_credential&.id)
            end

            requested_id = params[:credential_id].to_s
            return nil if requested_id.blank?
            return nil unless smb_backend_task_grants?(assignment, requested_id)

            ::System::StorageCredential.find_by(
              id: requested_id,
              storage_assignment_id: assignment.id,
              status: %w[issued active rotating]
            )
          end

          def smb_backend_task_grants?(assignment, credential_id)
            ::System::Task
              .where(command: "storage.smb_user.apply", status: %w[pending running])
              .where(operable_type: "System::NodeInstance", operable_id: current_instance.id)
              .where(account_id: assignment.account_id)
              .where(
                "options -> 'credential' ->> 'id' = :cred_id OR options -> 'new_credential' ->> 'id' = :cred_id",
                cred_id: credential_id
              )
              .exists?
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
