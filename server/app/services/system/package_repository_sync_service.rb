# frozen_string_literal: true

module System
  # Synchronizes an apt/rpm package-repository's upstream catalog into the
  # local system_packages cache.
  #
  # Flow per call:
  #   1. Mark repository sync_status="syncing"
  #   2. Adapter fetches index files + parses → yields ParsedPackage entries
  #   3. Batch-upsert in 1000-row chunks
  #   4. Soft-delete (obsoleted_at) Package rows not seen in this run
  #   5. Mark repository sync_status="idle" + last_synced_at + package_count
  #
  # On error: marks sync_status="failed" + last_sync_error; does NOT clear
  # existing Package rows or obsoleted_at stamps (preserving prior state).
  #
  # Idempotent: re-syncing produces no net DB change when upstream is unchanged.
  class PackageRepositorySyncService
    BATCH_SIZE = 1000

    Result = Struct.new(:success, :package_count, :upserted, :obsoleted, :error, keyword_init: true) do
      def success?
        success == true
      end
    end

    def self.call(repository:, architectures: nil)
      new(repository: repository, architectures: architectures).call
    end

    def initialize(repository:, architectures: nil)
      @repository = repository
      # PackageRepository.architectures stores canonical names (post-T2.A).
      # Adapters need kind-specific names for URL construction
      # (apt's `binary-<arch>` paths, rpm's `--forcearch`). Translate at
      # the boundary via architectures_for_kind. The `architectures:`
      # override kwarg is treated as already kind-specific — used by
      # tests and ad-hoc CLI invocations that want to force a specific
      # set without canonicalization.
      @architectures =
        architectures.presence ||
        repository.architectures_for_kind.presence ||
        default_architecture_for(repository.kind)
    end

    def call
      @repository.mark_syncing!
      sync_start = Time.current
      upserted_count = upsert_packages
      obsoleted = soft_delete_unseen(since: sync_start)
      package_count = ::System::Package
        .where(package_repository_id: @repository.id, obsoleted_at: nil)
        .count
      @repository.mark_synced!(package_count: package_count)
      # Package rows landed via upsert_all (no callbacks); refresh the
      # arch-level package_count counter so the catalog UI's Usage column
      # stays honest. Cheap (~N=arch_count SELECT COUNTs) and idempotent.
      ::System::NodeArchitecture.recompute_package_counts!

      Result.new(
        success: true,
        package_count: package_count,
        upserted: upserted_count,
        obsoleted: obsoleted,
        error: nil
      )
    rescue StandardError => e
      Rails.logger.error("[PackageRepositorySync] #{@repository.name} failed: #{e.class}: #{e.message}")
      @repository.mark_sync_failed!(e.message)
      Result.new(success: false, package_count: 0, upserted: 0, obsoleted: 0, error: e.message)
    end

    private

    # Streams adapter output, batching into upserts. Returns count of upserted rows.
    # Detection of unseen rows is via `updated_at < sync_start` after the run
    # (upsert_all touches updated_at on every match, so anything not touched
    # by this run is, by definition, no longer in the upstream index).
    def upsert_packages
      adapter = ::System::PackageAdapters.for(kind: @repository.kind)
      count = 0
      buffer = []

      adapter.sync_metadata(repository: @repository, architectures: @architectures) do |parsed|
        buffer << build_row(parsed)
        count += 1
        if buffer.size >= BATCH_SIZE
          flush(buffer)
          buffer.clear
        end
      end
      flush(buffer) if buffer.any?
      count
    end

    def build_row(parsed)
      now = Time.current
      {
        package_repository_id: @repository.id,
        name:                  parsed.name,
        version:               parsed.version,
        architecture:          parsed.architecture,
        release_version:       parsed.release_version,
        section_or_group:      parsed.section_or_group,
        description:           parsed.description,
        summary:               parsed.summary,
        installed_size_bytes:  parsed.installed_size_bytes,
        download_size_bytes:   parsed.download_size_bytes,
        depends:        parsed.depends.to_json,
        pre_depends:    parsed.pre_depends.to_json,
        recommends:     parsed.recommends.to_json,
        suggests:       parsed.suggests.to_json,
        conflicts:      parsed.conflicts.to_json,
        provides:       parsed.provides.to_json,
        replaces:       parsed.replaces.to_json,
        breaks:         parsed.breaks.to_json,
        filename:       parsed.filename,
        sha256:         parsed.sha256,
        sha512:         parsed.sha512,
        homepage:       parsed.homepage,
        license:        parsed.license,
        maintainer:     parsed.maintainer,
        raw_metadata:   parsed.raw_metadata.to_json,
        obsoleted_at:   nil,
        created_at:     now,
        updated_at:     now
      }
    end

    def flush(buffer)
      return if buffer.empty?

      # `update_only` must NOT include `updated_at`: Rails 7.1+ already
      # appends `updated_at = NOW()` to the ON CONFLICT SET clause when
      # `record_timestamps: true` (the default). Listing it here too
      # produces a duplicate column assignment and PG raises
      # "multiple assignments to same column updated_at".
      ::System::Package.upsert_all(
        buffer,
        unique_by: :idx_pkg_repo_name_arch_ver,
        update_only: %i[
          release_version section_or_group description summary
          installed_size_bytes download_size_bytes
          depends pre_depends recommends suggests conflicts provides replaces breaks
          filename sha256 sha512 homepage license maintainer raw_metadata
          obsoleted_at
        ]
      )
    end

    def soft_delete_unseen(since:)
      # Rows that survived this sync had updated_at touched by upsert_all
      # (Rails always rewrites updated_at on conflict, even when no other
      # columns changed). Rows older than the sync start are definitionally
      # missing from the latest upstream index → mark obsoleted.
      ::System::Package
        .where(package_repository_id: @repository.id)
        .where(obsoleted_at: nil)
        .where("updated_at < ?", since)
        .update_all(obsoleted_at: Time.current)
    end

    # Fallback when a repo has no architectures set — pick the kind's
    # default. apt's `amd64` and rpm's `x86_64` are the safest baseline
    # choices and match what the form would default to.
    def default_architecture_for(kind)
      kind.to_s == "apt" ? ["amd64"] : ["x86_64"]
    end
  end
end
