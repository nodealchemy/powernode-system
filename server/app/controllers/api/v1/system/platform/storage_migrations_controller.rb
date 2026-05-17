# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side REST surface for System::StorageMigration. Mirrors
        # the MCP actions exposed via SystemFleetTool but in a shape the
        # frontend's React Query layer consumes.
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/storage_migrations
        #     List (optional status/instance/active_only filters).
        #   GET    /api/v1/system/platform/storage_migrations/:id
        #     Full detail incl. plan + audit_log.
        #   POST   /api/v1/system/platform/storage_migrations
        #     Plan a new migration. Body: { node_instance_id, role,
        #     source_volume_id, target_volume_id }.
        #   POST   /api/v1/system/platform/storage_migrations/:id/approve
        #     Advance status planned → approved (agent picks up next tick).
        #   POST   /api/v1/system/platform/storage_migrations/:id/cancel
        #     Cancel a not-yet-syncing migration.
        #
        # Permissions:
        #   system.platform.read   — index + show
        #   system.platform.scale  — create + approve + cancel
        #
        # Plan reference: E8 / E8.2 frontend slice.
        class StorageMigrationsController < ApplicationController
          before_action :authenticate_request
          before_action :set_migration, only: %i[show approve cancel]

          def index
            return forbidden unless current_user&.has_permission?("system.platform.read")

            scope = ::System::StorageMigration.where(account: current_account).order(created_at: :desc)
            scope = scope.where(status: params[:status].split(",")) if params[:status].present?
            scope = scope.for_instance(params[:node_instance_id]) if params[:node_instance_id].present?
            scope = scope.active if ActiveModel::Type::Boolean.new.cast(params[:active_only])

            render_success(
              storage_migrations: scope.limit(200).map { |m| serialize_summary(m) },
              count: scope.size
            )
          end

          def show
            return forbidden unless current_user&.has_permission?("system.platform.read")
            render_success(storage_migration: serialize_full(@migration))
          end

          def create
            return forbidden unless current_user&.has_permission?("system.platform.scale")

            result = call_mcp_action("system_migrate_storage_component",
              node_instance_id: params[:node_instance_id],
              source_volume_id: params[:source_volume_id],
              target_volume_id: params[:target_volume_id],
              role:             params[:role]
            )
            return render_error(result[:error] || "Migration plan failed", status: :unprocessable_entity) unless result[:success]
            render_success(storage_migration: result[:storage_migration])
          end

          def approve
            return forbidden unless current_user&.has_permission?("system.platform.scale")
            return render_error("Cannot approve in status=#{@migration.status}", status: :unprocessable_entity) unless @migration.can_transition_to?("approved")

            @migration.transition_to!(
              "approved",
              message: "Approved by #{current_user&.email || 'operator'}",
              details: { approved_by_user_id: current_user&.id }
            )
            render_success(storage_migration: serialize_full(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_entity)
          end

          def cancel
            return forbidden unless current_user&.has_permission?("system.platform.scale")
            return render_error("Already terminal (#{@migration.status})", status: :unprocessable_entity) if @migration.terminal?
            return render_error("Cannot cancel — sync already in progress", status: :unprocessable_entity) unless %w[planned approved preparing].include?(@migration.status)

            @migration.cancel!(reason: params[:reason], user: current_user)
            render_success(storage_migration: serialize_full(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_entity)
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_migration
            @migration = ::System::StorageMigration.find_by(id: params[:id], account: current_account)
            render_error("Migration not found", status: :not_found) unless @migration
          end

          # The MCP action layer already implements plan composition with
          # all the right validations + subpath computation. Re-using it
          # via the registry avoids duplicating ~50 lines of logic and
          # keeps the operator path consistent with the agent / AI path.
          def call_mcp_action(action, params)
            registry = ::Ai::Tools::PlatformApiToolRegistry.new(
              account: current_account, user: current_user
            )
            registry.execute(action, params).then { |r| r.is_a?(Hash) ? r.with_indifferent_access : { success: false, error: "Unexpected MCP response" } }
          rescue StandardError => e
            Rails.logger.warn("[PlatformStorageMigrationsController] MCP call failed: #{e.message}")
            { success: false, error: e.message }
          end

          def serialize_summary(m)
            {
              id: m.id,
              status: m.status,
              role: m.role,
              node_instance_id: m.node_instance_id,
              source_volume_id: m.source_volume_id,
              target_volume_id: m.target_volume_id,
              source_subpath: m.source_subpath,
              target_subpath: m.target_subpath,
              bytes_copied: m.bytes_copied,
              bytes_total: m.bytes_total,
              terminal: m.terminal?,
              error_message: m.error_message,
              created_at: m.created_at&.iso8601,
              approved_at: m.approved_at&.iso8601,
              started_at: m.started_at&.iso8601,
              completed_at: m.completed_at&.iso8601,
              failed_at: m.failed_at&.iso8601,
              cancelled_at: m.cancelled_at&.iso8601
            }
          end

          def serialize_full(m)
            serialize_summary(m).merge(
              plan: m.plan,
              audit_log: Array(m.audit_log),
              metadata: m.metadata || {},
              snapshot_subpath: m.snapshot_subpath,
              initiated_by_user_id: m.initiated_by_user_id
            )
          end
        end
      end
    end
  end
end
