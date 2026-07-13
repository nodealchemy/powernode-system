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
            if pub.retired?
              # Restore its file_object (soft-deleted) and reactivate the row
              # back to :published — otherwise it stays status=retired even
              # though it's now the platform's active image, and the next
              # purge sweep would treat it as purgeable.
              pub.file_object.update!(deleted_at: nil, deleted_reason: nil, deleted_by_id: nil) if pub.file_object&.deleted_at?
              pub.reactivate
              pub.save!
            end

            platform.update!(
              disk_image_file_object_id:     pub.file_object_id,
              disk_image_sha256:             pub.sha256,
              disk_image_size_bytes:         pub.size_bytes,
              disk_image_oci_ref:            pub.oci_ref,
              disk_image_git_sha:            pub.git_sha,
              # Standalone UKI artifact for in-place upgrades (campaign 019f505f
              # inc 2). Null on publications built before the UKI-publishing CI —
              # the in-place upgrade action fails closed when it's absent.
              disk_image_uki_oci_ref:        pub.uki_oci_ref,
              disk_image_uki_sha256:         pub.uki_sha256,
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
