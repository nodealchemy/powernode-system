# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing endpoints for the disk-image publication history
      # surface in the UI.
      #
      #   GET  /api/v1/system/node_platforms/:platform_id/disk_image_publications
      #     — paginated history list, ordered by created_at DESC.
      #     Powers the DiskImageHistoryTab on the platform detail page.
      #
      #   POST /api/v1/system/node_platforms/:platform_id/rollback_disk_image
      #     — flips the platform's disk_image_file_object_id back to a
      #     prior published or retired publication. Permission-gated on
      #     system.platforms.rollback_disk_image. Refuses purged rows
      #     (file_object hard-deleted from storage).
      #
      # Worker_api endpoints with similar names live in WorkerApi::
      # DiskImagePublicationsController and serve a different audience —
      # the worker job posting back to the platform after OCI pull.
      # These two controllers are deliberately separate to keep
      # operator vs system-internal access surfaces distinct.
      #
      # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
      class DiskImagePublicationsController < BaseController
        include ::System::GatedActions

        before_action :set_account
        before_action :set_platform
        before_action :set_publication, only: %i[show]

        def index
          require_permission("system.platforms.read")
          publications = @platform.disk_image_publications
                                   .includes(:webhook, :file_object, :triggered_by_worker)
                                   .order(created_at: :desc)
          publications = paginate(publications)
          render_success(
            disk_image_publications: serialize_collection(publications),
            meta: pagination_meta
          )
        end

        def show
          require_permission("system.platforms.read")
          render_success(disk_image_publication: serialize_one(@publication))
        end

        # POST /api/v1/system/node_platforms/:platform_id/rollback_disk_image
        # Body: { publication_id }
        # Flips platform pointer to a prior publication's file_object,
        # restoring the FileObject from soft-delete if the publication
        # was retired. Refuses :purged (FileObject hard-deleted).
        #
        # Gated through Ai::AutonomyGate — rolling back affects every new
        # node provision until the next promote/rollback. Default policy is
        # require_approval per system_disk_image_manager_agent.rb.
        def rollback
          require_permission("system.platforms.rollback_disk_image")

          target = @platform.disk_image_publications.find_by(id: params[:publication_id])
          return render_not_found("DiskImagePublication") unless target

          if target.purged?
            return render_error("Cannot rollback to a purged publication — FileObject was hard-deleted past the grace window. Re-trigger CI to rebuild.", 422)
          end

          unless target.file_object_id.present?
            return render_error("Target publication has no file_object — was it ever published?", 422)
          end

          # Gate-check before running the destructive transaction. On the
          # :proceed path the gate has ALREADY run the mutation — auto-
          # approved/core-mode decisions execute the executor synchronously
          # (Ai::DeferredOperation#execute_now!) — so the controller just
          # shapes its response from the executor's result instead of
          # duplicating the transaction (see System::Executors::DiskImage::
          # RollbackPublication, the same executor SystemFleetTool#revert_
          # disk_image delegates to for the MCP path).
          gate_result = ::Ai::AutonomyGate.evaluate(
            action_category: "system.disk_image_publication_rollback",
            executor_class: "System::Executors::DiskImage::RollbackPublication",
            params: { target_publication_id: target.id, platform_id: @platform.id },
            account: current_account,
            requested_by: current_user,
            source_type: "System::DiskImagePublication",
            source_id: target.id,
            description: "Roll back #{@platform.name} disk image to publication #{target.id}"
          )

          case gate_result.decision
          when :pending
            return render_pending_approval(gate_result.deferred_operation,
                                           message: "Approval required to roll back disk image")
          when :blocked
            return render_error(gate_result.error || "Action blocked by policy",
                                status: :unprocessable_content)
          end

          data = gate_result.result&.dig(:data) || {}
          previous_file_object_id = data[:previous_file_object_id]
          emit_rolled_back_event(target, previous_file_object_id)
          render_success(
            data: {
              platform_id:                @platform.id,
              activated_publication_id:   target.id,
              prior_file_object_id:       previous_file_object_id
            }
          )
        end

        private

        def set_platform
          @platform = @account.system_node_platforms.find(params[:platform_id] || params[:node_platform_id] || params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Platform")
        end

        def set_publication
          @publication = @platform.disk_image_publications.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("DiskImagePublication")
        end

        def serialize_one(pub)
          ::System::DiskImagePublicationSerializer.new(pub).as_json
        end

        def serialize_collection(pubs)
          pubs.map { |p| serialize_one(p) }
        end

        def emit_rolled_back_event(target, previous_active_id)
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account:  @account,
            kind:     "system.disk_image_rolled_back",
            severity: :medium,
            source:   "operator_ui",
            payload: {
              platform_id:                @platform.id,
              platform_name:              @platform.name,
              activated_publication_id:   target.id,
              activated_git_sha:          target.git_sha,
              prior_file_object_id:       previous_active_id,
              by_user_id:                 current_user&.id
            }
          )
        rescue StandardError => e
          Rails.logger.warn "[DiskImagePublications] rolled_back event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
