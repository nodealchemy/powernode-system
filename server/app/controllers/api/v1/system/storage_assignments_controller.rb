# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD + lifecycle actions for storage assignments.
      # See plan we-need-to-integrate-sunny-flame.md Phase S5.
      class StorageAssignmentsController < BaseController
        before_action :set_assignment, only: %i[show update destroy reconcile rotate_credential]

        def index
          require_permission("system.storage.assignments.read")

          assignments = current_account
            .system_storage_assignments
            .includes(:node_instance, :sdwan_network, :sdwan_virtual_ip)

          assignments = apply_filters(assignments)
          assignments = paginate(assignments.order(created_at: :desc))

          render_success(
            assignments: assignments.map { |a| serialize_assignment(a) },
            meta: pagination_meta
          )
        end

        def show
          require_permission("system.storage.assignments.read")
          render_success(assignment: serialize_assignment(@assignment, full: true))
        end

        def create
          require_permission("system.storage.assignments.create")

          if params[:assignments].is_a?(Array)
            bulk_create(params[:assignments])
            return
          end

          assignment = current_account.system_storage_assignments.build(assignment_params)
          if assignment.save
            render_success(assignment: serialize_assignment(assignment, full: true), status: :created)
          else
            render_validation_error(assignment)
          end
        end

        def update
          require_permission("system.storage.assignments.update")

          if @assignment.update(assignment_params)
            render_success(assignment: serialize_assignment(@assignment, full: true))
          else
            render_validation_error(@assignment)
          end
        end

        def destroy
          require_permission("system.storage.assignments.delete")

          @assignment.update!(enabled: false)
          # The after_commit hook + reconciler will dispatch storage.unmount
          # before deleting. Schedule deletion after a brief grace period so
          # the agent can ack the unmount.
          @assignment.destroy
          render_success(message: "Assignment deleted")
        end

        def reconcile
          require_permission("system.storage.assignments.update")
          ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(@assignment)
          render_success(assignment: serialize_assignment(@assignment.reload, full: true))
        end

        def rotate_credential
          require_permission("system.storage.assignments.rotate_credential")
          credential = @assignment.active_credential
          if credential
            new_cred = ::System::Storage::CredentialIssuer.new(assignment: @assignment).rotate!(credential)
            render_success(credential_id: new_cred.id, message: "Credential rotated")
          else
            render_error("No active credential to rotate", status: :unprocessable_entity)
          end
        end

        private

        def set_assignment
          @assignment = current_account.system_storage_assignments.find(params[:id])
        end

        def apply_filters(scope)
          scope = scope.where(file_storage_id: params[:file_storage_id]) if params[:file_storage_id].present?
          scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope = scope.enabled if params[:enabled] == "true"
          scope
        end

        def assignment_params
          params.require(:assignment).permit(
            :file_storage_id, :node_instance_id,
            :sdwan_network_id, :sdwan_virtual_ip_id,
            :mount_path, :read_only, :enabled, :auto_mount, :encryption_mode,
            mount_options: {}
          )
        end

        def bulk_create(rows)
          created = []
          errors = []
          rows.each_with_index do |row, idx|
            assignment = current_account.system_storage_assignments.build(row.permit(
              :file_storage_id, :node_instance_id, :sdwan_network_id, :sdwan_virtual_ip_id,
              :mount_path, :read_only, :enabled, :auto_mount, :encryption_mode, mount_options: {}
            ).to_h)
            if assignment.save
              created << serialize_assignment(assignment, full: true)
            else
              errors << { index: idx, errors: assignment.errors.as_json }
            end
          end
          render_success(created: created, errors: errors, status: errors.empty? ? :created : :multi_status)
        end

        def serialize_assignment(a, full: false)
          base = {
            id: a.id,
            file_storage_id: a.file_storage_id,
            node_instance_id: a.node_instance_id,
            sdwan_network_id: a.sdwan_network_id,
            sdwan_virtual_ip_id: a.sdwan_virtual_ip_id,
            mount_path: a.mount_path,
            status: a.status,
            encryption_mode: a.encryption_mode,
            effective_encryption_mode: a.effective_encryption_mode,
            enabled: a.enabled,
            auto_mount: a.auto_mount,
            read_only: a.read_only,
            last_mounted_at: a.last_mounted_at&.iso8601,
            last_status_at: a.last_status_at&.iso8601,
            created_at: a.created_at&.iso8601
          }
          base[:mount_options] = a.mount_options
          base[:error_message] = a.error_message if full
          base[:active_credential_id] = a.active_credential&.id if full
          base
        end
      end
    end
  end
end
