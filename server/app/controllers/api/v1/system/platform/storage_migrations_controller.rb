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
        #   POST   /api/v1/system/platform/storage_migrations/:id/revert
        #     (Increment 9) Request the agent re-point the mount back to
        #     source. Reachable from `failed`, or `completed` when
        #     promote_target_binding! was swallowed.
        #   POST   /api/v1/system/platform/storage_migrations/:id/cleanup
        #     (Increment 9) DESTRUCTIVE — delete target-side scratch
        #     artifacts only. Body: { reason?, immediate? }.
        #
        # Permissions:
        #   system.platform.read   — index + show
        #   system.platform.scale  — create + approve + cancel + revert + cleanup
        #
        # Plan reference: E8 / E8.2 frontend slice; Increment 9 (campaign
        # 019f3458) — revert_binding! / cleanup.
        class StorageMigrationsController < ApplicationController
          before_action :authenticate_request
          before_action :set_migration, only: %i[show approve cancel revert cleanup]

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
            return render_error(result[:error] || "Migration plan failed", status: :unprocessable_content) unless result[:success]
            render_success(storage_migration: result[:storage_migration])
          end

          def approve
            return forbidden unless current_user&.has_permission?("system.platform.scale")
            return render_error("Cannot approve in status=#{@migration.status}", status: :unprocessable_content) unless @migration.can_transition_to?("approved")

            @migration.transition_to!(
              "approved",
              message: "Approved by #{current_user&.email || 'operator'}",
              details: { approved_by_user_id: current_user&.id }
            )
            render_success(storage_migration: serialize_full(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_content)
          end

          def cancel
            return forbidden unless current_user&.has_permission?("system.platform.scale")
            return render_error("Already terminal (#{@migration.status})", status: :unprocessable_content) if @migration.terminal?
            return render_error("Cannot cancel — sync already in progress", status: :unprocessable_content) unless %w[planned approved preparing].include?(@migration.status)

            @migration.cancel!(reason: params[:reason], user: current_user)
            render_success(storage_migration: serialize_full(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_content)
          end

          # POST /api/v1/system/platform/storage_migrations/:id/revert
          # Increment 9 (R) — request the on-node agent re-point the
          # canonical mount back to source. Reachable from `failed`, or
          # from `completed` when promote_target_binding! was swallowed.
          def revert
            return forbidden unless current_user&.has_permission?("system.platform.scale")

            result = call_mcp_action("system_revert_storage_migration_binding",
              id: @migration.id, reason: params[:reason]
            )
            return render_error(result[:error] || "Revert request failed", status: :unprocessable_content) unless result[:success]
            render_success(storage_migration: result[:storage_migration])
          end

          # POST /api/v1/system/platform/storage_migrations/:id/cleanup
          # Increment 9 (C) — DESTRUCTIVE, target-side, subpath-scoped
          # only. Explicit operator action; never auto-run on failure.
          # Body: { reason?, immediate? }.
          def cleanup
            return forbidden unless current_user&.has_permission?("system.platform.scale")

            result = call_mcp_action("system_cleanup_storage_migration",
              id: @migration.id, reason: params[:reason], immediate: params[:immediate]
            )
            return render_error(result[:error] || "Cleanup request failed", status: :unprocessable_content) unless result[:success]
            render_success(storage_migration: result[:storage_migration])
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
          #
          # BUGFIX (increment 9, campaign 019f3458) — two latent bugs found
          # while wiring #revert/#cleanup through this same helper, neither
          # ever exercised because this controller had zero request-spec
          # coverage before this increment:
          #
          # 1. PlatformApiToolRegistry has no `.new`/`#execute` of its own —
          #    it's a registry of tool CLASSES (`TOOLS`, `find_tool`), not a
          #    callable itself. The previous body
          #    (`PlatformApiToolRegistry.new(...).execute(action, params)`)
          #    raised ArgumentError ("wrong number of arguments") on every
          #    call, including #create's (silently swallowed by the rescue
          #    below into a generic error response). The correct pattern
          #    (matching every other MCP-tool caller in this codebase) is:
          #    resolve the tool CLASS via find_tool, instantiate it, and call
          #    #execute(params:) with the action folded into params
          #    (BaseTool#call reads params[:action] to dispatch).
          # 2. BaseTool#success_result(data) wraps its argument as
          #    `{ success: true, data: data }` — the caller-supplied keys
          #    (e.g. `storage_migration:`) live under `data`, not at the top
          #    level. #create's `result[:storage_migration]` (and this
          #    method's callers generally) expect a flat shape, so we merge
          #    `data` up a level here rather than touch every call site.
          def call_mcp_action(action, params)
            tool_class = ::Ai::Tools::PlatformApiToolRegistry.find_tool(action)
            return { success: false, error: "Unknown MCP action: #{action}" } unless tool_class

            result = tool_class.new(account: current_account, user: current_user)
                               .execute(params: params.merge(action: action))
            return { success: false, error: "Unexpected MCP response" } unless result.is_a?(Hash)

            result = result.with_indifferent_access
            data = result[:data].is_a?(Hash) ? result[:data] : {}
            data.with_indifferent_access.merge(success: result[:success], error: result[:error])
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
