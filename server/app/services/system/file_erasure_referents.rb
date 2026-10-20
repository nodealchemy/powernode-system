# frozen_string_literal: true

module System
  # This extension's handler on core's FileManagement::ErasureReferentRegistry
  # seam (IMP-d97f6e3bbc2b). Three columns here point at file_objects — two
  # through NO ACTION foreign keys with no inverse association, which made a
  # GDPR erasure of a referenced file raise InvalidForeignKey, and one
  # unconstrained pointer (architectures no longer hold boot-file pointers;
  # images are generic per platform, IMP-c7e9b31f7498):
  #
  #   system_disk_image_publications.file_object_id / prior_file_object_id
  #     — a published disk image and the one it replaced (rollback substrate)
  #   system_node_platforms.disk_image_file_object_id
  #     — the platform's live boot-image pointer (no FK; same artifact)
  #
  # Posture: HOLD, never release. Every one of these binds a platform
  # boot/rollback artifact; nullifying it underneath a running fleet would
  # corrupt a boot-image pointer or a rollback history. The file is refused
  # with a reason naming the holder, and core reports it as a gap rather than
  # an erasure. In practice core's category policy (FileManagement::Erasure::
  # PERSONAL_CATEGORIES) keeps `disk_image` / `system` files out of scope
  # already; this is the guard for a personal-category upload an operator
  # promoted into one of these roles. Registered as :system_boot_images in
  # lib/powernode_system/engine.rb.
  class FileErasureReferents
    HOLDERS = [
      [ "held_by_system_disk_image_publication", ->(ids) {
        ::System::DiskImagePublication
          .where(file_object_id: ids).or(::System::DiskImagePublication.where(prior_file_object_id: ids))
          .pluck(:file_object_id, :prior_file_object_id)
      } ],
      [ "held_by_system_node_platform", ->(ids) {
        ::System::NodePlatform.where(disk_image_file_object_id: ids).pluck(:disk_image_file_object_id)
      } ]
    ].freeze

    def self.call(action, payload)
      case action
      when :holds then holds(Array(payload))
      when :release then nil
      end
    end

    # { file_object_id => reason } for every id one of the holders points
    # at. A row's other pointer columns come back from the pluck too; only
    # ids in the batch are reported.
    def self.holds(ids)
      return {} if ids.empty?

      wanted = ids.to_set
      HOLDERS.each_with_object({}) do |(reason, lookup), held|
        lookup.call(ids).flatten.compact.each do |id|
          held[id] ||= reason if wanted.include?(id)
        end
      end
    end
  end
end
