# frozen_string_literal: true

module System
  # Stores historical versions of node modules for rollback capability
  # Each version captures the complete state of a module at a point in time
  class NodeModuleVersion < BaseRecord
    # === Associations ===
    belongs_to :node_module, class_name: "System::NodeModule"
    belongs_to :created_by, class_name: "User", optional: true
    has_many   :module_artifacts, class_name: "System::ModuleArtifact", dependent: :destroy
    # The pinned planes serving this row (Environment campaign, incr. 4); the
    # FK cascades on delete.
    has_many   :environment_pins, class_name: "System::ModuleEnvironmentPin", dependent: :delete_all,
                                  inverse_of: :node_module_version

    # === Validations ===
    validates :version_number, presence: true,
                               numericality: { only_integer: true, greater_than: 0 },
                               uniqueness: { scope: :node_module_id }
    validates :node_module, presence: true

    # === Scopes ===
    scope :ordered, -> { order(version_number: :desc) }
    scope :by_version, -> { order(version_number: :asc) }
    scope :latest_first, -> { order(version_number: :desc) }
    scope :with_data_file, -> { where.not(data_file_name: nil) }

    # === Callbacks ===
    before_validation :set_version_number, on: :create

    # === Methods ===

    # Check if this version has a data file attached
    def has_data_file?
      data_file_name.present?
    end

    # Check if this is the current version for its module
    def current?
      node_module&.current_version_id == id
    end

    # Check if this is the latest version
    def latest?
      node_module&.versions&.maximum(:version_number) == version_number
    end

    # Get the previous version
    def previous_version
      return nil unless node_module

      node_module.versions.where("version_number < ?", version_number).order(version_number: :desc).first
    end

    # Get the next version
    def next_version
      return nil unless node_module

      node_module.versions.where("version_number > ?", version_number).order(version_number: :asc).first
    end

    # Verify data file integrity using checksum
    def verify_checksum(file_content)
      return false unless data_checksum.present?

      Digest::SHA256.hexdigest(file_content) == data_checksum
    end

    # Generate summary of what changed in this version
    def change_summary
      changelog.presence || "Version #{version_number}"
    end

    # === Where this version RUNS (Environment campaign, increment 4) ===
    # There is no per-version lifecycle label. A version either is what an
    # environment serves or it is not, and that is a fact about the
    # environment, not about the row: NodeModule#current_version_id for a
    # following plane, System::ModuleEnvironmentPin for a pinned one. Read it
    # through NodeModule#served_version_for(environment), and move it through
    # NodeModule#promote_in_environment!.
    #
    # The built -> staging -> blessed -> live -> retired ladder that used to
    # live here was deleted in increment 4b. It was decorative: no node-facing
    # surface read it, several versions of one module could sit at `live` at
    # once, and a version could be `live` while the fleet ran something else.
    # The evidence it claimed to gate on is real and survives as
    # System::Fleet::PromotionCriteria, now attached to a promotion INTO a
    # pinned environment — the one place where "the rung below has run this and
    # lived" is a question with an answer.

    # The pinned environments serving this exact version.
    def pinned_environments
      ::Ai::Environment.where(id: environment_pins.select(:environment_id))
    end

    # === erofs artifact helpers ===
    # Module versions carry one artifact format — erofs (Enhanced
    # Read-Only File System), universal across every Linux kernel
    # since 5.4. See AddArtifactsAndCapabilitiesForDualFormat
    # migration for the JSONB shape under `artifacts`.
    #
    # The schema was originally designed for a dual-format world
    # (composefs + squashfs); the single-key erofs JSONB shape is the
    # current implementation but leaves room for future formats if
    # they're ever needed.

    PRIMARY_ARTIFACT_FORMAT = "erofs"

    # Returns the artifact hash for the canonical format, or nil when
    # this version hasn't been published yet.
    def artifact
      return nil if artifacts.blank?
      artifacts[PRIMARY_ARTIFACT_FORMAT] || artifacts[PRIMARY_ARTIFACT_FORMAT.to_sym]
    end

    # True iff this version has a published erofs artifact.
    def published?
      artifact.present?
    end

    # Could this version actually SERVE the fleet if made current again?
    #
    # Stricter than #published?, and the distinction matters: on 2026-08-07 the
    # versions immediately preceding the two bad builds carried oci_digest nil,
    # so a naive "roll back to the previous row" would have repointed the fleet
    # at a version the agent cannot mount. Rollback must walk back to a version
    # that is genuinely usable, not merely the one before.
    #
    # Size is checked against the same floor a fresh publish must clear, so
    # rollback can't land on a known-empty artifact either. An ABSENT size is
    # treated as usable: older rows predate size recording, and refusing them
    # would block rollback to a perfectly good version — matching the
    # unknown-size-is-allowed call in the publish path.
    def rollback_usable?
      data = artifact
      return false if data.blank?
      return false if (data["oci_digest"] || data[:oci_digest]).blank?

      # FAIL OPEN on an unknown size, unlike the fresh-publish path: old version
      # rows predate size recording, and refusing them would block rollback to a
      # version known to have worked. See artifact_size_promotable?'s comment
      # for why the two readings differ on purpose.
      size = data["size"] || data[:size]
      return true if size.nil?

      ::System::ModulePublicationProcessor.artifact_size_promotable?(size)
    end

    private

    def set_version_number
      return if version_number.present?

      max_version = node_module&.versions&.maximum(:version_number) || 0
      self.version_number = max_version + 1
    end
  end
end
