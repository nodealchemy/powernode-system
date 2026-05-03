# frozen_string_literal: true

module System
  class NodePlatform < BaseRecord
    include System::Base

    # Associations
    belongs_to :account
    belongs_to :node_architecture, class_name: "System::NodeArchitecture"
    has_many :node_templates, class_name: "System::NodeTemplate", dependent: :restrict_with_error
    # has_many :node_modules will be added in Release 3

    # Disk-image publication history (Phase 2 — Chunk 1).
    # Plan: docs/plans/wondrous-yawning-anchor.md.
    has_many :disk_image_publications,
             class_name: "System::DiskImagePublication",
             dependent: :destroy

    # Convenience: the publication that the platform pointer currently
    # references. Useful in UI + serializer where "the active disk image"
    # is the operator-relevant view, not the full history list.
    has_one :active_disk_image_publication,
            -> { where(status: "published").order(created_at: :desc) },
            class_name: "System::DiskImagePublication"

    # Validations
    validates :name, presence: true, uniqueness: { scope: :account_id }
    validates :disk_image_retention_count,
              numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 50 },
              allow_nil: true

    # Cosign trust is "configured" when both regexps are non-blank.
    # The DiskImageOciIngestService refuses publication when either is
    # missing — we'd rather fail closed than silently accept an unsigned
    # blob (or one signed by an arbitrary identity).
    def cosign_trust_configured?
      cosign_identity_regexp.present? && cosign_issuer_regexp.present?
    end
  end
end
