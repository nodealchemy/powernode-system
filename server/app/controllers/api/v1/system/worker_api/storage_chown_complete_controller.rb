# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that the on-node agent POSTs to after
        # finishing a storage.chown task. Transitions the assignment's
        # chown_state to complete/failed and triggers NFS export
        # re-render (via the standard StorageAssignment after_commit
        # :trigger_reconcile hook).
        #
        # POST /api/v1/system/worker_api/storage/chown_complete
        #   Auth: X-Worker-Token (worker JWT)
        #   Body:
        #     {
        #       storage_assignment_id: <uuid>,
        #       task_id:               <uuid>,
        #       status:                "complete" | "failed",
        #       error_message:         <string?>
        #     }
        #   Response: { data: { assignment_id, chown_state } }
        class StorageChownCompleteController < BaseController
          def create
            assignment = ::System::StorageAssignment.find_by(id: params[:storage_assignment_id])
            return render_error("Unknown storage_assignment_id", status: :not_found) unless assignment

            # Guard against stale callbacks — if the assignment has
            # already been re-dispatched (different chown_task_id),
            # ignore this completion to avoid clobbering a fresh chown.
            if assignment.chown_task_id.present? && params[:task_id].present? &&
               assignment.chown_task_id.to_s != params[:task_id].to_s
              Rails.logger.warn(
                "[StorageChownCompleteController] stale callback for assignment #{assignment.id}: " \
                "expected task=#{assignment.chown_task_id} got task=#{params[:task_id]}"
              )
              return render_success(
                assignment_id: assignment.id,
                chown_state:   assignment.chown_state,
                stale:         true
              )
            end

            case params[:status].to_s
            when "complete"
              assignment.update_columns(
                chown_state:        "complete",
                chown_completed_at: Time.current,
                chown_previous_uid: nil,
                chown_previous_gid: nil,
                chown_last_error:   nil
              )
              # Re-render NFS exports with the now-effective anonuid/anongid.
              ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(assignment) rescue nil
            when "failed"
              assignment.update_columns(
                chown_state:      "failed",
                chown_last_error: params[:error_message].to_s.presence || "agent reported failure without detail"
              )
            else
              return render_error(
                "status must be one of complete|failed (got #{params[:status].inspect})",
                status: :unprocessable_entity
              )
            end

            render_success(
              assignment_id: assignment.id,
              chown_state:   assignment.reload.chown_state
            )
          rescue StandardError => e
            Rails.logger.error("[StorageChownCompleteController] #{e.class}: #{e.message}")
            render_error("Chown completion failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
