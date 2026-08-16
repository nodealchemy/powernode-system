# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class PromotePublication < ::System::Executors::Base
        # Refused rather than silently no-op'd — see DiskImagePublication
        # #promotable? for why neither status nor published_at alone is a
        # sufficient guard, and #reactivate for the whiny_transitions:false
        # trap this class deliberately does NOT rely on (an AASM guard
        # failure here would leave the row untouched but say nothing, and
        # this executor's own platform.update! would run anyway since it's
        # a plain method call, not gated by the AASM transition at all).
        class UnpromotablePublicationError < StandardError; end

        protected

        def perform
          pub = ::System::DiskImagePublication.find(params[:publication_id])
          unless pub.promotable?
            raise UnpromotablePublicationError,
                  "cannot promote publication #{pub.id}: status=#{pub.status} " \
                  "file_object_id=#{pub.file_object_id.inspect} (must be published or " \
                  "retired with a live artifact)"
          end

          platform = pub.node_platform
          previous_file_object_id = platform.disk_image_file_object_id

          ::ApplicationRecord.transaction do
            if pub.retired?
              # Restore its file_object (soft-deleted) and reactivate the row
              # back to :published — otherwise it stays status=retired even
              # though it's now the platform's active image, and the next
              # purge sweep would treat it as purgeable. `restore!` is the
              # model's own soft-delete-undo helper (deleted_at/deleted_by
              # only — FileManagement::Object has no deleted_reason column;
              # see RollbackPublication, which already did this correctly).
              pub.file_object.restore! if pub.file_object&.deleted_at?
              pub.reactivate
              pub.save!
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

        # IMP-8e4674f4d62d: anchored to the operation's account, though nothing
        # previews this executor today — its one caller
        # (Ai::Tools::SystemFleetTool#set_default_disk_image_publication)
        # invokes `.execute` directly with `deferred_operation: nil`, so no
        # approval card renders it. Pinned rather than left to the wiring
        # (the CreatePeer precedent): `system.disk_image_publication_promote`
        # IS a registered action category with a seeded require_approval
        # policy, so the day a gate site names this class the label would have
        # gone out unscoped.
        #
        # Same shape as the VIP verbs: `pub.try(:tag)` is a DEAD rung
        # (System::DiskImagePublication has no `tag`), so the named arm renders
        # the id and what the card discloses is EXISTENCE. The no-name arm
        # therefore stays id-free — see delete_virtual_ip.rb for why.
        def summarize
          pub = scoped_label_record(::System::DiskImagePublication, params[:publication_id])
          pub ? "Promote disk image #{pub.try(:tag) || pub.id} to active" : "Promote disk image"
        end

        def impact = "All new node provisions will boot from this image"
      end
    end
  end
end
