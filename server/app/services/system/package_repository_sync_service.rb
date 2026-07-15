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

    # Bump when the parse/build logic (parse_dependency_string, build_row,
    # to_parsed_package…) changes in a way that should refresh already-stored
    # rows. Change-detection skips unchanged tuples, so a repo last synced with
    # an older parser is force-reparsed ONCE (parser_version column) to heal
    # stale metadata — restoring the auto-heal the always-upsert path had.
    PARSER_VERSION = 1

    # Per-KIND overrides — bump a kind's number when THAT adapter's parse/store
    # format changes, so only repos of that kind reparse (apt stays put). rpm/dnf
    # went to 2 when `version` switched from bare version to full EVR
    # (epoch:version-release); existing rpm rows reparse once from bare→EVR.
    PARSER_VERSIONS = { "rpm" => 2, "dnf" => 2 }.freeze

    # Fraction of a repo's active packages that may be obsoleted in one sync
    # before the run is refused as a likely partial-upstream failure (a mirror
    # mid-publish 404ing a slice). Operator-tunable; `force:` overrides.
    OBSOLETE_GUARD_SETTING = "system.package_repository.obsolete_guard_fraction"
    DEFAULT_OBSOLETE_GUARD_FRACTION = 0.2

    # Raised when a sync would obsolete a suspicious share of the catalog
    # (empty upstream or a partial fetch) — fail closed instead of nuking rows.
    class SyncGuardError < StandardError; end

    Result = Struct.new(:success, :package_count, :upserted, :obsoleted, :error, keyword_init: true) do
      def success?
        success == true
      end
    end

    def self.call(repository:, architectures: nil, force: false)
      new(repository: repository, architectures: architectures, force: force).call
    end

    # Schedule an async sync instead of running it inline. Marks the repo
    # `syncing` and enqueues the worker job (SystemPackageRepositorySyncJob),
    # which POSTs worker_api and spawns the detached out-of-puma sync process.
    # EVERY operator/API/MCP/agent entry point must use this — only the spawned
    # PackageRepositoryBackgroundSync calls `.call` to do the work. A full sync
    # is a minutes-long, memory-heavy job: running it inline blocks the caller
    # and (in puma) inflates RSS past the worker recycler, killing the request
    # worker. `force` is coerced so callers can pass a raw param value.
    def self.enqueue!(repository:, force: false)
      coerced = ::ActiveModel::Type::Boolean.new.cast(force) || false
      repository.update!(sync_status: "syncing", last_sync_error: nil)
      ::System::WorkerJobEnqueuer.enqueue(
        job_class: "SystemPackageRepositorySyncJob",
        args:      [ repository.id, { "force" => coerced } ],
        queue:     "system"
      )
      repository
    end

    def initialize(repository:, architectures: nil, force: false)
      @repository = repository
      # force: re-write EVERY package row even if its (name,version,arch) is
      # unchanged — the escape hatch for refreshing stored metadata after a
      # parser change. Default false uses change-detection (skip unchanged).
      @force = force
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
      # Concurrency guard (Postgres session advisory lock keyed on the repo).
      # A full sync is a minutes-to-hours operation; without this, a retry, the
      # daily tick, or a second "Sync now" click could start a SECOND concurrent
      # sync of the same repo — the two fight over the same rows (contention,
      # wasted work, and a CardinalityViolation-class hazard). A second attempt
      # while one is in flight becomes a fast no-op. Doubles as stale-sync
      # recovery: if a prior sync's process died, its session lock is already
      # released, so the next attempt simply proceeds and re-marks the repo.
      conn = ::System::Package.connection
      unless conn.select_value("SELECT pg_try_advisory_lock(#{advisory_lock_key})")
        Rails.logger.info("[PackageRepositorySync] #{@repository.name}: already syncing (advisory lock held) — skipping duplicate")
        return Result.new(success: false, package_count: @repository.package_count.to_i,
                          upserted: 0, obsoleted: 0, error: "already syncing")
      end

      begin
        call_locked
      ensure
        conn.select_value("SELECT pg_advisory_unlock(#{advisory_lock_key})")
      end
    end

    # Stable 63-bit signed key from the repo UUID (fits a Postgres bigint).
    def advisory_lock_key
      ::Digest::SHA256.hexdigest("pkgrepo-sync:#{@repository.id}").to_i(16) % (2**63)
    end

    def call_locked
      @repository.mark_syncing!
      adapter = ::System::PackageAdapters.for(kind: @repository.kind)

      # A parser bump forces one full reparse to refresh stored metadata (see
      # PARSER_VERSION); operator force does the same.
      effective_force = @force || parser_stale?

      # FINGERPRINT FAST-PATH: fetch just the small index metadata; if its
      # digest matches the last successful sync AND we aren't force-reparsing,
      # nothing changed upstream — skip fetch+parse+diff of the full catalog
      # entirely (the common "daily tick, nothing changed" case). nil digest
      # (adapter can't compute one / fetch failed) falls through to a full sync.
      fingerprint = safe_fingerprint(adapter)
      if !effective_force && fingerprint.present? && fingerprint == @repository.sync_fingerprint
        package_count = active_package_count
        finalize_synced!(fingerprint, package_count)
        Rails.logger.info("[PackageRepositorySync] #{@repository.name}: fingerprint unchanged — skipped (fast-path)")
        return Result.new(success: true, package_count: package_count, upserted: 0, obsoleted: 0, error: nil)
      end

      stats = sync_packages(adapter, force: effective_force)
      package_count = active_package_count
      finalize_synced!(fingerprint, package_count)

      # Only NEW packages need embeddings — existing rows keep theirs. A force
      # reparse may change descriptions, so re-embed then too. Pushed via
      # WorkerJobEnqueuer (server has no Sidekiq gem; we LPUSH the queue).
      if stats[:inserted].positive? || effective_force
        ::System::WorkerJobEnqueuer.enqueue(
          job_class: "SystemPackageEmbeddingJob",
          args:      [ @repository.id, {} ],
          queue:     "system"
        )
      end

      Result.new(
        success: true,
        package_count: package_count,
        upserted: stats[:inserted],
        obsoleted: stats[:obsoleted],
        error: nil
      )
    rescue StandardError => e
      Rails.logger.error("[PackageRepositorySync] #{@repository.name} failed: #{e.class}: #{e.message}")
      @repository.mark_sync_failed!(e.message)
      Result.new(success: false, package_count: 0, upserted: 0, obsoleted: 0, error: e.message)
    end

    private

    # Dispatch: apt — whose (name, version, architecture) IS a package's full
    # immutable identity (Version carries epoch + revision) — uses change-
    # detection (skip unchanged rows). rpm falls back to the full upsert path:
    # the rpm adapter stores only the bare `version` (not epoch:ver-release),
    # so its stored tuple is NOT a unique identity and skipping-if-present would
    # freeze release-only errata. `force` (operator or parser bump) always does
    # a full rewrite. Returns { inserted:, obsoleted:, reactivated:, seen: }.
    def sync_packages(adapter, force:)
      if change_detection_eligible? && !force
        sync_changed_only(adapter)
      else
        sync_full(adapter)
      end
    end

    def change_detection_eligible?
      # apt's full Debian version and rpm/dnf's full EVR (both stored in
      # `version`) are immutable per-artifact identities, so an existing
      # (name, arch, version) tuple can be skipped safely.
      %w[apt rpm dnf].include?(@repository.kind.to_s)
    end

    # Change-detection (apt). An existing (name, version, arch) tuple names the
    # exact same immutable artifact, so it is skipped entirely (no rewrite, no
    # index churn). Only three sets are written: NEW tuples (insert), tuples
    # that VANISHED upstream (obsolete), previously-obsoleted tuples that
    # REAPPEARED (reactivate). Turns a re-sync of a mostly-unchanged repo from
    # ~hundreds-of-thousands of rewrites into a handful.
    def sync_changed_only(adapter)
      existing = load_existing_keys # { key => obsoleted_bool }
      seen       = Set.new
      reactivate = []
      buffer     = []
      inserted   = 0

      adapter.sync_metadata(repository: @repository, architectures: @architectures) do |parsed|
        key = row_key(parsed.name, parsed.architecture, parsed.version)
        next if seen.include?(key) # an index can list a tuple twice (multi-component)

        seen << key
        if existing.key?(key)
          reactivate << key if existing[key] # was obsoleted → reappeared
          # existing && active → unchanged: skip (the whole point)
        else
          buffer << build_row(parsed)
          inserted += 1
        end

        if buffer.size >= BATCH_SIZE
          flush(buffer)
          buffer.clear
        end
      end
      flush(buffer) if buffer.any?

      reactivated = set_obsoleted(reactivate, nil)
      to_obsolete = existing.reject { |k, obs| obs || seen.include?(k) }.keys
      guard_obsoletion!(seen_count: seen.size, active_count: existing.count { |_k, obs| !obs }, obsolete_count: to_obsolete.size)
      obsoleted = set_obsoleted(to_obsolete, Time.current)

      Rails.logger.info(
        "[PackageRepositorySync] #{@repository.name}: seen=#{seen.size} inserted=#{inserted} " \
        "reactivated=#{reactivated} obsoleted=#{obsoleted} unchanged=#{seen.size - inserted - reactivated}"
      )
      { inserted: inserted, obsoleted: obsoleted, reactivated: reactivated, seen: seen.size }
    end

    # Full upsert (rpm / force / parser bump): rewrite every row, then soft-
    # delete the tuples this run did not touch (updated_at < sync_start). The
    # pre-change-detection behavior, correct for formats whose stored key isn't
    # a full immutable identity and for a deliberate metadata refresh.
    def sync_full(adapter)
      count = 0
      buffer = []
      sync_start = Time.current
      adapter.sync_metadata(repository: @repository, architectures: @architectures) do |parsed|
        buffer << build_row(parsed)
        count += 1
        if buffer.size >= BATCH_SIZE
          flush(buffer)
          buffer.clear
        end
      end
      flush(buffer) if buffer.any?
      obsoleted = soft_delete_unseen(since: sync_start, seen_count: count)
      { inserted: count, obsoleted: obsoleted, reactivated: 0, seen: count }
    end

    # Fail closed on a mass-obsoletion that almost certainly reflects a broken
    # upstream (empty index, or a mirror mid-publish 404ing a whole
    # component/arch slice) rather than real deletions — otherwise the sync
    # nukes tens of thousands of live rows, then reactivates them next run.
    def guard_obsoletion!(seen_count:, active_count:, obsolete_count:)
      # Explicit operator force is a deliberate override (e.g. an intentional
      # large prune, or overriding a false-positive on a small repo).
      return if @force

      # An empty upstream is ALWAYS a failure (mirror/publish outage) — never
      # auto-bypass, even during a reparse.
      if seen_count.zero?
        raise SyncGuardError, "upstream yielded zero packages — refusing to obsolete the whole repo (likely a mirror/publish failure)"
      end

      # A rpm/dnf bare-version → EVR reparse deliberately rewrites every row
      # under a new KEY, obsoleting all old-key rows as new-key rows replace
      # them — that mass obsoletion is expected, so skip the fraction check (the
      # empty-upstream check above still stands). Only kinds with a
      # PARSER_VERSIONS override reformat their key; apt reparses keep the same
      # key, so a genuine upstream shrink there must still be caught.
      return if parser_stale? && PARSER_VERSIONS.key?(@repository.kind.to_s)

      frac = obsolete_guard_fraction
      if active_count.positive? && obsolete_count > (active_count * frac)
        raise SyncGuardError,
              "would obsolete #{obsolete_count}/#{active_count} active packages (> #{(frac * 100).round}%) — " \
              "refusing as a likely partial upstream; re-run with force to override"
      end
    end

    def obsolete_guard_fraction
      raw = ::SiteSetting.get(OBSOLETE_GUARD_SETTING)
      f = raw.presence&.to_f
      f&.positive? ? f : DEFAULT_OBSOLETE_GUARD_FRACTION
    rescue StandardError
      DEFAULT_OBSOLETE_GUARD_FRACTION
    end

    def safe_fingerprint(adapter)
      adapter.fingerprint(repository: @repository)
    rescue StandardError => e
      Rails.logger.warn("[PackageRepositorySync] #{@repository.name}: fingerprint failed (#{e.class}: #{e.message}) — doing a full sync")
      nil
    end

    def parser_stale?
      @repository.parser_version.to_i < target_parser_version
    end

    # The parser version this repo's KIND should be synced with (rpm/dnf = 2 for
    # the EVR reformat, apt = the default 1).
    def target_parser_version
      PARSER_VERSIONS.fetch(@repository.kind.to_s, PARSER_VERSION)
    end

    def active_package_count
      ::System::Package.where(package_repository_id: @repository.id, obsoleted_at: nil).count
    end

    # Records a successful sync: repo status/last_synced_at/package_count, plus
    # the fingerprint (enables next run's fast-path) and the parser version we
    # synced with (clears parser_stale?). update_columns skips callbacks — the
    # counts are already consistent.
    def finalize_synced!(fingerprint, package_count)
      @repository.mark_synced!(package_count: package_count)
      cols = { parser_version: target_parser_version }
      cols[:sync_fingerprint] = fingerprint if fingerprint.present?
      @repository.update_columns(cols)
      # Package rows landed via raw upsert/update (no callbacks); refresh the
      # arch-level package_count counter so the catalog UI stays honest.
      ::System::NodeArchitecture.recompute_package_counts!
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

      # Deduplicate by the conflict key WITHIN this batch. An upstream index can
      # list the same (name, architecture, version) more than once (e.g. a
      # package present in multiple components), and Postgres' ON CONFLICT DO
      # UPDATE refuses to touch the same row twice in one statement
      # (PG::CardinalityViolation: "cannot affect row a second time"). Keep the
      # LAST occurrence — later entries win, matching normal upsert semantics.
      # (Cross-batch duplicates are harmless: they're separate statements.)
      rows = buffer
        .reverse
        .uniq { |r| [ r[:package_repository_id], r[:name], r[:architecture], r[:version] ] }
        .reverse

      # `updated_at` MUST be rewritten on every conflicting row — and
      # unconditionally. Rails' default `record_timestamps` does NOT do that:
      # it emits `updated_at = CASE WHEN <any update_only column differs>
      # THEN now ELSE updated_at END`, so re-upserting a row whose data is
      # UNCHANGED leaves its `updated_at` at the old value. `sync_full`'s
      # `soft_delete_unseen` treats "updated_at < sync_start" as "vanished
      # upstream" — so under the conditional bump, a full re-sync of an
      # unchanged upstream marks EVERY row unseen and the mass-obsoletion
      # guard fail-closes (the repo can never finalize, seen live 2026-07-14
      # on the parser-stale apt mirrors). Disable the conditional
      # auto-timestamp and list `updated_at` in `update_only` so it is set
      # unconditionally to the row's stamp (build_row sets it), making
      # "seen this run" reliable. created_at is explicit in every row too, so
      # inserts still get both timestamps despite record_timestamps: false.
      ::System::Package.upsert_all(
        rows,
        # Reference the conflict target by COLUMNS, not by index name: the
        # unique index on these four columns exists, but under Rails'
        # auto-generated name (idx_on_package_repository_id_name_architecture_vers_…),
        # never the `idx_pkg_repo_name_arch_ver` name this code originally
        # named — so `unique_by: :idx_pkg_repo_name_arch_ver` raised
        # "No unique index found" on EVERY sync. Columns resolve to whichever
        # unique index covers exactly them, independent of its name / any DB.
        unique_by: %i[package_repository_id name architecture version],
        record_timestamps: false,
        update_only: %i[
          release_version section_or_group description summary
          installed_size_bytes download_size_bytes
          depends pre_depends recommends suggests conflicts provides replaces breaks
          filename sha256 sha512 homepage license maintainer raw_metadata
          obsoleted_at updated_at
        ]
      )
    end

    # Loads every stored tuple for this repo as { "name\x1farch\x1fversion" =>
    # obsoleted? } in one pass. pluck (no AR objects) keeps ~N-row memory modest
    # (~4 small values/row). This is the one unavoidable full-repo read, but it
    # is a cheap index-covered SELECT vs. the mass rewrite it replaces.
    def load_existing_keys
      ::System::Package
        .where(package_repository_id: @repository.id)
        .pluck(:name, :architecture, :version, Arel.sql("obsoleted_at IS NOT NULL"))
        .each_with_object({}) { |(n, a, v, obs), h| h[row_key(n, a, v)] = obs }
    end

    def row_key(name, architecture, version)
      # \x1f (unit separator) can't appear in a package name/arch/version.
      "#{name}\x1f#{architecture}\x1f#{version}"
    end

    # Sets obsoleted_at (Time to obsolete, nil to reactivate) on a specific set
    # of tuple keys, chunked composite-key UPDATEs. Touches only the affected
    # rows (usually few — stable repos change little). Returns rows affected.
    def set_obsoleted(keys, value)
      return 0 if keys.blank?

      conn = ::System::Package.connection
      repo = conn.quote(@repository.id)
      val  = value.nil? ? "NULL" : conn.quote(value)
      keys.each_slice(1000).sum do |chunk|
        tuples = chunk.map do |k|
          n, a, v = k.split("\x1f", 3)
          "(#{conn.quote(n)},#{conn.quote(a)},#{conn.quote(v)})"
        end.join(",")
        conn.exec_update(
          "UPDATE system_packages SET obsoleted_at = #{val}, updated_at = now() " \
          "WHERE package_repository_id = #{repo} AND (name, architecture, version) IN (#{tuples})"
        )
      end
    end

    # Full-sync soft-delete: rows not touched by this run (updated_at < the
    # sync start) are missing from the latest upstream index → obsolete them.
    # Guarded like change-detection so a partial/empty upstream can't nuke the
    # catalog. Used only by sync_full (rpm/force).
    def soft_delete_unseen(since:, seen_count:)
      scope = ::System::Package
        .where(package_repository_id: @repository.id)
        .where(obsoleted_at: nil)
      active_count   = scope.count
      unseen         = scope.where("updated_at < ?", since)
      obsolete_count = unseen.count
      guard_obsoletion!(seen_count: seen_count, active_count: active_count, obsolete_count: obsolete_count)
      unseen.update_all(obsoleted_at: Time.current)
    end

    # Fallback when a repo has no architectures set — pick the kind's
    # default. apt's `amd64` and rpm's `x86_64` are the safest baseline
    # choices and match what the form would default to.
    def default_architecture_for(kind)
      kind.to_s == "apt" ? [ "amd64" ] : [ "x86_64" ]
    end
  end
end
