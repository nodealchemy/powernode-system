# frozen_string_literal: true

require "spec_helper"

# Drift guard for the smoke-seed count restated in three separate documents,
# AND for SMOKE_TEST.md's catalog table naming every seed it counts.
#
# All three docs said "28" while db/seeds/smoke_test_*.rb actually has 34
# files — six real smoke tests (smoke_test_ci_runner.rb,
# smoke_test_edge_exposure.rb, smoke_test_expose_service.rb,
# smoke_test_instance_replace.rb, smoke_test_pivot_root.rb,
# smoke_test_storage_migration_revert_cleanup.rb) existed on disk but were
# never counted OR listed. Fixing only the digit would have left a table that
# claims 34 while naming 28 by name — arguably worse than a doc that was
# wrong on both axes consistently, per the guard's own history: see
# stale_systemd_unit_names_spec.rb's roster-not-just-count precedent. So this
# spec asserts BOTH: the stated count matches the glob, AND the catalog
# table's row count matches the glob AND names every file that exists.
#
# Follows readme_counts_spec.rb's pattern (same directory): derive the real
# count from disk, parse what each doc states via a regex that raises if the
# wording has changed (never a silent 0 == 0), and assert equality/set
# membership against the derived figures — never hardcoding 34 or the file
# list on both sides.
#
# What it does NOT catch: whether a table row's Pass/Phase/Validates content
# is itself accurate — six rows intentionally carry "—" for Pass/Phase
# because their own file headers don't state one (see the note above the
# table in SMOKE_TEST.md); asserting THAT content would require re-deriving
# prose from each file's header, which this spec does not attempt.
RSpec.describe "smoke-test seed count and catalog roster vs. reality" do
  ext_root           = File.expand_path("../../..", __dir__)
  seeds_dir          = File.join(ext_root, "server/db/seeds")
  smoke_test_path    = File.join(ext_root, "docs/SMOKE_TEST.md")
  k3s_lifecycle_path = File.join(ext_root, "docs/runbooks/k3s-smoke-full-lifecycle.md")
  architecture_path  = File.join(ext_root, "docs/ARCHITECTURE.md")

  let(:actual_smoke_seed_files) do
    Dir.glob(File.join(seeds_dir, "smoke_test_*.rb")).map { |path| File.basename(path) }.sort
  end

  let(:actual_smoke_seed_count) { actual_smoke_seed_files.size }

  def doc_number(text, pattern, label, path)
    match = text.match(pattern)
    unless match
      raise "#{path}: could not find the \"#{label}\" figure (pattern #{pattern.inspect}) — " \
            "the doc's phrasing around this number likely changed; update this spec's regex " \
            "to match the new wording rather than treating this as a passing/failing count."
    end
    match[1].to_i
  end

  # Isolates SMOKE_TEST.md's ONE master catalog table (the "Seed | Pass |
  # Phase | Validates | Spawns VM?" table right under the "## Smoke test
  # catalog" heading) from the per-pass mini-tables further down the doc that
  # restate a subset of the same seeds in a different (2-column) shape — a
  # bare `grep '`smoke_test_'` across the whole file would double-count those
  # and give a false roster.
  def catalog_table_rows(text)
    header = /^\| Seed \| Pass \| Phase \| Validates \| Spawns VM\? \|\n\|[-\s|]+\|\n/
    match = text.match(header)
    unless match
      raise "#{smoke_test_path}: could not locate the master catalog table's header row " \
            "(\"Seed | Pass | Phase | Validates | Spawns VM?\") — has the table been reshaped? " \
            "update this spec's pattern rather than skipping the check."
    end
    body_start = match.end(0)
    rest = text[body_start..]
    body = rest[/\A(?:\|.*\n)+/]
    unless body
      raise "#{smoke_test_path}: the master catalog table header was found but no data rows " \
            "follow it — update this spec's pattern."
    end
    body.each_line.map(&:strip).reject(&:empty?)
  end

  def seed_name_from_row(row)
    match = row.match(/^\|\s*`(smoke_test_[a-zA-Z0-9_]+\.rb)`\s*\|/)
    unless match
      raise "#{smoke_test_path}: a master catalog table row does not start with a " \
            "`smoke_test_*.rb` seed name in backticks as its first cell: #{row.inspect} — " \
            "has the table's column order changed? update this spec's pattern."
    end
    match[1]
  end

  it "has at least one smoke seed on disk (sanity check on the glob itself)" do
    expect(actual_smoke_seed_count).to be > 0
  end

  it "states the correct count in SMOKE_TEST.md's intro prose" do
    text = File.read(smoke_test_path)
    stated = doc_number(text, /exercised through (\d+) seeded smoke scripts/, "intro smoke-script count", smoke_test_path)
    expect(stated).to eq(actual_smoke_seed_count),
      "SMOKE_TEST.md's intro claims #{stated} seeded smoke scripts; #{seeds_dir} actually has " \
      "#{actual_smoke_seed_count} smoke_test_*.rb files"
  end

  it "states the correct count in SMOKE_TEST.md's catalog heading" do
    text = File.read(smoke_test_path)
    stated = doc_number(text, /All (\d+) smoke seeds\./, "catalog heading count", smoke_test_path)
    expect(stated).to eq(actual_smoke_seed_count),
      "SMOKE_TEST.md's catalog heading claims #{stated} smoke seeds; #{seeds_dir} actually has " \
      "#{actual_smoke_seed_count} smoke_test_*.rb files"
  end

  it "states the correct count in k3s-smoke-full-lifecycle.md's cross-reference" do
    text = File.read(k3s_lifecycle_path)
    stated = doc_number(text, /catalog of all (\d+) smoke seeds/, "cross-reference smoke-seed count", k3s_lifecycle_path)
    expect(stated).to eq(actual_smoke_seed_count),
      "k3s-smoke-full-lifecycle.md's cross-reference claims #{stated} smoke seeds; #{seeds_dir} " \
      "actually has #{actual_smoke_seed_count} smoke_test_*.rb files"
  end

  it "states the correct count in ARCHITECTURE.md's 'Where to read more' pointer" do
    text = File.read(architecture_path)
    stated = doc_number(text, /platform-level smoke catalog \((\d+) seeds, \d+ passes\)/, "smoke catalog pointer count", architecture_path)
    expect(stated).to eq(actual_smoke_seed_count),
      "ARCHITECTURE.md's smoke catalog pointer claims #{stated} seeds; #{seeds_dir} actually has " \
      "#{actual_smoke_seed_count} smoke_test_*.rb files"
  end

  it "has exactly as many rows in the master catalog table as there are seed files" do
    text = File.read(smoke_test_path)
    rows = catalog_table_rows(text)
    expect(rows.size).to eq(actual_smoke_seed_count),
      "SMOKE_TEST.md's master catalog table has #{rows.size} rows; #{seeds_dir} actually has " \
      "#{actual_smoke_seed_count} smoke_test_*.rb files — a matching COUNT with a short ROSTER " \
      "(or vice versa) is exactly the defect this spec exists to catch"
  end

  it "names every smoke_test_*.rb file by name in the master catalog table, and no others" do
    text = File.read(smoke_test_path)
    rows = catalog_table_rows(text)
    listed = rows.map { |row| seed_name_from_row(row) }

    missing = actual_smoke_seed_files - listed
    extra   = listed - actual_smoke_seed_files
    expect(missing).to be_empty,
      "SMOKE_TEST.md's master catalog table omits these real seed files: #{missing.join(', ')}"
    expect(extra).to be_empty,
      "SMOKE_TEST.md's master catalog table names seed files that do not exist on disk: #{extra.join(', ')}"

    # EQUALITY, not just inclusion — catches a duplicated row hiding a missing one
    # behind a count that still happens to match.
    expect(listed.sort).to eq(actual_smoke_seed_files),
      "SMOKE_TEST.md's master catalog table's roster does not exactly match the seeds on disk " \
      "once duplicates are accounted for (listed: #{listed.size}, unique files: #{actual_smoke_seed_files.size})"
  end
end
