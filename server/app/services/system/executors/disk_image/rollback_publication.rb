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

          { rolled_back_to: target.id, platform_id: platform.id, previous_file_object_id: previous_file_object_id }
        end

        def summarize = "Roll back disk image to #{params[:target_publication_id]}"
        def impact    = "Reverts active publication — affects all new node provisions"
      end
    end
  end
end
