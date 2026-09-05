# frozen_string_literal: true

require "rails_helper"

# CENSUS GUARD: no spec `load`s an abortable seed except through
# AbortableSeedHelpers#load_abortable_seed!.
#
# A seed that ends an assertion in Kernel#abort raises SystemExit, which
# rspec-support deliberately does not rescue (AVOID_RESCUING). An example that
# lets it escape does not fail — it ends the process, and the reporter prints
# a clean summary of what had finished. That is how the misc lane reported
# "89 examples, 1 failure" over a suite that collects 2172, for every CI run
# in which smoke_test_instance_replace's seed was regressed (2026-09-05).
# Guarding the one call whose assertion is about the exit is not enough: the
# same spec loaded the seed unguarded at two other sites, and the next seed
# spec had four. So the shape is asserted, and both halves are DISCOVERED:
#
#   * an abortable seed is any db/seeds file that calls abort / exit /
#     fail_with (the smoke seeds' own assertion vocabulary), and
#   * an offending site is a bare `load` in a spec file that names one of
#     those seeds anywhere in its source.
#
# WHAT THIS DOES NOT CATCH: a seed loaded through a path built at runtime
# that never spells the filename, or a `load` of a seed that reaches abort
# only through a helper this scan does not recognise. It is a ratchet against
# the shape being re-introduced by hand in the forms it actually took.
RSpec.describe "abortable seeds are only loaded through load_abortable_seed!", type: :lint do
  ASL_SERVER_ROOT = File.expand_path("../..", __dir__)
  ASL_SEEDS_ROOT = File.join(ASL_SERVER_ROOT, "db", "seeds")
  ASL_ABORT_VOCABULARY = /(?<![\w.])(?:abort|exit|exit!|fail_with)\b/
  # A bare `load`: not `.load` (a receiver's method), not `load_…` (another
  # identifier), not `Rails.application.load_tasks`, not `eager_load!`.
  ASL_BARE_LOAD = /(?<![\w.:!])load(?![\w!?])\s*[(\s]/

  def self.abortable_seeds
    Dir.glob(File.join(ASL_SEEDS_ROOT, "**", "*.rb")).sort.select do |path|
      File.readlines(path).any? { |l| !l.strip.start_with?("#") && l.match?(ASL_ABORT_VOCABULARY) }
    end.map { |p| File.basename(p) }
  end

  def self.spec_sources
    Dir.glob(File.join(ASL_SERVER_ROOT, "spec", "**", "*.rb")).sort.reject { |p| p == __FILE__ }
  end

  it "discovers the seeds that abort (the discovery itself is alive)" do
    seeds = self.class.abortable_seeds
    expect(seeds.size).to be >= 30, "found #{seeds.size} abortable seeds under db/seeds — the scan is wrong"
    expect(seeds).to include("smoke_test_instance_replace.rb", "smoke_test_k3s_federation.rb")
  end

  it "finds the specs that load them (the scan is scoped to something)" do
    seeds = self.class.abortable_seeds
    in_scope = self.class.spec_sources.select { |p| src = File.read(p); seeds.any? { |s| src.include?(s) } }
    expect(in_scope.size).to be >= 2, "no spec names an abortable seed — the scope is wrong"
  end

  it "never loads an abortable seed with a bare `load`" do
    seeds = self.class.abortable_seeds

    offences = self.class.spec_sources.flat_map do |path|
      src = File.read(path)
      next [] unless seeds.any? { |s| src.include?(s) }

      src.lines.each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#")
        next unless line.match?(ASL_BARE_LOAD)

        "#{path.delete_prefix("#{ASL_SERVER_ROOT}/")}:#{i + 1}: #{line.strip}"
      end
    end

    expect(offences).to be_empty, <<~MSG
      A seed that aborts raises SystemExit, which RSpec does not rescue: an
      unguarded `load` of it ends the whole rspec process on the first failed
      seed assertion and hides every example after it, while the summary
      reads clean. Load it with `load_abortable_seed!(path)` (spec/support/
      abortable_seed_helpers.rb), which turns the abort into an ordinary
      failure of the example that loaded it.

      #{offences.join("\n")}
    MSG
  end
end
