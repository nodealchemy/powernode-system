# frozen_string_literal: true

require "spec_helper"
require "yaml"

# 2026-09-05: every rspec and provider-specs run on develop aborted at load
# with "Migrations are pending" before a single example executed. Cause: the
# inline schema_migrations backfill in ci.yaml globbed
# ../extensions/*/server/db/migrate/*.rb ONLY, while db:schema:load stamps just
# what schema.rb's version covers. A core DATA-only migration
# (20260905050000_scrub_historical_audit_log_secrets.rb) changes no schema, so
# schema.rb stayed at 20260904150000 and that version was stamped by neither
# mechanism.
#
# It survived because the backfill was DUPLICATED verbatim across two jobs, so
# the gap was in both, and because every earlier core migration was DDL and
# bumped schema.rb — the extension-only glob had never been the binding
# constraint. These invariants pin the shared script and its coverage of BOTH
# trees.
RSpec.describe "CI test-database migration stamping" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script_path)    { File.join(extension_root, "scripts/ci-stamp-migration-versions.rb") }
  let(:script)         { File.read(script_path) }
  let(:ci)             { YAML.safe_load(File.read(File.join(extension_root, ".gitea/workflows/ci.yaml")), aliases: true) }

  # Every job that loads a schema must then stamp; a job that does one without
  # the other is the exact failure above.
  def prepare_steps
    ci.fetch("jobs").flat_map do |job_name, job|
      Array(job["steps"]).filter_map do |step|
        run = step["run"].to_s
        [ job_name, run ] if run.include?("db:schema:load")
      end
    end
  end

  it "finds the jobs that load the schema" do
    expect(prepare_steps).not_to be_empty,
      "no CI step runs db:schema:load — this guard's derivation has drifted and " \
      "would otherwise pass vacuously"
  end

  it "stamps via the shared script in every job that loads the schema" do
    missing = prepare_steps.reject { |_, run| run.include?("ci-stamp-migration-versions.rb") }
    expect(missing.map(&:first)).to be_empty,
      "these jobs load a schema without stamping through the shared script, so a core " \
      "migration above schema.rb's version will read as pending: #{missing.map(&:first).inspect}"
  end

  it "keeps no inline extension-only backfill behind" do
    offenders = prepare_steps.select { |_, run| run.include?('Dir.glob("../extensions') }
    expect(offenders.map(&:first)).to be_empty,
      "an inline backfill has come back; it is what missed core migrations: " \
      "#{offenders.map(&:first).inspect}"
  end

  # The whole point of the fix: BOTH trees, not just extensions.
  it "globs core migrations as well as extension migrations" do
    expect(script).to include('Dir.glob("db/migrate/*.rb")'),
      "the script must glob CORE migrations — a core data-only migration is stamped by " \
      "nothing else"
    expect(script).to include('Dir.glob("../extensions/*/server/db/migrate/*.rb")'),
      "the script must still glob extension migrations"
  end

  it "fails loudly rather than stamping nothing when a glob comes back empty" do
    expect(script).to match(/if core\.empty\?.*abort/m)
    expect(script).to match(/if extensions\.empty\?.*abort/m)
  end
end
