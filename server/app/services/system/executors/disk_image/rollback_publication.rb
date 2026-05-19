# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class RollbackPublication < ::System::Executors::Base
        protected

        def perform
          target = ::System::DiskImagePublication.find(params[:target_publication_id])
          platform = if params[:platform_id]
                       ::System::NodePlatform.find(params[:platform_id])
                     else
                       target.node_platform
                     end
          previous_file_object_id = platform.disk_image_file_object_id

          ::ApplicationRecord.transaction do
            # Restore the file_object if the target was retired (soft-deleted).
            if target.retired? && target.file_object&.deleted_at?
              target.file_object.update!(deleted_at: nil, deleted_reason: nil, deleted_by_id: nil)
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

          { rolled_back_to: target.id, platform_id: platform.id }
        end

        def summarize = "Roll back disk image to #{params[:target_publication_id]}"
        def impact    = "Reverts active publication — affects all new node provisions"
      end
    end
  end
end
