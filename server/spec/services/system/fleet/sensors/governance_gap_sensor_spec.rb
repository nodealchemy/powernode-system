# frozen_string_literal: true

require "rails_helper"

# HIER-P3 — the GovernanceGapSensor reproduces, on every fleet tick, the gap
# kinds the 2026-09-03 hierarchy audit found BY HAND: a declared category no
# agent set owns, an agent that carries policies but binds no skill, a
# SIGNAL_BINDINGS lane bound to `skill: nil` that nothing declares deliberate,
# an executor with no Ai::Skill catalog row, a canonical with no lineage edge
# or no delegation policy, a declared category's row parked on an agent the
# declarations do not know, and a tool_families entry naming nothing the
# registry serves.
#
# One example per kind, each planting EXACTLY ONE gap and asserting exactly
# one fingerprinted signal for it — the property the propose executor's dedup
# rests on (one gap, one fingerprint, one offer).
RSpec.describe System::Fleet::Sensors::GovernanceGapSensor do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider, account: account) }

  subject(:sensor) { described_class.new(account: account) }

  # The registry-derived detector reads SkillBindingsReconciler#drift, which on
  # an UNSEEDED test database reports every executor's catalog row missing —
  # a flood that would hide the one gap each example plants. Quiet by default;
  # the registry example below feeds it a plan of its own.
  let(:quiet_drift) do
    System::Ai::Skills::SkillBindingsReconciler::Drift.new(
      missing: [], missing_pairs: [], stale: [], unknown_agents: [], missing_skills: [], registry_empty: false
    )
  end

  before do
    allow_any_instance_of(System::Ai::Skills::SkillBindingsReconciler).to receive(:drift).and_return(quiet_drift)
  end

  def global_agent!(name:, agent_type:, source_key:, slug: nil, skills: 0, **attrs)
    agent = create(:ai_agent, account: nil, name: name, agent_type: agent_type, source_key: source_key,
                              slug: slug || source_key, is_system: true, provider: provider, creator: user, **attrs)
    skills.times { create(:ai_agent_skill, agent: agent, skill: create(:ai_skill, :global)) }
    agent
  end

  def signals_of(kind)
    sensor.sense.select { |s| s.payload["gap_kind"] == kind }
  end

  it "declares its tunable cap through the sensor-config seam" do
    expect(described_class.default_thresholds).to eq("max_per_tick" => 25)
    expect(described_class.sensor_key).to eq("governance_gap")
  end

  it "is silent on an account with nothing declared out of place" do
    expect(sensor.sense).to eq([])
  end

  describe "a declared category no agent set owns" do
    before do
      real = Ai::InterventionPolicy.registered_categories
      allow(Ai::InterventionPolicy).to receive(:registered_categories).and_return(real + [ "system.orphan_lane_probe" ])
    end

    it "emits exactly one HIGH signal fingerprinted on the category, naming the declarations file" do
      found = signals_of("category_unowned")

      expect(found.size).to eq(1)
      signal = found.first
      expect(signal.kind).to eq("system.governance_gap")
      expect(signal.severity).to eq(:high)
      expect(signal.fingerprint).to eq("governance_gap:category_unowned:system.orphan_lane_probe")
      expect(signal.payload).to include(
        "subject" => "system.orphan_lane_probe",
        "recommendation_type" => "capability_gap",
        "_sensor" => "GovernanceGapSensor"
      )
      expect(signal.payload["files"]).to include(a_string_matching(/policy_declarations\.rb/))
      expect(signal.payload["materialization"]).to be_nil
    end

    it "does not report a category some set declares (the manual operator set included)" do
      subjects = signals_of("category_unowned").map { |s| s.payload["subject"] }
      expect(subjects).to eq([ "system.orphan_lane_probe" ])
    end
  end

  describe "an agent with policies but no skill binding" do
    let!(:storage) { global_agent!(name: "Storage Manager", agent_type: "monitor", source_key: "storage-manager") }

    it "emits exactly one MEDIUM signal for the declared identity" do
      found = signals_of("agent_without_skills")

      expect(found.size).to eq(1)
      expect(found.first.severity).to eq(:medium)
      expect(found.first.fingerprint).to eq("governance_gap:agent_without_skills:storage-manager")
      expect(found.first.payload).to include(
        "subject" => "storage-manager",
        "agent_id" => storage.id,
        "recommendation_type" => "skill_creation"
      )
      expect(found.first.payload["declared_policies"]).to be > 0
    end

    it "clears the moment the agent binds a skill" do
      create(:ai_agent_skill, agent: storage, skill: create(:ai_skill, :global))
      expect(signals_of("agent_without_skills")).to eq([])
    end

    it "offers the registry's own pairs for that agent as the runtime materialisation when it declares any" do
      skill = create(:ai_skill, :global, slug: "system-restore-volume")
      drift = System::Ai::Skills::SkillBindingsReconciler::Drift.new(
        missing: [ "Storage Manager → system-restore-volume" ],
        missing_pairs: [ { "agent_id" => storage.id, "agent_name" => "Storage Manager",
                           "skill_id" => skill.id, "skill_slug" => "system-restore-volume" } ],
        stale: [], unknown_agents: [], missing_skills: [], registry_empty: false
      )
      allow_any_instance_of(System::Ai::Skills::SkillBindingsReconciler).to receive(:drift).and_return(drift)

      found = signals_of("agent_without_skills")
      expect(found.size).to eq(1)
      expect(found.first.payload["materialization"]).to eq(
        "kind" => "skill_binding",
        "bindings" => [ { "agent_id" => storage.id, "skill_id" => skill.id, "skill_slug" => "system-restore-volume" } ]
      )
    end
  end

  describe "a SIGNAL_BINDINGS lane bound to skill: nil that nothing declares deliberate" do
    before do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.merge(
        "system.probe_lane" => { skill: nil, action_category: "system.probe_investigate" }
      )
      stub_const("System::Fleet::DecisionEngine::SIGNAL_BINDINGS", bindings)
    end

    it "emits exactly one signal for the undeclared lane and none for the declared notify-only lanes" do
      found = signals_of("binding_without_skill")

      expect(found.size).to eq(1)
      expect(found.first.fingerprint).to eq("governance_gap:binding_without_skill:system.probe_lane")
      expect(found.first.payload).to include("subject" => "system.probe_lane",
                                             "action_category" => "system.probe_investigate",
                                             "recommendation_type" => "capability_gap")
    end
  end

  describe "the skill registry" do
    let!(:concierge) { global_agent!(name: "System Concierge", agent_type: "assistant", source_key: "system-concierge", skills: 1) }

    it "reports an executor with no Ai::Skill catalog row, an unknown binds_to target and a missing pair" do
      skill = create(:ai_skill, :global, slug: "system-cve-response")
      drift = System::Ai::Skills::SkillBindingsReconciler::Drift.new(
        missing: [ "System Concierge → system-cve-response" ],
        missing_pairs: [ { "agent_id" => concierge.id, "agent_name" => "System Concierge",
                           "skill_id" => skill.id, "skill_slug" => "system-cve-response" } ],
        stale: [], unknown_agents: [ "Nobody Manager" ], missing_skills: [ "system-probe-executor" ], registry_empty: false
      )
      allow_any_instance_of(System::Ai::Skills::SkillBindingsReconciler).to receive(:drift).and_return(drift)

      by_kind = sensor.sense.group_by { |s| s.payload["gap_kind"] }

      expect(by_kind.fetch("executor_without_skill_row").map(&:fingerprint))
        .to eq([ "governance_gap:executor_without_skill_row:system-probe-executor" ])
      expect(by_kind.fetch("executor_without_skill_row").first.severity).to eq(:high)
      expect(by_kind.fetch("executor_without_skill_row").first.payload["files"])
        .to include(a_string_matching(/system_skills_seed\.rb/))

      expect(by_kind.fetch("binding_agent_unknown").map(&:fingerprint))
        .to eq([ "governance_gap:binding_agent_unknown:Nobody Manager" ])

      missing = by_kind.fetch("skill_binding_missing")
      expect(missing.map(&:fingerprint)).to eq([ "governance_gap:skill_binding_missing:#{concierge.id}:system-cve-response" ])
      expect(missing.first.payload["materialization"]).to eq(
        "kind" => "skill_binding",
        "bindings" => [ { "agent_id" => concierge.id, "skill_id" => skill.id, "skill_slug" => "system-cve-response" } ]
      )
    end
  end

  describe "hierarchy drift (a canonical with no lineage edge or no delegation policy)" do
    let!(:concierge) { global_agent!(name: "System Concierge", agent_type: "assistant", source_key: "system-concierge", skills: 1) }
    let!(:runtime)   { global_agent!(name: "Runtime Manager", agent_type: "monitor", source_key: "runtime-manager", skills: 1) }

    it "emits exactly one edge signal for the unattached child, carrying the attach as its materialisation" do
      found = signals_of("lineage_edge_missing")

      expect(found.size).to eq(1)
      expect(found.first.fingerprint).to eq("governance_gap:lineage_edge_missing:system-concierge/runtime-manager")
      expect(found.first.payload).to include("recommendation_type" => "team_composition")
      expect(found.first.payload["materialization"]).to eq(
        "kind" => "lineage_edge",
        "child_agent_id" => runtime.id, "parent_agent_id" => concierge.id, "agent_key" => "runtime-manager"
      )
    end

    it "emits one delegation signal per agent lacking a policy, carrying the declared delegation as its materialisation" do
      found = signals_of("delegation_policy_missing")

      expect(found.map(&:fingerprint)).to match_array(%w[
        governance_gap:delegation_policy_missing:system-concierge
        governance_gap:delegation_policy_missing:runtime-manager
      ])
      child = found.find { |s| s.payload["subject"] == "runtime-manager" }
      expect(child.payload["materialization"]).to include(
        "kind" => "delegation_policy", "agent_id" => runtime.id,
        "attributes" => hash_including("inheritance_policy" => "conservative", "max_depth" => 2)
      )
    end

    it "clears once the reconciler has written the edge and the policies" do
      System::Governance::HierarchyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

      expect(signals_of("lineage_edge_missing")).to eq([])
      expect(signals_of("delegation_policy_missing")).to eq([])
    end

    # The Engineering root is a CORE canonical whose edge under System Concierge
    # the extension seed writes by hand (HierarchyReconciler leaves its
    # delegation policy to core and does not attach it), so the reconciler's
    # own drift report cannot see this edge — the sensor has to.
    it "reports the Platform Architect's missing edge under System Concierge" do
      architect = global_agent!(name: "Platform Architect", agent_type: "assistant", source_key: "platform-architect",
                                skills: 1, is_governance: true)

      found = signals_of("lineage_edge_missing").select { |s| s.payload["subject"] == "system-concierge/platform-architect" }
      expect(found.size).to eq(1)
      expect(found.first.payload["materialization"]).to eq(
        "kind" => "lineage_edge",
        "child_agent_id" => architect.id, "parent_agent_id" => concierge.id, "agent_key" => "platform-architect"
      )

      Ai::Agents::HierarchyWriter.new(account: account).attach!(child: architect, parent: concierge, spawn_reason: "seed")
      expect(signals_of("lineage_edge_missing").map { |s| s.payload["subject"] }).not_to include("system-concierge/platform-architect")
    end
  end

  describe "a declared category's row on an agent the declarations do not know" do
    it "emits exactly one LOW signal per (category, agent) and leaves the declared owner's rows alone" do
      owner = global_agent!(name: "Fleet Autonomy", agent_type: "monitor", source_key: "fleet-autonomy", skills: 1)
      stray = create(:ai_agent, account: account, name: "Ops Bot", agent_type: "monitor")
      Ai::InterventionPolicy.create!(account: account, scope: "agent", ai_agent_id: owner.id,
                                     action_category: "system.cert_rotate", policy: "auto_approve", priority: 10)
      Ai::InterventionPolicy.create!(account: account, scope: "agent", ai_agent_id: stray.id,
                                     action_category: "system.cert_rotate", policy: "block", priority: 10)

      found = signals_of("policy_owner_undeclared")

      expect(found.size).to eq(1)
      expect(found.first.severity).to eq(:low)
      expect(found.first.fingerprint).to eq("governance_gap:policy_owner_undeclared:system.cert_rotate:#{stray.id}")
      expect(found.first.payload).to include("agent_id" => stray.id, "declared_owner" => "fleet-autonomy")
    end

    # dev.campaign_propose is a CORE category the extension co-declares on the
    # Platform Architect; core's engineering seed writes it on the Platform
    # Developer as well, and that row is core's — never a misplaced copy.
    it "leaves a core static category's row on another core agent alone" do
      developer = create(:ai_agent, account: account, name: "Platform Developer", agent_type: "code_assistant")
      Ai::InterventionPolicy.create!(account: account, scope: "agent", ai_agent_id: developer.id,
                                     action_category: "dev.campaign_propose", policy: "auto_approve", priority: 10)

      expect(signals_of("policy_owner_undeclared")).to eq([])
    end
  end

  describe "a tool_families entry naming nothing the registry serves" do
    it "emits exactly one signal per unknown family" do
      capacity = global_agent!(name: "Capacity Manager", agent_type: "monitor", source_key: "capacity-manager", skills: 1)
      capacity.update!(mcp_metadata: { "tool_access" => { "tool_families" => %w[system_list_instances no_such_family] } })

      found = signals_of("tool_family_unregistered")

      expect(found.size).to eq(1)
      expect(found.first.fingerprint).to eq("governance_gap:tool_family_unregistered:capacity-manager:no_such_family")
      expect(found.first.payload).to include("agent_id" => capacity.id, "family" => "no_such_family")
    end
  end

  describe "fingerprint stability and resilience" do
    before do
      real = Ai::InterventionPolicy.registered_categories
      allow(Ai::InterventionPolicy).to receive(:registered_categories).and_return(real + [ "system.orphan_lane_probe" ])
    end

    it "emits the same fingerprints on consecutive ticks (a standing gap dedups, it does not re-fire)" do
      first = sensor.sense.map(&:fingerprint)
      second = described_class.new(account: account).sense.map(&:fingerprint)

      expect(first).not_to be_empty
      expect(second).to eq(first)
    end

    it "survives one detector raising — the others still report" do
      allow_any_instance_of(System::Governance::HierarchyReconciler).to receive(:drift).and_raise(RuntimeError, "boom")
      allow(Rails.logger).to receive(:warn)

      expect { sensor.sense }.not_to raise_error
      expect(signals_of("category_unowned").size).to eq(1)
      expect(Rails.logger).to have_received(:warn).with(/GovernanceGapSensor.*hierarchy.*boom/).at_least(:once)
    end

    it "caps the pass at max_per_tick, highest severity first" do
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "governance_gap", config: { "max_per_tick" => 1 })
      global_agent!(name: "Storage Manager", agent_type: "monitor", source_key: "storage-manager")

      signals = sensor.sense
      expect(signals.size).to eq(1)
      expect(signals.first.payload["gap_kind"]).to eq("category_unowned")
    end

    # HIER-P3 review — a fingerprint the cap drops is INVISIBLE to
    # RemediationValidator#validate_due!, which reads a due pending outcome's
    # absence from the pass as "the gap cleared" (effective). Its only guard is
    # a CRASHED sensor (F3-11(a)); a truncated pass is not a crash, so the whole
    # VERIFY arm of this lane would silently score a still-standing gap as
    # remediated and fleet.governance_gap_stuck could never fire for it.
    describe "the cap and the validator" do
      let!(:storage) { global_agent!(name: "Storage Manager", agent_type: "monitor", source_key: "storage-manager") }
      let(:low_fingerprint) { "governance_gap:agent_without_skills:storage-manager" }

      before do
        System::Fleet::SensorConfig.upsert_for(account: account, sensor: "governance_gap", config: { "max_per_tick" => 1 })
      end

      it "drops the lower-severity gap while nothing is being scored" do
        expect(sensor.sense.map(&:fingerprint)).not_to include(low_fingerprint)
      end

      it "keeps a fingerprint with a PENDING outcome in the pass, cap or no cap" do
        System::Fleet::RemediationOutcome.create!(
          account: account, signal_kind: described_class::SIGNAL_KIND, fingerprint: low_fingerprint,
          status: "pending", acted_at: 10.minutes.ago, settle_until: 5.minutes.ago
        )

        fingerprints = sensor.sense.map(&:fingerprint)
        expect(fingerprints).to include(low_fingerprint)

        validation = System::Fleet::RemediationValidator.new(account: account)
                                                        .validate_due!(current_signals: sensor.sense, failed_sensors: [])
        expect(validation[:effective]).to eq(0)
        expect(validation[:ineffective]).to eq(1)
      end

      it "rotates the remaining budget so a settled subject does not starve a never-acted one" do
        System::Fleet::RemediationOutcome.create!(
          account: account, signal_kind: described_class::SIGNAL_KIND,
          fingerprint: "governance_gap:category_unowned:system.orphan_lane_probe",
          status: "effective", acted_at: 1.hour.ago, settle_until: 50.minutes.ago, validated_at: 40.minutes.ago
        )
        System::Fleet::SensorConfig.upsert_for(account: account, sensor: "governance_gap", config: { "max_per_tick" => 1 })

        expect(sensor.sense.map(&:fingerprint)).to eq([ low_fingerprint ])
      end
    end
  end
end
