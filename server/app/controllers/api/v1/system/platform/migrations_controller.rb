# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side read endpoints for Migration rows (the planned/
        # in-flight/completed cross-peer resource transfers built on the
        # P5 framework).
        #
        # Note: this controller is intentionally READ-ONLY in v1. The
        # full operator-driven creation flow (PlanComposer trigger →
        # conflict resolution → apply) is a follow-up wizard slice;
        # operators currently create migrations programmatically via the
        # internal Migration::PlanComposer + MigrationApplyJob.
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/migrations
        #     List with summary fields. Filterable by status (comma-sep).
        #
        #   GET    /api/v1/system/platform/migrations/:id
        #     Full detail including plan_summary, conflict_log, audit_log.
        #
        # Permissions:
        #   system.platform.read — index + show
        #
        # Plan reference: Decentralized Federation §F + §I + P5 + P7.4.
        class MigrationsController < ApplicationController
          before_action :authenticate_request
          before_action :set_migration, only: %i[show]

          def index
            return forbidden unless current_user&.has_permission?("system.platform.read")

            migrations = ::System::Migration.where(account: current_account).order(created_at: :desc)
            migrations = migrations.where(status: params[:status].split(",")) if params[:status].present?
            migrations = migrations.where(operation: params[:operation]) if params[:operation].present?

            render_success(
              migrations: migrations.map { |m| serialize_summary(m) },
              count: migrations.size
            )
          end

          def show
            return forbidden unless current_user&.has_permission?("system.platform.read")
            render_success(migration: serialize_full(@migration))
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_migration
            @migration = ::System::Migration.find_by(id: params[:id], account: current_account)
            render_error("Migration not found", status: :not_found) unless @migration
          end

          def serialize_summary(migration)
            {
              id: migration.id,
              operation: migration.operation,
              status: migration.status,
              root_resource_kind: migration.root_resource_kind,
              root_resource_id: migration.root_resource_id,
              dry_run: migration.dry_run,
              destination_peer_id: migration.destination_peer_id,
              step_count: safe_call(migration, :step_count) || 0,
              total_steps: safe_call(migration, :total_steps) || 0,
              created_at: migration.created_at&.iso8601,
              started_at: migration.started_at&.iso8601,
              completed_at: migration.completed_at&.iso8601,
              failed_at: migration.failed_at&.iso8601,
              cancelled_at: migration.cancelled_at&.iso8601,
              terminal: safe_call(migration, :terminal?) || false,
              error_message: migration.error_message
            }
          end

          def serialize_full(migration)
            serialize_summary(migration).merge(
              plan_summary: migration.plan_summary || {},
              conflict_log: Array(migration.conflict_log),
              audit_log: Array(migration.audit_log),
              metadata: migration.metadata || {},
              initiated_by_user_id: migration.initiated_by_user_id
            )
          end

          def safe_call(obj, method)
            obj.respond_to?(method) ? obj.public_send(method) : nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
