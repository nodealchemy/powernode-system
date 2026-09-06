# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "tmpdir"
require "open3"

# 2026-09-06 (IMP-3cdd6859a249): on run 1773 the rspec, provider-specs and
# worker-specs jobs each reported conclusion `failure` after 13-23 seconds with
# every step `cancelled` and not one line of rspec output. None executed a
# single example — the postgres sidecar could not bind the fixed host port. The
# workflow surface for that outcome is byte-identical to a genuine spec
# failure, so "3 jobs failed" is information-free: a reviewer cannot tell a
# broken build from a build that was never tested, and a real regression
# landing in that window is invisible behind it.
#
# The port collision is fixed separately (the isolation design, step 2). This
# guard is about the REPORTING, which stays wrong after collisions stop:
# any future infrastructure fault that kills a job before the suite lands in
# the same indistinguishable bucket. Every spec-running job must therefore
# assert it actually executed examples, and say so in those words when it did
# not.
RSpec.describe "CI zero-example gate" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:ci)      { YAML.safe_load(File.read(File.join(extension_root, ".gitea/workflows/ci.yaml")), aliases: true) }
  let(:wrapper) { File.join(extension_root, "scripts/ci-rspec.sh") }
  let(:asserter) { File.join(extension_root, "scripts/ci-assert-examples-ran.sh") }

  # A job runs specs if any step EXECUTES examples. A `--dry-run` invocation is
  # deliberately not one: it enumerates the suite and runs nothing, which is
  # the whole point of the shard planner and the coverage gate. Counting those
  # as spec jobs would demand a zero-example assertion on a job designed to
  # execute zero examples, and fail every run.
  #
  # The shard job itself does BOTH — it plans with --dry-run and then runs for
  # real — so the test is per-INVOCATION, not per-job.
  def executing_rspec_runs(job)
    Array(job["steps"]).flat_map { |s| s["run"].to_s.lines }
                       .select { |line| line.match?(/rspec|test-provider-gems\.sh/) }
                       .reject { |line| line.include?("--dry-run") }
  end

  def spec_jobs
    ci.fetch("jobs").select { |_name, job| executing_rspec_runs(job).any? }
  end

  it "finds the spec-running jobs" do
    expect(spec_jobs.keys).to include("rspec", "provider-specs", "worker-specs"),
      "the derivation of spec-running jobs has drifted; this guard would otherwise " \
      "pass vacuously by matching nothing"
  end

  it "routes every rspec invocation through the counting wrapper" do
    bare = spec_jobs.filter_map do |name, job|
      name if executing_rspec_runs(job).any? { |line| line.match?(/bundle exec rspec/) }
    end
    expect(bare).to be_empty,
      "these jobs call `bundle exec rspec` directly, so their example count is " \
      "never recorded and a zero-example run stays indistinguishable from a " \
      "test failure: #{bare.join(', ')}. Call scripts/ci-rspec.sh instead."
  end

  it "exempts a dry-run-only job, and ONLY because it executes nothing" do
    gate = ci.fetch("jobs")["rspec-gate"]
    skip "no rspec-gate job in this workflow" if gate.nil?

    expect(spec_jobs.keys).not_to include("rspec-gate")
    expect(gate.fetch("steps").map { |s| s["run"].to_s }.join).to include("--dry-run"),
      "rspec-gate is exempt from the zero-example assertion purely because its " \
      "rspec invocation is a dry run; if it ever executes examples the exemption " \
      "must go with it"
  end

  it "asserts examples ran, unconditionally, in every spec-running job" do
    missing = spec_jobs.reject do |_name, job|
      Array(job["steps"]).any? do |s|
        s["run"].to_s.include?("ci-assert-examples-ran.sh") && s["if"].to_s.include?("always")
      end
    end
    expect(missing.keys).to be_empty,
      "these jobs have no `if: always()` step running ci-assert-examples-ran.sh, " \
      "so a job killed before its suite still reports a bare `failure`: " \
      "#{missing.keys.join(', ')}"
  end

  it "routes the provider-gem harness through the wrapper too" do
    harness = File.read(File.join(extension_root, "scripts/test-provider-gems.sh"))
    expect(harness).not_to match(/^\s*bundle exec rspec/),
      "test-provider-gems.sh runs rspec directly, so provider-specs records no " \
      "example count"
  end

  # Behavioural, not textual: the scripts are the thing that has to work.
  describe "ci-assert-examples-ran.sh" do
    it "fails, naming 'never ran', when no examples were recorded" do
      Dir.mktmpdir do |dir|
        totals = File.join(dir, "totals")
        out, status = Open3.capture2e(
          { "CI_EXAMPLES_TOTALS_FILE" => totals }, "bash", asserter, "rspec"
        )
        expect(status).not_to be_success, "a zero-example job must fail the build"
        expect(out).to match(/NO EXAMPLES RAN/i)
        expect(out).to match(/never/i),
          "the message must distinguish 'never ran' from an ordinary failure"
      end
    end

    it "passes when examples were recorded" do
      Dir.mktmpdir do |dir|
        totals = File.join(dir, "totals")
        File.write(totals, "0\n2153\n")
        out, status = Open3.capture2e(
          { "CI_EXAMPLES_TOTALS_FILE" => totals }, "bash", asserter, "rspec"
        )
        expect(status).to be_success, out
        expect(out).to include("2153")
      end
    end
  end

  it "derives the totals file identically in both scripts" do
    line = ->(path) { File.read(path).lines.find { |l| l.start_with?("TOTALS=") }&.strip }
    expect(line.call(wrapper)).to eq(line.call(asserter)),
      "the wrapper writes counts to one path and the asserter reads another, so " \
      "the gate would read an empty file and fail every job"
    expect(line.call(wrapper)).to include("GITHUB_JOB"),
      "the totals file must be job-scoped, or two jobs sharing a runner sum into " \
      "one file and a job that ran nothing inherits its neighbour's count"
  end

  describe "ci-rspec.sh" do
    it "records the example count and preserves rspec's own exit status" do
      Dir.mktmpdir do |dir|
        totals = File.join(dir, "totals")
        fake   = File.join(dir, "bin")
        FileUtils.mkdir_p(fake)
        # Stand in for `bundle`, so the wrapper is tested without a real suite.
        File.write(File.join(fake, "bundle"), <<~SH)
          #!/usr/bin/env bash
          echo "7 examples, 1 failure"
          exit 3
        SH
        FileUtils.chmod(0o755, File.join(fake, "bundle"))

        _out, status = Open3.capture2e(
          { "CI_EXAMPLES_TOTALS_FILE" => totals, "PATH" => "#{fake}:#{ENV['PATH']}" },
          "bash", wrapper, "spec/whatever_spec.rb"
        )
        expect(status.exitstatus).to eq(3),
          "the wrapper must exit with rspec's status, not a pipeline stage's"
        expect(File.read(totals).split.map(&:to_i).sum).to eq(7)
      end
    end
  end
end
