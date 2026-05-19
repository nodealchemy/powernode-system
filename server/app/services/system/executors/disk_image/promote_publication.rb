# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class PromotePublication < ::System::Executors::Base
        protected

        def perform
          pub = ::System::DiskImagePublication.find(params[:publication_id])
          platform = pub.node_platform
          previous_file_object_id = platform.disk_image_file_object_id

          ::ApplicationRecord.transaction do
            # If the publication had been retired, restore its file_object
            # before flipping the platform pointer.
            if pub.retired? && pub.file_object&.deleted_at?
              pub.file_object.update!(deleted_at: nil, deleted_reason: nil, deleted_by_id: nil)
            end

            platform.update!(
              disk_image_file_object_id:     pub.file_object_id,
              disk_image_sha256:             pub.sha256,
              disk_image_size_bytes:         pub.size_bytes,
              disk_image_oci_ref:            pub.oci_ref,
              disk_image_git_sha:            pub.git_sha,
              disk_image_publication_status: "published",
              disk_image_publication_error:  nil
            )

            if previous_file_object_id.present? && previous_file_object_id != pub.file_object_id
              prior = platform.disk_image_publications
                              .where(file_object_id: previous_file_object_id, status: "published")
                              .first
              prior&.update!(status: "retired", retired_at: Time.current)
            end
          end

          { publication_id: pub.id, platform_id: platform.id, promoted: true }
        end

        def summarize
          pub = ::System::DiskImagePublication.find_by(id: params[:publication_id])
          pub ? "Promote disk image #{pub.try(:tag) || pub.id} to active" : "Promote disk image"
        end

        def impact = "All new node provisions will boot from this image"
      end
    end
  end
end
