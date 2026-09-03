# frozen_string_literal: true

require "spec_helper"

# Drift guard for the hand-maintained counts that repeatedly went stale
# in SKILL_EXECUTORS.md / FLEET_SENSORS.md / CLAUDE.md (IMP-c5d4a8e61e55
# "round 2" — they had already been corrected once before and drifted again;
# IMP-1463ab389e0c extended this to CLAUDE.md after it was found
# self-contradicting on the executor count — 54 in one place, 49 in two
# others, ground truth 53 — while nothing guarded it: CLAUDE.md is the file
# most likely to be read by an AI session at load time, and it was the one
# file nothing checked). Derives the real counts from disk and from the
# source they describe, and cross-checks them against the numbers the docs
# state in prose. A future drift (someone adds/removes an executor or a
# sensor, or registers/unregisters one, without updating the doc) fails THIS
# spec instead of rotting silently until the next manual audit.
#
# What it catches: the total *_executor.rb file count, the concrete
# (binds_to-declaring) executor count, the total fleet/sensors/ file count,
# the count of sensors actually registered in FleetAutonomyService::SENSORS,
# the exact (ordered) list of sensor class names named in the doc's
# inventory sentence, every per-agent "(N policies)" heading, seed bullet and
# the eight-agent total against the key counts of the PolicyDeclarations
# constants (HIER-P2A — before that only Fleet Autonomy's heading was pinned),
# CLAUDE.md's per-agent policy counts, CLAUDE.md's three separate citations
# of the executor count (the table cell's total-files/concrete-classes pair,
# the "already cover" convention line, and the Related Docs line), CLAUDE.md's
# Capability Domains header count against its own table's actual row count,
# and CLAUDE.md's Related Docs citation of the fleet-sensor count.
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
RSpec.describe "SKILL_EXECUTORS.md / FLEET_SENSORS.md / CLAUDE.md counts vs. reality" do
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

  # Scan the DECLARATIONS file, not the seed and not the constant.
  #
  # These policy sets moved out of fleet_autonomy_agent.rb into
  # System::Governance::PolicyDeclarations so the boot reconciler can assert
  # them against a RUNNING database; the seed now just consumes the constant,
  # so slicing its source between two markers found nothing and this spec
  # RAISED rather than failing an assertion.
  #
  # Still a TEXT SCAN, deliberately: this file is a docs-vs-source count check
  # that runs without a Rails env (referencing the constant here raises
  # NameError: uninitialized constant System). Slicing between the constant
  # assignment and its `.freeze` isolates the literal the same way the old
  # marker pair isolated the seed's hash. `.uniq` mirrors real Hash semantics —
  # a duplicate key collapses at runtime while the scan would see it twice.
  let(:declarations_path) do
    File.expand_path("../../app/services/system/governance/policy_declarations.rb", __dir__)
  end
  let(:declarations_text) { File.read(declarations_path) }

  # Keys of a declared constant, by TEXT SCAN, following its shape:
  #
  #   NAME = { "a" => "verb", ... }.freeze
  #   NAME = { ... }.merge(GROUP_A, GROUP_B).freeze     # HIER-P2A sub-hashes
  #   NAME = OTHER.merge(ANOTHER).freeze
  #
  # The slice runs from `NAME = ` to the FIRST `.freeze` after it (no policy
  # literal carries that token in a comment — the scan raises if it does not
  # find the end), comment lines are dropped so a commented-out key or a
  # constant NAMED in prose is never counted, and every constant the head or
  # a `.merge(...)` names is expanded recursively. `.uniq` mirrors real Hash
  # semantics — a duplicate key collapses at runtime while the scan would see
  # it twice.
  def declared_keys(name)
    start = declarations_text.index("      #{name} = ")
    unless start
      raise "could not find `#{name} = ` in #{declarations_path} — " \
            "has the declaration been renamed? update this spec's scan."
    end
    stop = declarations_text.index(".freeze", start)
    unless stop
      raise "could not find the end of the #{name} declaration (`.freeze`) " \
            "in #{declarations_path} — update this spec's scan."
    end
    body = declarations_text[start...stop].lines.reject { |l| l.strip.start_with?("#") }.join

    literal = body.scan(/"([a-z][a-z0-9_]*\.[a-zA-Z0-9_.]+)"\s*=>/).flatten
    head = body[/\A\s*#{Regexp.escape(name)}\s*=\s*([A-Z][A-Z0-9_]*)\.merge/, 1]
    merged = body.scan(/\.merge\(([^)]*)\)/).flatten.flat_map { |args| args.scan(/[A-Z][A-Z0-9_]*/) }
    ([ head ].compact + merged).uniq.each { |other| literal.concat(declared_keys(other)) }
    literal.uniq
  end

  let(:seeded_policy_keys) { declared_keys("FLEET_AUTONOMY_POLICIES") }

  # The per-agent seed sets, keyed by the FLEET_SENSORS.md bullet / section
  # name they are stated under. Eight seeded agents; two carry no policies.
  let(:agent_policy_counts) do
    {
      "Fleet Autonomy"     => declared_keys("FLEET_AUTONOMY_POLICIES").size,
      "Runtime Manager"    => declared_keys("RUNTIME_MANAGER_POLICIES").size,
      "CVE Responder"      => declared_keys("CVE_RESPONDER_POLICIES").size,
      "SDWAN Manager"      => declared_keys("SDWAN_MANAGER_POLICIES").size,
      "Disk Image Manager" => declared_keys("DISK_IMAGE_MANAGER_POLICIES").size,
      "GitOps Reconciler"  => declared_keys("GITOPS_RECONCILER_POLICIES").size
    }
  end

  let(:agent_seed_files) do
    {
      "Fleet Autonomy"     => "fleet_autonomy_agent.rb",
      "Runtime Manager"    => "system_runtime_manager_agent.rb",
      "CVE Responder"      => "system_cve_responder_agent.rb",
      "SDWAN Manager"      => "system_sdwan_manager_agent.rb",
      "Disk Image Manager" => "system_disk_image_manager_agent.rb",
      "GitOps Reconciler"  => "system_gitops_reconciler_agent.rb"
    }
  end

  let(:executors_doc_text) { File.read(executors_doc_path) }
  let(:sensors_doc_text)   { File.read(sensors_doc_path) }

  claude_md_path = File.join(ext_root, "CLAUDE.md")
  let(:claude_md_text) { File.read(claude_md_path) }

  # The "## Capability Domains (N)" table is CLAUDE.md's own content — no
  # external source to derive N from, so ground truth is the table's own row
  # count (total `|`-prefixed lines minus the header row and the `|---|`
  # separator row). Raises with a clear message if the table shape changes
  # enough that this stops making sense, rather than silently comparing a
  # nonsense count.
  let(:capability_domains_row_count) do
    block = claude_md_text[/## Capability Domains \(\d+\)(.*?)\n##/m, 1]
    unless block
      raise "could not locate the Capability Domains table in #{claude_md_path} — " \
            "has the heading or the section after it changed? update this spec's regex."
    end
    pipe_lines = block.lines.select { |l| l.start_with?("|") }
    unless pipe_lines.size >= 2 && pipe_lines[0].include?("Domain") && pipe_lines[1].match?(/^\|[\s-]+\|/)
      raise "Capability Domains table in #{claude_md_path} doesn't look like a standard " \
            "header+separator+rows markdown table anymore — update this spec's row-counting logic."
    end
    pipe_lines.size - 2
  end

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

  it "FLEET_SENSORS.md's Fleet Autonomy policy count matches PolicyDeclarations::FLEET_AUTONOMY_POLICIES" do
    stated = doc_number(
      sensors_doc_text,
      /Fleet Autonomy agent \((\d+) policies\)/,
      "Fleet Autonomy policy count", sensors_doc_path
    )
    expect(stated).to eq(seeded_policy_keys.size),
      "FLEET_SENSORS.md claims Fleet Autonomy has #{stated} policies; " \
      "#{declarations_path}'s FLEET_AUTONOMY_POLICIES actually has #{seeded_policy_keys.size} keys"
  end

  # The scan's own integrity: FLEET_AUTONOMY_POLICIES is a literal MERGED with
  # four named groups (HIER-P2A), so a scan that stopped at the literal would
  # under-count silently and every count below would pin the wrong figure.
  it "expands the merged sub-hashes when scanning FLEET_AUTONOMY_POLICIES (guards the scan from under-counting)" do
    groups = %w[CAPACITY_POLICY_KEYS STORAGE_POLICY_KEYS INGRESS_POLICY_KEYS SUPPLY_CHAIN_POLICY_KEYS]
    group_keys = groups.flat_map { |g| declared_keys(g) }
    expect(group_keys).not_to be_empty
    expect(seeded_policy_keys).to include(*group_keys)
    expect(declared_keys("SDWAN_MANAGER_POLICIES"))
      .to match_array(declared_keys("SDWAN_OPERATOR_POLICIES") + declared_keys("SDWAN_REMEDIATION_POLICIES"))
  end

  # ==========================================================================
  # HIER-P2A: every per-agent figure in FLEET_SENSORS.md's Intervention Policy
  # Reference is pinned — the bullets, the section headers and the total.
  # Until now only the Fleet Autonomy header was, and the bullets and the
  # total drifted from it twice.
  # ==========================================================================

  it "FLEET_SENSORS.md's per-agent seed bullets match the PolicyDeclarations sets" do
    agent_policy_counts.each do |agent, actual|
      file = agent_seed_files.fetch(agent)
      stated = doc_number(
        sensors_doc_text,
        /`db\/seeds\/#{Regexp.escape(file)}` — \*\*(\d+) policies\*\*/,
        "#{agent} seed bullet count", sensors_doc_path
      )
      expect(stated).to eq(actual),
        "FLEET_SENSORS.md's bullet for #{file} claims #{stated} policies; the declared set has #{actual}"
    end
  end

  it "FLEET_SENSORS.md's per-agent section headers match the PolicyDeclarations sets" do
    agent_policy_counts.each do |agent, actual|
      stated = doc_number(
        sensors_doc_text,
        /### #{Regexp.escape(agent)} agent \((\d+) policies\)/,
        "#{agent} section header count", sensors_doc_path
      )
      expect(stated).to eq(actual),
        "FLEET_SENSORS.md's '### #{agent} agent (#{stated} policies)' header disagrees with the declared set (#{actual})"
    end
  end

  it "FLEET_SENSORS.md's eight-agent total is the sum of the per-agent sets" do
    stated = doc_number(
      sensors_doc_text,
      /\*\*= (\d+) action-category policies across the eight system-extension agents\*\*/,
      "eight-agent policy total", sensors_doc_path
    )
    expect(stated).to eq(agent_policy_counts.values.sum),
      "FLEET_SENSORS.md's total claims #{stated}; the six policy-carrying sets sum to #{agent_policy_counts.values.sum}"
  end

  # The per-agent OPERATOR GUIDES carry the same numbers as CLAUDE.md and
  # FLEET_SENSORS.md and were the copies that rotted at HIER-P2A: the SDWAN
  # guide still claimed the 14 autonomous remediations lived on Fleet Autonomy
  # and that the agent shipped 41 policies, the Disk Image guide still said 6.
  # Both were edited by that change, so the stale figures were on screen — the
  # missing piece was a guard. These pin them to the same declared sets.
  sdwan_guide_path = File.join(ext_root, "docs", "SDWAN_MANAGER_AGENT.md")
  disk_guide_path  = File.join(ext_root, "docs", "DISK_IMAGE_MANAGER_AGENT.md")
  let(:sdwan_guide_text) { File.read(sdwan_guide_path) }
  let(:disk_guide_text)  { File.read(disk_guide_path) }

  it "SDWAN_MANAGER_AGENT.md states the agent's total, operator and remediation counts correctly" do
    total       = declared_keys("SDWAN_MANAGER_POLICIES").size
    operator    = declared_keys("SDWAN_OPERATOR_POLICIES").size
    remediation = declared_keys("SDWAN_REMEDIATION_POLICIES").size

    expect(doc_number(sdwan_guide_text, /ships with \*\*(\d+) intervention policies\*\*/,
                      "SDWAN guide total", sdwan_guide_path)).to eq(total)
    expect(doc_number(sdwan_guide_text, /These \*\*(\d+)\*\* policies live \*\*here\*\*/,
                      "SDWAN guide operator count", sdwan_guide_path)).to eq(operator)
    expect(doc_number(sdwan_guide_text, /These \*\*(\d+)\*\* policies also live \*\*here\*\*/,
                      "SDWAN guide remediation count", sdwan_guide_path)).to eq(remediation)
    expect(doc_number(sdwan_guide_text, /Total: \*\*(\d+)\*\* policies/,
                      "SDWAN guide prefix-split total", sdwan_guide_path)).to eq(total)
  end

  it "DISK_IMAGE_MANAGER_AGENT.md states the agent's policy count correctly, and its table lists every declared key" do
    declared = declared_keys("DISK_IMAGE_MANAGER_POLICIES")

    expect(doc_number(disk_guide_text, /ships with \*\*(\d+) intervention policies\*\*/,
                      "Disk Image guide total", disk_guide_path)).to eq(declared.size)
    expect(doc_number(disk_guide_text, /of the (\d+) policies below/,
                      "Disk Image guide caveat count", disk_guide_path)).to eq(declared.size)

    # The count agreeing while the TABLE omits the new row is exactly the
    # half-fix this guard exists to refuse — so read the table\'s own rows, not
    # the whole file: every key is also named in the surrounding prose, which
    # would satisfy a document-wide `include?` while the table stayed short.
    table_keys = disk_guide_text.scan(/^\| `(system\.[a-z0-9_]+)` \|/).flatten
    missing = declared - table_keys
    expect(missing).to be_empty,
      "DISK_IMAGE_MANAGER_AGENT.md's policy table has no row for #{missing.join(', ')} " \
      "(table rows found: #{table_keys.size}, declared: #{declared.size})"
  end

  it "CLAUDE.md's agent roster states each agent's intervention-policy count correctly" do
    agent_policy_counts.each do |agent, actual|
      stated = doc_number(
        claude_md_text,
        /- \*\*#{Regexp.escape(agent)}\*\*[^\n]*?(\d+) intervention policies/,
        "CLAUDE.md #{agent} policy count", claude_md_path
      )
      expect(stated).to eq(actual),
        "CLAUDE.md's roster claims #{agent} has #{stated} intervention policies; the declared set has #{actual}"
    end
  end

  # ==========================================================================
  # IMP-1463ab389e0c: CLAUDE.md is the file most likely to be read by an AI
  # session at load time, and it cited the skill-executor count THREE times
  # with two different (both wrong) numbers, plus its own Capability Domains
  # table header and its Related Docs citation of the sensor count had also
  # drifted — and nothing guarded any of it. These five checks close that gap.
  # ==========================================================================

  # NOTE: unlike the checks below, this pair was ALREADY correct on disk when
  # found (54 total `*_executor.rb` files, 53 of them declaring `binds_to` —
  # both true) — the finding that flagged it turned out to be the one that
  # was wrong, not the doc. Left as-is; guarded here so it can't drift later.
  it "CLAUDE.md's skill-executor table cell states the total *_executor.rb file count correctly" do
    stated = doc_number(
      claude_md_text,
      /(\d+) executor classes, \d+ with `binds_to`/,
      "CLAUDE.md skill-executor table-cell total file count", claude_md_path
    )
    expect(stated).to eq(executor_files.size),
      "CLAUDE.md's Capability Domains table cell claims #{stated} executor classes; " \
      "#{skills_dir} actually has #{executor_files.size} `*_executor.rb` files"
  end

  it "CLAUDE.md's skill-executor table cell states the concrete (binds_to) count correctly" do
    stated = doc_number(
      claude_md_text,
      /\d+ executor classes, (\d+) with `binds_to`/,
      "CLAUDE.md skill-executor table-cell concrete count", claude_md_path
    )
    expect(stated).to eq(concrete_executor_files.size),
      "CLAUDE.md's Capability Domains table cell claims #{stated} executors with `binds_to`; " \
      "#{skills_dir} actually has #{concrete_executor_files.size} concrete executors"
  end

  it "CLAUDE.md's 'skill executors already cover' convention line matches disk" do
    stated = doc_number(
      claude_md_text,
      %r{(\d+) already cover most fleet/SDWAN/runtime/topology workflows},
      "CLAUDE.md 'already cover' executor count", claude_md_path
    )
    expect(stated).to eq(concrete_executor_files.size),
      "CLAUDE.md's conventions section claims #{stated} skill executors already cover most workflows; " \
      "#{skills_dir} actually has #{concrete_executor_files.size} concrete executors"
  end

  it "CLAUDE.md's Related Docs citation of SKILL_EXECUTORS.md's executor count matches disk" do
    stated = doc_number(
      claude_md_text,
      /SKILL_EXECUTORS\.md`\s*—\s*(\d+) executor reference/,
      "CLAUDE.md Related Docs SKILL_EXECUTORS.md citation", claude_md_path
    )
    expect(stated).to eq(concrete_executor_files.size),
      "CLAUDE.md's Related Docs line claims SKILL_EXECUTORS.md is a #{stated}-executor reference; " \
      "#{skills_dir} actually has #{concrete_executor_files.size} concrete executors"
  end

  it "CLAUDE.md's Related Docs citation of FLEET_SENSORS.md's registered-sensor count matches reality" do
    stated = doc_number(
      claude_md_text,
      /(\d+) fleet sensors \(tick-registered\)/,
      "CLAUDE.md Related Docs FLEET_SENSORS.md citation", claude_md_path
    )
    expect(stated).to eq(registered_sensor_names.size),
      "CLAUDE.md's Related Docs line claims #{stated} tick-registered fleet sensors; " \
      "FleetAutonomyService::SENSORS actually has #{registered_sensor_names.size}"
  end

  it "CLAUDE.md's Capability Domains header count matches its own table's row count" do
    stated = doc_number(
      claude_md_text,
      /## Capability Domains \((\d+)\)/,
      "CLAUDE.md Capability Domains header count", claude_md_path
    )
    expect(stated).to eq(capability_domains_row_count),
      "CLAUDE.md's '## Capability Domains (#{stated})' header doesn't match its own table, " \
      "which actually has #{capability_domains_row_count} rows"
  end
end
