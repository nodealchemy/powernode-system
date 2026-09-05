# frozen_string_literal: true

require "spec_helper"

# Drift guard for the smoke-seed count restated in three separate documents.
# All three said "28" while db/seeds/smoke_test_*.rb actually has 34 files —
# six real smoke tests (smoke_test_ci_runner.rb, smoke_test_edge_exposure.rb,
# smoke_test_expose_service.rb, smoke_test_instance_replace.rb,
# smoke_test_pivot_root.rb, smoke_test_storage_migration_revert_cleanup.rb)
# existed on disk but were never counted. Restating "34" by hand would leave
# this exact drift free to recur the next time a smoke seed is added, so this
# derives the figure from the glob every time instead.
#
# Follows readme_counts_spec.rb's pattern (same directory): derive the real
# count from disk, parse the number each doc states in prose via a regex that
# raises if the wording has changed (never a silent 0 == 0), and assert
# equality against the derived figure — never hardcoding 34 on both sides.
#
# What it does NOT catch: SMOKE_TEST.md's catalog TABLE itself still lists
# only 28 of the 34 files by name (a roster gap, not a count) — fixing that
# requires authoring pass/phase/description content for the six missing
# rows, which is out of scope for a count guard and is tracked separately.
RSpec.describe "smoke-test seed count vs. reality" do
  ext_root           = File.expand_path("../../..", __dir__)
  seeds_dir          = File.join(ext_root, "server/db/seeds")
  smoke_test_path    = File.join(ext_root, "docs/SMOKE_TEST.md")
  k3s_lifecycle_path = File.join(ext_root, "docs/runbooks/k3s-smoke-full-lifecycle.md")
  architecture_path  = File.join(ext_root, "docs/ARCHITECTURE.md")

  let(:actual_smoke_seed_count) do
    Dir.glob(File.join(seeds_dir, "smoke_test_*.rb")).size
  end

  def doc_number(text, pattern, label, path)
    match = text.match(pattern)
    unless match
      raise "#{path}: could not find the \"#{label}\" figure (pattern #{pattern.inspect}) — " \
            "the doc's phrasing around this number likely changed; update this spec's regex " \
            "to match the new wording rather than treating this as a passing/failing count."
    end
    match[1].to_i
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
    stated = doc_number(text, /All (\d+) smoke seeds, grouped by pass/, "catalog heading count", smoke_test_path)
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
end
