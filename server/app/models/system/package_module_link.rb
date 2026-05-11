# frozen_string_literal: true

module System
  # 1:1 link between a System::NodeModule and the upstream apt/rpm package it
  # was materialized from. Created by PackageModuleMaterializer.
  #
  # Two roles in one table, distinguished by `auto_generated`:
  #
  #   auto_generated=false → top-level package the operator explicitly picked.
  #     `recommends_chosen` holds the operator's per-edge selection from the
  #     materialize-time UI. This is the row that drives refresh semantics.
  #
  #   auto_generated=true  → transitive dependency pulled in by closure
  #     resolution. `recommends_chosen` is empty (transitive deps don't
  #     themselves carry per-edge selections; they were pulled because
  #     someone else's selection cascaded them in).
  #
  # NOT scoped to account directly — account access flows via node_module.
  class PackageModuleLink < BaseRecord
    FILE_SPEC_SOURCES = %w[manual package_query].freeze

    # === Associations ===
    belongs_to :node_module, class_name: "System::NodeModule"
    belongs_to :package_repository, class_name: "System::PackageRepository"

    # Convenience back-ref to the upstream Package metadata for this link.
    # NOT a hard FK because Package rows may be obsoleted_at without
    # invalidating an existing link (we keep the historical materialization).
    def package
      ::System::Package.find_by(
        package_repository_id: package_repository_id,
        name:                  package_name,
        architecture:          architecture,
        version:               package_version
      )
    end

    # === Validations ===
    validates :package_name, presence: true
    validates :package_version, presence: true
    validates :architecture, presence: true
    validates :file_spec_source, inclusion: { in: FILE_SPEC_SOURCES }

    # Note: NO uniqueness validation on (package_repository_id, package_name,
    # architecture). Two accounts may each materialize "nginx" from the same
    # shared repo, producing two PackageModuleLink rows pointing at different
    # NodeModules. Uniqueness on (node_module_id) is enforced by the DB index.

    # === Scopes ===
    scope :auto_generated_only, -> { where(auto_generated: true) }
    scope :top_level_only,      -> { where(auto_generated: false) }
    scope :for_arch, ->(arch)   { where(architecture: arch) }
    scope :for_repo, ->(repo)   { where(package_repository_id: repo.id) }

    # === Account scope delegation ===
    delegate :account, to: :node_module
    delegate :account_id, to: :node_module

    # === Methods ===

    # Stale iff the upstream Package version exceeds this link's package_version
    # (per the adapter's compare_versions). Used by PackageDriftSensor.
    def stale?
      upstream = ::System::Package.live.find_by(
        package_repository_id: package_repository_id,
        name: package_name,
        architecture: architecture
      )
      return false unless upstream

      adapter = ::System::PackageAdapters.for(kind: package_repository.kind)
      adapter.compare_versions(upstream.version, package_version) > 0
    end

    # Returns whether this link's recommends_chosen list includes the given
    # package name. Used by TemplateExpansionService when computing the
    # effective recommends set for a (template, module) pair.
    def includes_recommends?(package_name)
      Array(recommends_chosen).include?(package_name)
    end
  end
end
