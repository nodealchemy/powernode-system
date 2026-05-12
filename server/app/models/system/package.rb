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

    # Enables `.nearest_neighbors(:embedding, vec, distance: "cosine")` via
    # the `neighbor` gem. Populated by SystemPackageEmbeddingJob (worker-side).
    has_neighbors :embedding

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
    scope :live,             -> { where(obsoleted_at: nil) }
    scope :obsoleted,        -> { where.not(obsoleted_at: nil) }
    scope :for_arch,         ->(arch) { where(architecture: arch) }
    scope :for_name,         ->(name) { where(name: name) }
    scope :with_embedding,   -> { where.not(embedding: nil) }
    scope :without_embedding,-> { where(embedding: nil) }

    # Lease-ordering SQL for the embedding pipeline. Ordering, top-to-bottom:
    #
    #   1. NULL embeddings first (existing — embed unembedded rows before re-embeds)
    #   2. Packages already materialized into a NodeModule — operators have
    #      built modules from them, so they're operationally important.
    #      Signal: EXISTS row in system_package_module_links.
    #   3. Operationally-relevant section_or_group — web/httpd, mail, net,
    #      database, admin, kernel, then defaults. Handles both Debian
    #      ("httpd") and Ubuntu ("universe/httpd") naming via regex.
    #   4. Packages that declare provides (capability-providers like
    #      mail-transport-agent, http-server, etc.) before plain libraries.
    #      Defensive `jsonb_typeof = 'array'` check — a handful of legacy
    #      rows have provides stored as a stringified JSON instead of a
    #      native JSONB array, and `jsonb_array_length` on a scalar errors
    #      out with "cannot get array length of a scalar."
    #   5. updated_at DESC as final tiebreaker (preserves the old behavior).
    #
    # Replaces the prior `embedding_generated_at NULLS FIRST, updated_at DESC`
    # ordering, which embedded operationally-canonical packages
    # (nginx, haproxy, redis-server) in the trailing tail — operators saw
    # "useful but not canonical" search results for the first ~90 minutes of
    # the bootstrap backfill. With this ordering, popular packages embed in
    # the leading 5% of any future re-embed campaign.
    def self.lease_order_sql
      Arel.sql(<<~SQL.squish)
        embedding_generated_at NULLS FIRST,
        EXISTS (
          SELECT 1 FROM system_package_module_links pml
          WHERE pml.package_repository_id = system_packages.package_repository_id
            AND pml.package_name = system_packages.name
            AND pml.architecture = system_packages.architecture
        ) DESC,
        CASE
          WHEN system_packages.section_or_group ~ '(^|/)(httpd|web)$' THEN 100
          WHEN system_packages.section_or_group ~ '(^|/)mail$' THEN 90
          WHEN system_packages.section_or_group ~ '(^|/)(database|databases)$' THEN 85
          WHEN system_packages.section_or_group ~ '(^|/)net$' THEN 80
          WHEN system_packages.section_or_group ~ '(^|/)admin$' THEN 70
          WHEN system_packages.section_or_group ~ '(^|/)kernel$' THEN 60
          WHEN system_packages.section_or_group ~ '(^|/)(shells|interpreters)$' THEN 40
          ELSE 0
        END DESC,
        CASE
          WHEN jsonb_typeof(system_packages.provides) = 'array'
               AND jsonb_array_length(system_packages.provides) > 0
          THEN 1 ELSE 0
        END DESC,
        system_packages.updated_at DESC
      SQL
    end

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

    # Flattens the JSONB `provides` array of-arrays-of-{name,op,version} hashes
    # down to a simple list of capability names. Used by embedding_text + by
    # serializers that surface "what this package provides" for AI/operators.
    def provides_capabilities
      Array(provides).flatten.filter_map { |entry| entry.is_a?(Hash) ? entry["name"] : nil }.uniq
    end

    # Composed once, here, so re-embed campaigns produce identical input.
    # Truncate description to 2000 chars — OpenAI text-embedding-3-small caps
    # at 8191 tokens but most useful signal is in the first paragraph plus
    # the structured fields below.
    def embedding_text
      capabilities = provides_capabilities
      <<~TEXT.strip
        #{name} v#{version} (#{architecture}) — #{summary}

        #{description.to_s.truncate(2000)}

        Section: #{section_or_group}
        License: #{license}
        Maintainer: #{maintainer}
        Provides: #{capabilities.join(', ')}
      TEXT
    end

    # Virtual attribute set by pgvector's nearest_neighbors scope. Mirrors
    # the pattern on Ai::KnowledgeGraphNode.
    def neighbor_distance
      self[:neighbor_distance]
    end
  end
end
