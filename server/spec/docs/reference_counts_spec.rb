# frozen_string_literal: true

require "spec_helper"

# Drift guard for the two hand-maintained counts that repeatedly went stale
# in SKILL_EXECUTORS.md / FLEET_SENSORS.md (IMP-c5d4a8e61e55 "round 2" — they
# had already been corrected once before and drifted again). Derives the real
# counts from disk and from the source they describe, and cross-checks them
# against the numbers the two docs state in prose. A future drift (someone
# adds/removes an executor or a sensor, or registers/unregisters one, without
# updating the doc) fails THIS spec instead of rotting silently until the
# next manual audit.
#
# What it catches: the total *_executor.rb file count, the concrete
# (binds_to-declaring) executor count, the total fleet/sensors/ file count,
# the count of sensors actually registered in FleetAutonomyService::SENSORS,
# the exact (ordered) list of sensor class names named in the doc's
# inventory sentence, and the Fleet Autonomy "(N policies)" heading count
# against the actual key count of the `fleet_policies` hash literal seeded
# in db/seeds/fleet_autonomy_agent.rb.
#
# What it does NOT catch: prose rewording elsewhere in either doc, a count
# that's wrong in the same way in both the doc and this spec's own regexes,
# or a sensor/executor that exists on disk but was never meant to be counted
# here (e.g. the two CVE sensors under cve_ops/sensors/, which the doc text
# explicitly excludes from this directory's count). If either doc's phrasing
# around these numbers changes (e.g. "**53 skill executors**" loses its bold
# markers), the parse itself raises with a clear message instead of silently
# comparing 0 == 0 — that is a "the regex needs updating" signal, not
# evidence of a real drift.
#
# Lives under spec/docs/ (a new directory — no docs spec directory existed
# yet) rather than spec/scripts/ or spec/schema/, the two closest existing
# precedents for a doc/config-vs-code consistency guard: both are scoped to
# a narrower artifact (a shell script's behavior, a JSON schema's pattern)
# and neither is about prose figures in a markdown reference doc.
RSpec.describe "SKILL_EXECUTORS.md / FLEET_SENSORS.md counts vs. reality" do
  ext_root     = File.expand_path("../../..", __dir__)
  skills_dir   = File.join(ext_root, "server/app/services/system/ai/skills")
  sensors_dir  = File.join(ext_root, "server/app/services/system/fleet/sensors")
  service_path = File.join(ext_root, "server/app/services/system/fleet/fleet_autonomy_service.rb")

  policy_seed_path = File.join(ext_root, "server/db/seeds/fleet_autonomy_agent.rb")

  executors_doc_path = File.join(ext_root, "docs/SKILL_EXECUTORS.md")
  sensors_doc_path    = File.join(ext_root, "docs/FLEET_SENSORS.md")

  let(:executor_files) { Dir.glob(File.join(skills_dir, "*_executor.rb")).sort }

  # Concrete executors declare `binds_to "<Agent Name>"` at class scope; the
  # abstract BaseSkillExecutor only *defines* the `binds_to` macro (`def
  # binds_to(*agents)`), which this pattern does not match.
  let(:concrete_executor_files) do
    executor_files.select { |path| File.read(path).match?(/^\s*binds_to\s+["']/) }
  end

  let(:sensor_files) { Dir.glob(File.join(sensors_dir, "*.rb")).sort }

  let(:registered_sensor_names) do
    src = File.read(service_path)
    block = src[/SENSORS\s*=\s*\[(.*?)\]\.freeze/m, 1]
    unless block
      raise "could not locate the FleetAutonomyService::SENSORS array literal in " \
            "#{service_path} — has it been renamed or restructured? update this spec's regex."
    end
    block.scan(/::System::Fleet::Sensors::(\w+)/).flatten
  end

  let(:policy_seed_text) { File.read(policy_seed_path) }

  # The seed defines `fleet_policies = { ... }` then immediately consumes it
  # via `count = System::Seeds::AgentSetupHelpers.upsert_policies!(...)` —
  # slicing the source between those two markers isolates the hash literal
  # without needing to `load` the seed (which would require a Rails env).
  # `.uniq` mirrors real Hash literal semantics: a duplicate key would
  # collapse at runtime even though the source scan would see it twice, so
  # counting unique keys is what actually matches `fleet_policies.size`.
  let(:seeded_policy_keys) do
    start = policy_seed_text.index("fleet_policies = {")
    unless start
      raise "could not find `fleet_policies = {` in #{policy_seed_path} — " \
            "has the seed been restructured? update this spec's regex."
    end
    stop = policy_seed_text.index("count = System::Seeds", start)
    unless stop
      raise "could not find the end of the fleet_policies block " \
            "(`count = System::Seeds...`) in #{policy_seed_path} — update this spec's regex."
    end
    block = policy_seed_text[start...stop]
    block.scan(/"(system\.[a-zA-Z0-9_.]+)"\s*=>/).flatten.uniq
  end

  let(:executors_doc_text) { File.read(executors_doc_path) }
  let(:sensors_doc_text)   { File.read(sensors_doc_path) }

  def doc_number(doc_text, pattern, label, doc_path)
    match = doc_text.match(pattern)
    unless match
      raise "#{doc_path}: could not find the \"#{label}\" figure (pattern #{pattern.inspect}) — " \
            "the doc's phrasing around this number likely changed; update this spec's regex " \
            "to match the new wording rather than treating this as a passing/failing count."
    end
    match[1].to_i
  end

  it "SKILL_EXECUTORS.md's total *_executor.rb file count matches disk" do
    stated = doc_number(
      executors_doc_text,
      /directory holds (\d+) `\*_executor\.rb` files/,
      "total *_executor.rb files", executors_doc_path
    )
    expect(stated).to eq(executor_files.size),
      "SKILL_EXECUTORS.md claims #{stated} `*_executor.rb` files; " \
      "#{skills_dir} actually has #{executor_files.size}"
  end

  it "SKILL_EXECUTORS.md's concrete (binds_to-declaring) executor count matches disk" do
    stated = doc_number(
      executors_doc_text,
      /\*\*(\d+) skill executors\*\*/,
      "concrete skill executor count", executors_doc_path
    )
    expect(stated).to eq(concrete_executor_files.size),
      "SKILL_EXECUTORS.md claims #{stated} concrete skill executors (binds_to-declaring); " \
      "#{skills_dir} actually has #{concrete_executor_files.size}"
  end

  it "FLEET_SENSORS.md's total fleet/sensors/ file count matches disk" do
    stated = doc_number(
      sensors_doc_text,
      /holds \*\*(\d+) files\*\*/,
      "total sensor-directory files", sensors_doc_path
    )
    expect(stated).to eq(sensor_files.size),
      "FLEET_SENSORS.md claims #{stated} files in fleet/sensors/; " \
      "#{sensors_dir} actually has #{sensor_files.size}"
  end

  it "FLEET_SENSORS.md's registered-sensor count matches FleetAutonomyService::SENSORS" do
    stated = doc_number(
      sensors_doc_text,
      /\*\*(\d+) sensors registered\*\*/,
      "registered sensor count", sensors_doc_path
    )
    expect(stated).to eq(registered_sensor_names.size),
      "FLEET_SENSORS.md claims #{stated} sensors registered; " \
      "FleetAutonomyService::SENSORS actually has #{registered_sensor_names.size}"
  end

  it "FLEET_SENSORS.md's inventory sentence lists exactly the sensors registered, in order" do
    # Independent of whether the raw counts happen to still agree, this
    # catches a sensor being renamed, swapped, or reordered in one place but
    # not the other (e.g. two sensors both added, keeping the count right
    # but the roster wrong).
    sentence = sensors_doc_text[/The \d+ registered sensors, in `SENSORS` order:(.*?)\./m, 1]
    unless sentence
      raise "could not find the sensor inventory sentence in #{sensors_doc_path} — " \
            "has its wording changed? update this spec's regex."
    end
    doc_names = sentence.scan(/`(\w+Sensor)`/).flatten

    expect(doc_names).to eq(registered_sensor_names),
      "FLEET_SENSORS.md's inventory sentence lists #{doc_names.inspect}; " \
      "FleetAutonomyService::SENSORS is actually #{registered_sensor_names.inspect}"
  end

  it "FLEET_SENSORS.md's Fleet Autonomy policy count matches db/seeds/fleet_autonomy_agent.rb" do
    stated = doc_number(
      sensors_doc_text,
      /Fleet Autonomy agent \((\d+) policies\)/,
      "Fleet Autonomy policy count", sensors_doc_path
    )
    expect(stated).to eq(seeded_policy_keys.size),
      "FLEET_SENSORS.md claims Fleet Autonomy has #{stated} policies; " \
      "#{policy_seed_path}'s fleet_policies hash actually has #{seeded_policy_keys.size} keys"
  end
end
