# frozen_string_literal: true

module System
  # Cached package metadata from an upstream apt/rpm repository.
  #
  # One row per (package_repository, name, architecture, version) tuple — many
  # versions of the same package coexist (the upstream archive keeps history).
  # PackageRepositorySyncService upserts new rows on each sync and stamps
  # `obsoleted_at` on rows no longer in the upstream index (so PackageModuleLink
  # history isn't broken when upstream prunes old versions).
  #
  # Dependency-field shape (depends, recommends, pre_depends, etc.):
  #
  #   [
  #     [{"name" => "libc6", "op" => ">=", "version" => "2.34"}],          # AND
  #     [{"name" => "libssl3", "op" => nil,  "version" => nil},            # AND
  #      {"name" => "libssl1.1", "op" => nil,  "version" => nil}],         # OR within group
  #     ...
  #   ]
  #
  # Outer array = AND across required entries; inner array within each entry =
  # OR (apt's `a | b` alternatives). For rpm, capability deps (`/usr/bin/python3`)
  # are stored with op=nil, version=nil; the name is the capability string itself.
  class Package < BaseRecord
    # Intentionally does NOT include System::Base — Packages don't directly
    # belong to an account; they belong to a repository, which may or may not
    # be account-scoped. Account access flows through the repo.

    # === Associations ===
    belongs_to :package_repository, class_name: "System::PackageRepository"
    has_many :package_module_links,
             class_name: "System::PackageModuleLink",
             primary_key: [:package_repository_id, :name, :architecture],
             foreign_key: [:package_repository_id, :package_name, :architecture]

    # === Validations ===
    validates :name, presence: true
    validates :version, presence: true
    validates :architecture, presence: true

    # === Scopes ===
    scope :live,      -> { where(obsoleted_at: nil) }
    scope :obsoleted, -> { where.not(obsoleted_at: nil) }
    scope :for_arch,  ->(arch) { where(architecture: arch) }
    scope :for_name,  ->(name) { where(name: name) }

    # Find every package across the given repositories that provides `capability`
    # either directly (as its own name) or via its `provides` JSONB array.
    scope :providing, ->(capability, repos: nil, arch: nil) {
      base = live
      base = base.where(package_repository: repos) if repos
      base = base.where(architecture: arch) if arch
      base.where(
        "name = ? OR provides @> ?::jsonb",
        capability,
        [[{ name: capability }]].to_json
      )
    }

    # === Methods ===
    delegate :account_id, to: :package_repository
    delegate :account,    to: :package_repository

    def obsoleted?
      obsoleted_at.present?
    end

    def has_dependencies?
      depends.any? || pre_depends.any?
    end

    def has_recommends?
      recommends.any?
    end

    # Returns the full apt-style version string including epoch + release.
    # For rpm, glues release_version on (e.g., "3.0.13-1.fc40").
    def full_version
      return version if release_version.blank?

      "#{version}-#{release_version}"
    end
  end
end
