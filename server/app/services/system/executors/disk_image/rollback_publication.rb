# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class RollbackPublication < ::System::Executors::Base
        # Refused rather than silently no-op'd — see PromotePublication::
        # UnpromotablePublicationError and DiskImagePublication#promotable?.
        # This executor is also reachable from an approved DeferredOperation
        # minted before the target was purged (approval can land long after
        # the request), so the guard belongs here — re-checked at the moment
        # of mutation — not only in the callers that pre-check at request time
        # (DiskImagePublicationsController#rollback, SystemFleetTool#revert_
        # disk_image).
        class UnpromotablePublicationError < StandardError; end

        protected

        def perform
          target = ::System::DiskImagePublication.find(params[:target_publication_id])
          unless target.promotable?
            raise UnpromotablePublicationError,
                  "cannot roll back to publication #{target.id}: status=#{target.status} " \
                  "file_object_id=#{target.file_object_id.inspect} (must be published or " \
                  "retired with a live artifact)"
          end

          platform = if params[:platform_id]
                       ::System::NodePlatform.find(params[:platform_id])
          else
                       target.node_platform
          end
          previous_file_object_id = platform.disk_image_file_object_id

          ::ApplicationRecord.transaction do
            if target.retired?
              # Restore the file_object (soft-deleted) and reactivate the row
              # back to :published — otherwise it stays status=retired even
              # though it's now the platform's active image, and the next
              # purge sweep would treat it as purgeable. `restore!` is the
              # model's own soft-delete-undo helper (deleted_at/deleted_by
              # only — FileManagement::Object has no deleted_reason column).
              target.file_object.restore! if target.file_object&.deleted_at?
              target.reactivate
              target.save!
            end

            platform.update!(
              disk_image_file_object_id:     target.file_object_id,
              disk_image_sha256:             target.sha256,
              disk_image_size_bytes:         target.size_bytes,
              disk_image_oci_ref:            target.oci_ref,
              disk_image_git_sha:            target.git_sha,
              disk_image_publication_status: "published",
              disk_image_publication_error:  nil
            )

            if previous_file_object_id.present? && previous_file_object_id != target.file_object_id
              prior = platform.disk_image_publications
                              .where(file_object_id: previous_file_object_id, status: "published")
                              .first
              prior&.update!(status: "retired", retired_at: Time.current)
            end
          end

          emit_rolled_back_event(platform, target, previous_file_object_id)

          { rolled_back_to: target.id, platform_id: platform.id, previous_file_object_id: previous_file_object_id }
        end

        def summarize = "Roll back disk image to #{params[:target_publication_id]}"
        def impact    = "Reverts active publication — affects all new node provisions"

        private

        # THE ONLY emitter of system.disk_image_rolled_back, and it lives here
        # because this executor is the only arm that runs on every branch the
        # rollback completes on.
        #
        # DiskImagePublicationsController used to emit it from the arm reached
        # when policy resolves to proceed inline, and nothing emitted on the
        # approved branch — so a rollback that was parked, deliberated over and
        # approved rolled the platform back and recorded nothing. The seeded
        # policy for this category is require_approval, so on a deployment with
        # an approval chain the unrecorded path was the NORMAL one. The fleet
        # log held the automatic rollbacks and not the deliberate ones
        # (IMP-a18da6f5e05c).
        #
        # TWO OTHER DOORS reach this executor with `deferred_operation: nil` —
        # Ai::Tools::SystemFleetTool#revert_disk_image and
        # System::Ai::Skills::DiskImageRollbackExecutor. Both emitted nothing
        # before and now emit here. `requesting_user` is nil-safe for them
        # (System::Executors::Base), so this cannot raise, but the resulting
        # `by_user_id: nil` is LOSSY, not honest: both doors are gated on this
        # same category and their caller's identity exists one frame up, on
        # their own deferred operation. It is dropped at the call site, not
        # absent. Threading it through is filed separately; do not read a nil
        # here as "no human asked for this".
        #
        # PLACEMENT. Outside this executor's OWN transaction above, so a write
        # that rolled back cannot leave an event claiming it happened. It is
        # NOT outside every transaction: on the approval path the whole
        # executor runs inside ApprovalRequest's status-flip transaction
        # (ai/approval_request.rb, `after_update :notify_source_of_decision`,
        # which its own comment records as firing pre-commit). The FleetEvent
        # row joins that transaction and stays consistent with the pointer, but
        # the ActionCable broadcast does not — a subscriber can refresh before
        # the new pointer is visible. That is a property of the approval seam,
        # not of this emit.
        #
        # THE RESCUE IS NARROW ON PURPOSE. EventBroadcaster.emit! already
        # swallows its own failures and returns nil; the ONE thing it
        # deliberately re-raises is a schema deploy defect, because a missing
        # FleetEvent table would make every emission in the platform vanish at
        # WARN while everything read as healthy. Catching StandardError here
        # would defeat exactly that, so it is re-raised.
        def emit_rolled_back_event(platform, target, previous_active_id)
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account:  platform.account,
            kind:     "system.disk_image_rolled_back",
            severity: :medium,
            source:   "autonomy_executor",
            payload: {
              platform_id:                platform.id,
              platform_name:              platform.name,
              activated_publication_id:   target.id,
              activated_git_sha:          target.git_sha,
              prior_file_object_id:       previous_active_id,
              by_user_id:                 requesting_user&.id,
              deferred_operation_id:      deferred_operation&.id
            }
          )
        rescue StandardError => e
          raise if ::System::DeployDefect.schema?(e)

          Rails.logger.warn "[DiskImage::RollbackPublication] rolled_back event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
