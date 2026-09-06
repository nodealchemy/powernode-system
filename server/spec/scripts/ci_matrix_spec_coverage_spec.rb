# frozen_string_literal: true

require "spec_helper"
require "yaml"

# THE INVARIANT THIS FILE HAS ALWAYS PROTECTED, through three different
# mechanisms: every spec-bearing directory is actually run by CI.
#
# History, because the shape keeps changing and the reason must not be lost.
# IMP-07e191785866: the rspec matrix named six directories while the spec root
# had fourteen with specs in them, and the step's own comment claimed "total
# coverage stays at 100% across the matrix" — which is precisely what stopped
# the next reader checking. Eight directories were never run by any suite.
# IMP-31a5ea65480d: the four matrix entries were collapsed into one job with a
# `for suite in ...` shell loop, deleting the `strategy:` key this spec read.
#
# Design step 3 changed the mechanism again, and this time it removes the class
# of bug rather than re-checking a list: shards are computed FROM THE FILE TREE
# by scripts/ci-spec-shard.rb, so there is no directory list to drift. What is
# left to pin is that the derivation cannot quietly narrow — the glob excludes
# exactly the helper dirs, the matrix length matches what the shard script is
# told, and the union gate exists.
RSpec.describe "ci.yaml spec shard coverage" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:workflow_path)  { File.join(extension_root, ".gitea", "workflows", "ci.yaml") }
  let(:workflow_text)  { File.read(workflow_path) }
  let(:workflow_yaml)  { YAML.safe_load(workflow_text, aliases: true) }
  let(:spec_root)      { File.join(extension_root, "server", "spec") }
  let(:rspec_job)      { workflow_yaml.fetch("jobs").fetch("rspec") }

  # Loaded by rails_helper as support code; they carry no *_spec.rb, so no
  # shard needs to run them. This is the ONE list, and the workflow's glob is
  # asserted against it below.
  HELPER_DIRS = %w[factories fixtures support].freeze

  def spec_bearing_dirs
    Dir.glob(File.join(spec_root, "*")).select { |p| File.directory?(p) }
       .reject { |p| HELPER_DIRS.include?(File.basename(p)) }
       .select { |p| Dir.glob(File.join(p, "**", "*_spec.rb")).any? }
       .map { |p| File.basename(p) }
  end

  it "shards the rspec job rather than running the suite in one container" do
    shards = rspec_job.dig("strategy", "matrix", "shard")

    expect(shards).to be_an(Array),
      "the rspec job must be a shard matrix — one job cannot finish the suite: " \
      "~217 minutes of work against a container ceiling of /bin/sleep 10800 = 180"
    expect(shards.length).to be >= 2
    expect(shards).to eq((0...shards.length).to_a),
      "shard indices must be a dense 0..N-1 range; ci-spec-shard.rb refuses anything else"
  end

  it "tells the shard script the same N as the matrix length" do
    declared = workflow_text.scan(/CI_RSPEC_SHARDS:\s*"(\d+)"/).flatten.map(&:to_i).uniq
    matrix_n = rspec_job.dig("strategy", "matrix", "shard").length

    expect(declared).not_to be_empty, "no CI_RSPEC_SHARDS declared in ci.yaml"
    expect(declared).to all(eq(matrix_n)),
      "CI_RSPEC_SHARDS #{declared.inspect} disagrees with the #{matrix_n}-entry matrix. " \
      "A stale N silently drops whole shards' worth of files."
  end

  # The replacement for the old "claimed=" audit. A directory list cannot drift
  # if there is no directory list — but the GLOB can, so pin its exclusions.
  it "excludes exactly the helper dirs from the shard glob, and nothing else" do
    excluded = workflow_text.scan(/^\s*(factories\|fixtures\|support)\)\s*;;\s*$/).flatten

    expect(excluded).not_to be_empty,
      "the shard step's directory glob no longer excludes helper dirs by the " \
      "expected shape — re-read it and update this guard deliberately"
    expect(excluded.first.split("|").sort).to eq(HELPER_DIRS.sort),
      "the workflow excludes #{excluded.first} but this guard knows #{HELPER_DIRS.join('|')}. " \
      "Excluding a real directory here is how eight of them went unrun in 2026-08."
  end

  it "finds spec-bearing directories, so this guard cannot pass vacuously" do
    expect(spec_bearing_dirs.length).to be >= 8
    expect(spec_bearing_dirs).to include("services", "models", "requests")
  end

  # Per-shard "ran == planned" catches a dropped file inside one shard; only a
  # union check catches a file no shard claimed at all.
  it "gates the union of the shards against the dry-run total" do
    gate = workflow_yaml.fetch("jobs")["rspec-gate"]

    expect(gate).not_to be_nil, "no rspec-gate job — nothing verifies the shards covered the suite"
    expect(gate["needs"]).to eq("rspec").or(include("rspec"))

    body = gate.fetch("steps").map { |s| s["run"].to_s }.join("\n")
    expect(body).to include("ci-spec-shard.rb"),
      "the gate must recompute the partition, not trust the shards' own word for it"
    expect(body).to match(/DO NOT COVER|missing/i)
    expect(body).to match(/OVERLAP|dupes/i)
  end

  it "keeps the gate mandatory — a skipped shard must not leave it green" do
    gate = workflow_yaml.fetch("jobs").fetch("rspec-gate")

    expect(gate["if"]).to be_nil,
      "`if: always()` on the gate would let it pass while a shard failed or was " \
      "cancelled; plain `needs:` makes a broken shard skip the gate and redden the run"
  end

  it "runs no spec job with continue-on-error" do
    offenders = workflow_yaml.fetch("jobs").select do |name, job|
      next false unless name.match?(/rspec|specs/)

      job["continue-on-error"] ||
        Array(job["steps"]).any? { |s| s["continue-on-error"] }
    end

    expect(offenders.keys).to be_empty,
      "a spec job that cannot fail the run is not a gate: #{offenders.keys.join(', ')}"
  end
end
