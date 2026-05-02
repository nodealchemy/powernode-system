# frozen_string_literal: true

module System
  # OCI-stored module artifact for a NodeModuleVersion + architecture pair.
  # Each (version, arch) tuple has at most one artifact; multi-arch releases
  # are represented as multiple ModuleArtifact rows under the same version.
  #
  # Provenance fields (sbom_uri, provenance_uri, vex_uri) point at OCI
  # referrer blobs co-located with the main artifact in the registry.
  #
  # Reference: Golden Eclipse M0.L; plan M1 supply chain.
  class ModuleArtifact < BaseRecord
    include System::Base

    # === Constants ===
    SUPPORTED_ARCHITECTURES = %w[amd64 arm64].freeze
    DEFAULT_MEDIA_TYPE      = "application/vnd.powernode.module.v1"

    # === Associations ===
    belongs_to :node_module_version, class_name: "System::NodeModuleVersion"
    delegate :node_module, to: :node_module_version
    delegate :account, to: :node_module

    # === Validations ===
    validates :oci_ref,      presence: true
    validates :oci_digest,   presence: true,
                             format: { with: /\Asha\d{3}:[a-f0-9]+\z/, message: "must look like 'sha256:<hex>'" }
    validates :media_type,   presence: true
    validates :architecture, presence: true, inclusion: { in: SUPPORTED_ARCHITECTURES }
    validates :size_bytes,   numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :built_at,     presence: true
    validates :node_module_version_id,
              uniqueness: { scope: :architecture,
                            message: "already has an artifact for this architecture" }

    # === Scopes ===
    scope :for_arch, ->(arch) { where(architecture: arch) }
    scope :amd64,    -> { for_arch("amd64") }
    scope :arm64,    -> { for_arch("arm64") }
    scope :signed,   -> { where.not(cosign_bundle: nil) }
    scope :verified_provenance, -> { where.not(provenance_uri: nil) }

    # === Methods ===

    # Convenience predicate — does this artifact carry full supply-chain
    # provenance (signature + SBOM + provenance attestation)?
    def fully_attested?
      cosign_bundle.present? && sbom_uri.present? && provenance_uri.present?
    end

    # The fs-verity Merkle root (hex). Used by ipn-agent to verify the
    # composefs lower at file-open time.
    def has_fsverity?
      fsverity_root_hash.present?
    end
  end
end
