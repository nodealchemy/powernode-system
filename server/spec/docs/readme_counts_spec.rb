# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Drift guard for three hand-maintained counts in the extension's top-level
# README.md that were all found stale in the same session: "21 fleet
# sensors" (actual: 36 registered in FleetAutonomyService::SENSORS), "50 AI
# Skill executors" (actual: 65 binds_to-declaring executors — the same
# figure docs/SKILL_EXECUTORS.md and docs/SKILL_EXECUTOR_CATALOG.md already
# state and reference_counts_spec.rb already guards there), and "Worker jobs
# (12)" naming a list that had drifted from worker/config/sidekiq_system.yml
# on BOTH axes at once — four names it listed are not scheduled at all
# (system_execute_task, system_package_embedding,
# system_package_module_materialize, system_package_module_refresh — these
# are event-driven jobs, never cron/every entries) while two scheduled jobs
# were missing entirely (sdwan_flow_sample_retention,
# system_fulfillment_request_reconcile). A bare count fix would have left
# the wrong roster stated correctly-numbered, so this guards the roster too.
#
# Follows reference_counts_spec.rb's pattern (same directory): derive the
# real counts from disk/source, parse the number and roster the doc states in
# prose, and assert equality — never restate the same literal on both sides,
# which guards nothing.
#
# What it does NOT catch: prose rewording elsewhere in README.md, or a count
# that's wrong in the same way here and in this spec's own regexes. If the
# doc's phrasing around these figures changes, the parse itself raises with a
# clear message instead of silently comparing 0 == 0.
RSpec.describe "README.md counts vs. reality" do
  ext_root      = File.expand_path("../../..", __dir__)
  sensors_dir   = File.join(ext_root, "server/app/services/system/fleet/sensors")
  service_path  = File.join(ext_root, "server/app/services/system/fleet/fleet_autonomy_service.rb")
  skills_dir    = File.join(ext_root, "server/app/services/system/ai/skills")
  schedule_path = File.join(ext_root, "worker/config/sidekiq_system.yml")
  readme_path   = File.join(ext_root, "README.md")

  let(:readme_text) { File.read(readme_path) }

  let(:registered_sensor_names) do
    src = File.read(service_path)
    block = src[/SENSORS\s*=\s*\[(.*?)\]\.freeze/m, 1]
    unless block
      raise "could not locate the FleetAutonomyService::SENSORS array literal in " \
            "#{service_path} — has it been renamed or restructured? update this spec's regex."
    end
    block.scan(/::System::Fleet::Sensors::(\w+)/).flatten
  end

  # Concrete executors declare `binds_to "<Agent Name>"` at class scope; the
  # abstract BaseSkillExecutor only *defines* the `binds_to` macro, which
  # this pattern does not match. Mirrors reference_counts_spec.rb exactly so
  # the two specs cannot silently diverge on what "an executor" means.
  let(:concrete_executor_files) do
    Dir.glob(File.join(skills_dir, "*_executor.rb")).select do |path|
      File.read(path).match?(/^\s*binds_to\s+["']/)
    end
  end

  # The schedule keys ARE the job names README.md's bullet lists (e.g.
  # `system_task_reaper`), not the Sidekiq `class:` values — read as a plain
  # YAML doc rather than via Rails' symbolize-keys loader so this spec has no
  # Rails-env dependency.
  let(:scheduled_job_names) do
    doc = YAML.safe_load(File.read(schedule_path), permitted_classes: [ Symbol ], aliases: true)
    schedule = doc[:schedule] || doc["schedule"]
    unless schedule.is_a?(Hash)
      raise "could not find a top-level `:schedule:` map in #{schedule_path} — " \
            "has the file's shape changed? update this spec."
    end
    schedule.keys.map(&:to_s)
  end

  def doc_number(text, pattern, label)
    match = text.match(pattern)
    unless match
      raise "README.md: could not find the \"#{label}\" figure (pattern #{pattern.inspect}) — " \
            "the doc's phrasing around this number likely changed; update this spec's regex " \
            "to match the new wording rather than treating this as a passing/failing count."
    end
    match[1].to_i
  end

  it "states the fleet-sensor count correctly" do
    stated = doc_number(readme_text, /\*\*(\d+) fleet sensors\*\*/, "fleet sensor count")
    expect(stated).to eq(registered_sensor_names.size),
      "README.md claims #{stated} fleet sensors; FleetAutonomyService::SENSORS actually has " \
      "#{registered_sensor_names.size}"
  end

  it "states the AI Skill executor count correctly" do
    stated = doc_number(readme_text, /\*\*(\d+) AI Skill executors\*\*/, "AI Skill executor count")
    expect(stated).to eq(concrete_executor_files.size),
      "README.md claims #{stated} AI Skill executors; #{skills_dir} actually has " \
      "#{concrete_executor_files.size} concrete (binds_to-declaring) executors"
  end

  it "states the scheduled worker-job count correctly, and lists exactly the scheduled jobs" do
    stated = doc_number(readme_text, /Worker jobs \((\d+) scheduled\)/, "scheduled worker-job count")
    expect(stated).to eq(scheduled_job_names.size),
      "README.md claims #{stated} scheduled worker jobs; #{schedule_path} actually schedules " \
      "#{scheduled_job_names.size}"

    bullet = readme_text[/Worker jobs \(\d+ scheduled\):(.*?)\n- /m, 1] ||
             readme_text[/Worker jobs \(\d+ scheduled\):(.*?)\n\n/m, 1]
    unless bullet
      raise "could not isolate the \"Worker jobs (N scheduled)\" bullet's job list in " \
            "#{readme_path} — has its wording or the following bullet changed? update this spec."
    end
    listed = bullet.scan(/`(\w+)`/).flatten

    # EQUALITY, not inclusion — the roster drifted on both axes at once
    # (extra event-driven jobs listed, real scheduled jobs missing), and an
    # inclusion check alone would have let either half rot again silently.
    missing = scheduled_job_names - listed
    extra   = listed - scheduled_job_names
    expect(missing).to be_empty,
      "README.md's Worker jobs bullet omits scheduled jobs: #{missing.join(', ')}"
    expect(extra).to be_empty,
      "README.md's Worker jobs bullet lists jobs #{schedule_path} does not schedule: #{extra.join(', ')}"
  end
end
