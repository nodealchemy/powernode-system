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

          # The executor performs the rollback and emits the fleet event; this
          # only renders the outcome. On the :proceed path the gate has ALREADY
          # run it — auto-approved and core-mode decisions execute the executor
          # synchronously (Ai::DeferredOperation#execute_now!).
          #
          # This used to call Ai::AutonomyGate.evaluate and dispatch on the
          # decision by hand, which is what let the event emitter sit on the
          # inline arm alone: Ai::GatedActions documents that a domain event
          # belongs to the executor, and a controller that does not route
          # through the concern never reads the concern (IMP-a18da6f5e05c). The
          # hand-rolled version answered identically on all three branches
          # apart from the 202's message, which `pending_message:` carries.
          gate!(
            action_category: "system.disk_image_publication_rollback",
            executor_class: "System::Executors::DiskImage::RollbackPublication",
            params: { target_publication_id: target.id, platform_id: @platform.id },
            source_type: "System::DiskImagePublication",
            source_id: target.id,
            description: "Roll back #{@platform.name} disk image to publication #{target.id}",
            pending_message: "Approval required to roll back disk image",
            on_proceed: ->(result) {
              data = result.result&.dig(:data) || {}
              render_success(
                data: {
                  platform_id:                @platform.id,
                  activated_publication_id:   target.id,
                  prior_file_object_id:       data[:previous_file_object_id]
                }
              )
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
      end
    end
  end
end
