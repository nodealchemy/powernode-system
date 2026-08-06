# frozen_string_literal: true

require "spec_helper"
require "yaml"

# IMP-07e191785866 — the rspec matrix in ci.yaml named six directories
# (controllers, requests, services, models, lib, integration) while the spec
# root carried fourteen with specs in them, and the step's own comment claimed
# "total coverage stays at 100% across the matrix" — which is exactly what
# stopped the next reader checking. db, decorators, docs, schema, scripts,
# seeds, serializers and system were never run by any suite.
#
# The fix adds a `misc` sweep suite that runs every top-level spec directory
# NOT explicitly claimed by a named suite, so a future directory is covered by
# default. That leaves one machine-checkable invariant, pinned here: a
# directory may be excluded from the sweep ONLY if a named suite runs it
# explicitly (or it is a spec-less helper directory). If someone adds a new
# name to the sweep's exclusion list without adding it to a suite, this spec
# goes red — the silent-uncovered failure mode cannot come back unnoticed.
RSpec.describe "ci.yaml rspec matrix spec coverage" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:workflow_path)  { File.join(extension_root, ".gitea", "workflows", "ci.yaml") }
  let(:workflow_text)  { File.read(workflow_path) }
  let(:workflow_yaml)  { YAML.safe_load(workflow_text, aliases: true) }
  let(:spec_root)      { File.join(extension_root, "server", "spec") }

  # Directories rails_helper/spec_helper load as support code — they carry no
  # *_spec.rb of their own, so no suite needs to run them.
  HELPER_DIRS = %w[factories fixtures support].freeze

  def rspec_matrix_suites
    jobs = workflow_yaml.fetch("jobs")
    rspec_job = jobs.values.find { |j| j.to_s.include?("matrix") && j.to_s.include?("suite") }
    expect(rspec_job).not_to be_nil, "no matrix-suite job found in ci.yaml"
    rspec_job.dig("strategy", "matrix", "suite")
  end

  # Every server/spec/<dir> the case block names via an explicit
  # `.../server/spec/<dir>` path assignment.
  def explicitly_run_dirs
    workflow_text.scan(%r{extensions/system/server/spec/([a-z_]+)}).flatten.uniq.sort
  end

  # The sweep suite's exclusion list: claimed="controllers requests ..."
  def sweep_exclusions
    m = workflow_text.match(/claimed="([^"]+)"/)
    expect(m).not_to be_nil,
                     "ci.yaml has no `claimed=\"...\"` sweep exclusion list — the misc sweep suite is missing"
    m[1].split.uniq.sort
  end

  def spec_bearing_dirs
    Dir.children(spec_root).select do |name|
      path = File.join(spec_root, name)
      File.directory?(path) && !Dir.glob(File.join(path, "**", "*_spec.rb")).empty?
    end.sort
  end

  it "has a misc sweep suite in the matrix" do
    expect(rspec_matrix_suites).to include("misc"),
      "matrix suites #{rspec_matrix_suites.inspect} lack the `misc` sweep — " \
      "directories outside the named suites are never run"
  end

  it "excludes a directory from the sweep only when a named suite runs it explicitly" do
    unexplained = sweep_exclusions - explicitly_run_dirs - HELPER_DIRS
    expect(unexplained).to be_empty,
      "#{unexplained.inspect} are excluded from the misc sweep but no named suite " \
      "runs them — they are silently uncovered"
  end

  it "leaves no spec-bearing directory both unnamed and excluded from the sweep" do
    uncovered = spec_bearing_dirs.select do |dir|
      sweep_exclusions.include?(dir) && !explicitly_run_dirs.include?(dir)
    end
    expect(uncovered).to be_empty,
      "#{uncovered.inspect} contain specs but are neither explicitly run nor swept by misc"
  end
end
