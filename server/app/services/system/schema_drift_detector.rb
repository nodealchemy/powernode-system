# frozen_string_literal: true

module System
  # Boot-time backstop for the "stamped-without-DDL" schema drift that bit
  # ops-hub (imp 019f77c5): a migration recorded in schema_migrations whose DDL
  # never ran, because a historical `db:schema:load` / `db:setup` stamped it via
  # `assume_migrated_upto_version` against a core-only schema.rb that lagged the
  # extension column. The live plane runs `db:migrate` now (which can't heal an
  # already-stamped version), so this detector exists to CATCH such a drift and
  # shout about it — never to fix or block.
  #
  # Approach: LIVE-vs-LOADED-MIGRATIONS (no build-time schema baking).
  #   For every migration FILE present in THIS node's loaded migration paths
  #   whose version is stamped applied in schema_migrations, statically scan the
  #   file for the objects it declares (add_column / add_index name:), net of the
  #   objects a later applied migration removes or renames (remove_column /
  #   remove_index / rename_column / rename_index), and verify each surviving
  #   object EXISTS in the live DB. A stamped migration whose declared
  #   column/index is absent is exactly the drift signature.
  #
  # Why loaded-migrations (not schema.rb): the committed core schema.rb records
  # only what was installed on the machine that dumped it. It is dumped in core
  # mode, so it carries no object belonging to a non-public extension at all —
  # that lag is what caused the drift, and it is why schema.rb cannot be the
  # oracle for any table this node holds beyond the public set. (It DOES carry
  # every system_* column, this file's own subject included, so do not read the
  # lag as "schema.rb is always behind"; it is behind exactly on what was not
  # installed at dump time.) The node's loaded migration paths, by contrast,
  # include every extension actually installed here — and NONE that isn't. So an
  # uninstalled extension's tables are never even scanned: no false positives.
  #
  # Design constraints (deliberate):
  #   * NEVER raises / never fails boot. A false positive that bricks a sole
  #     control plane's boot is worse than the drift it would report. All work is
  #     wrapped; any internal error yields an empty (no-drift) report.
  #   * Only STAMPED (applied) migrations are checked. A file present but not yet
  #     in schema_migrations is a pending migration, not drift — skipped.
  #   * Only objects on a table that EXISTS live are flagged. If the whole table
  #     is absent it's an uninstalled/legit-absent extension (create_table that
  #     legitimately didn't run here), never reported.
  #   * Deliberate under-catch (never a false positive): only top-level
  #     add_column / add_index name: are parsed. Columns declared inside
  #     create_table / change_table blocks, and unnamed indexes, are not tracked
  #     — a whole-table create_table that didn't run surfaces as an absent table
  #     (skipped), and the #41 class (add_column on an existing table) is the
  #     signature we must and do catch.
  #
  # The report is advisory. Callers (rails-start's post-migrate hook) log it
  # loudly and emit a System::FleetEvent so it's visible in fleet views/alerts.
  class SchemaDriftDetector
    Result = Struct.new(:drifted?, :missing, :migrations_scanned,
                        :versions_pending_skipped, :tables_absent_skipped, :error,
                        keyword_init: true) do
      def summary
        return "detector error: #{error}" if error
        unless drifted?
          return "no drift (#{migrations_scanned} applied migration file(s) scanned, " \
                 "#{tables_absent_skipped} absent-table object(s) skipped)"
        end

        "DRIFT: #{missing.size} stamped-but-absent object(s) across " \
          "#{migrations_scanned} scanned migration file(s)"
      end
    end

    def self.run(migration_paths: nil, connection: nil)
      new(migration_paths: migration_paths, connection: connection).run
    end

    def initialize(migration_paths: nil, connection: nil)
      @migration_paths = Array(migration_paths).reject(&:blank?)
      @migration_paths = default_migration_paths if @migration_paths.empty?
      @connection = connection
    end

    def run
      conn = @connection || ActiveRecord::Base.connection
      applied = applied_versions(conn)

      # {"table" => {columns: Set, indexes: Set}} of objects declared by applied
      # migration files, net of objects a later applied migration removes.
      expected, scanned, pending = expected_objects(applied)

      missing = []
      tables_absent = 0

      expected.each do |table, spec|
        unless conn.data_source_exists?(table)
          tables_absent += spec[:columns].size + spec[:indexes].size
          next
        end

        live_cols = conn.columns(table).map(&:name).to_set
        spec[:columns].each do |col, version|
          missing << { table: table, kind: "column", name: col, version: version } unless live_cols.include?(col)
        end

        next if spec[:indexes].empty?

        live_idx = conn.indexes(table).map(&:name).to_set
        spec[:indexes].each do |idx, version|
          missing << { table: table, kind: "index", name: idx, version: version } unless live_idx.include?(idx)
        end
      end

      Result.new(
        drifted?: missing.any?,
        missing: missing,
        migrations_scanned: scanned,
        versions_pending_skipped: pending,
        tables_absent_skipped: tables_absent,
        error: nil
      )
    rescue StandardError => e
      # Fail SAFE: never let the detector itself break the boot it guards.
      Result.new(drifted?: false, missing: [], migrations_scanned: 0,
                 versions_pending_skipped: 0, tables_absent_skipped: 0,
                 error: "#{e.class}: #{e.message}")
    end

    private

    def default_migration_paths
      # This node's loaded migration paths — core + every INSTALLED extension
      # engine (each engine appends its own db/migrate to this config path, see
      # PowernodeSystem::Engine), and nothing that isn't installed here. This is
      # the same source `rake db:migrate` uses, so it stays in lock-step with
      # what actually gets stamped. NOTE: ActiveRecord::Migrator.migrations_paths
      # is NOT equivalent — at runtime it stays core-only (["db/migrate"]) and
      # would miss every extension migration (the exact #41 class).
      cfg = Rails.application.config.paths["db/migrate"]
      paths = cfg.respond_to?(:expanded) ? cfg.expanded : Array(cfg.to_a)
      paths = Array(paths).reject(&:blank?)
      paths.presence || Array(ActiveRecord::Migrator.migrations_paths)
    rescue StandardError
      base = begin
        Array(ActiveRecord::Migrator.migrations_paths)
      rescue StandardError
        []
      end
      base.presence || [ Rails.root.join("db", "migrate").to_s ]
    end

    def applied_versions(conn)
      conn.select_values("SELECT version FROM schema_migrations").map(&:to_s).to_set
    rescue StandardError
      Set.new
    end

    # Walk applied migration files; accumulate declared add_column/add_index
    # objects and subtract later remove_column/remove_index. Returns
    # [expected_hash, scanned_count, pending_skipped_count].
    def expected_objects(applied)
      added   = Hash.new { |h, k| h[k] = { columns: {}, indexes: {} } }
      removed = { columns: Set.new, indexes: Set.new }
      scanned = 0
      pending = 0

      migration_files.sort_by { |f| migration_version(f).to_s }.each do |file|
        version = migration_version(file)
        next unless version

        unless applied.include?(version)
          pending += 1
          next
        end
        scanned += 1

        src = File.read(file)
        scan_source(src, version, added, removed)
      end

      # Net: drop any object a later applied migration removed.
      added.each do |table, spec|
        spec[:columns].reject! { |col, _v| removed[:columns].include?([ table, col ]) }
        spec[:indexes].reject! { |idx, _v| removed[:indexes].include?([ table, idx ]) }
      end
      added.reject! { |_t, spec| spec[:columns].empty? && spec[:indexes].empty? }

      [ added, scanned, pending ]
    end

    def scan_source(src, version, added, removed)
      src.each_line do |line|
        next if line =~ /\A\s*#/ # skip comment lines

        # rename_* first: a rename both removes the old object and adds the new
        # (so an early-added, later-renamed column isn't flagged as absent).
        if (m = line.match(/\brename_column\s+:?["']?(\w+)["']?\s*,\s*:?["']?(\w+)["']?\s*,\s*:?["']?(\w+)["']?/))
          removed[:columns] << [ m[1], m[2] ]
          added[m[1]][:columns][m[3]] ||= version
        elsif (m = line.match(/\brename_index\s+:?["']?(\w+)["']?\s*,\s*["':]?(\w+)["']?\s*,\s*["':]?(\w+)["']?/))
          removed[:indexes] << [ m[1], m[2] ]
          added[m[1]][:indexes][m[3]] ||= version
        elsif (m = line.match(/\badd_column\s+:?["']?(\w+)["']?\s*,\s*:?["']?(\w+)["']?/))
          added[m[1]][:columns][m[2]] ||= version
        elsif (m = line.match(/\bremove_column\s+:?["']?(\w+)["']?\s*,\s*:?["']?(\w+)["']?/))
          removed[:columns] << [ m[1], m[2] ]
        elsif (m = line.match(/\badd_index\s+:?["']?(\w+)["']?.*?name:\s*["']([^"']+)["']/))
          added[m[1]][:indexes][m[2]] ||= version
        elsif (m = line.match(/\bremove_index\s+:?["']?(\w+)["']?.*?name:\s*["']([^"']+)["']/))
          removed[:indexes] << [ m[1], m[2] ]
        end
      end
    end

    def migration_files
      @migration_paths.flat_map { |p| Dir[File.join(p, "*.rb")] }.uniq
    end

    def migration_version(file)
      m = File.basename(file).match(/\A(\d+)_/)
      m && m[1]
    end
  end
end
