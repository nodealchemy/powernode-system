# frozen_string_literal: true

require "rails_helper"

# HIER-P3 — the governance-gap LANE end to end on the fleet tick: the sensor's
# signal routes through DecisionEngine to the Platform Architect's propose
# executor, gated under the Platform Architect (a CORE canonical owning an
# extension-routed category — the first such owner), the offer it files IS the
# remediation the validate arc scores, and a gap that stands N settle windows
# escalates as `fleet.governance_gap_stuck`.
RSpec.describe "fleet governance-gap lane (sense → propose → verify)", type: :service do
  let(:account)  { create(:account) }
  let!(:user)    { create(:user, account: account) }
  let(:provider) { create(:ai_provider, account: account) }
  let(:fleet) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy", source_key: "fleet-autonomy",
                      provider: provider, creator: user)
  end
  let(:architect) do
    create(:ai_agent, account: account, agent_type: "assistant", name: "Platform Architect",
                      source_key: "platform-architect", slug: "platform-architect", is_governance: true,
                      provider: provider, creator: user)
  end
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: fleet) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  def policy!(agent, category, verb)
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: category, policy: verb, priority: 10, is_active: true)
  end

  let(:fingerprint) { "governance_gap:category_unowned:system.orphan_lane" }
  let(:signal) do
    System::Fleet::Signal.new(
      kind: "system.governance_gap", severity: :high, fingerprint: fingerprint,
      payload: {
        "gap_kind" => "category_unowned", "subject" => "system.orphan_lane",
        "recommendation_type" => "capability_gap", "severity" => "high",
        "summary" => "system.orphan_lane is registered but no agent set declares it",
        "files" => [ "extensions/system/server/app/services/system/governance/policy_declarations.rb" ],
        "materialization" => nil, "_sensor" => "GovernanceGapSensor"
      }
    )
  end

  describe "the declaration" do
    let(:binding) { System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.governance_gap") }

    it "routes to the propose executor under dev.campaign_propose, owned by the Platform Architect" do
      expect(binding[:skill]).to eq(System::Ai::Skills::GovernanceGapProposeExecutor)
      expect(binding[:action_category]).to eq("dev.campaign_propose")
      expect(System::Fleet::DecisionEngine.owner_for(binding)).to eq("platform-architect")
      expect(System::Governance::PolicyDeclarations.owner_of("dev.campaign_propose")).to eq("platform-architect")
      expect(binding[:side_effectful]).to be(true)
      expect(binding[:dry_run_supported]).to be(true)
      expect(binding[:stuck_event_kind]).to eq("fleet.governance_gap_stuck")
    end

    it "declares the Platform Architect as a core-canonical identity with the propose and materialise categories" do
      d = System::Governance::PolicyDeclarations
      expect(d::AGENT_IDENTITIES["platform-architect"]).to eq(name: "Platform Architect", agent_type: "assistant")
      expect(d::CORE_CANONICAL_KEYS).to eq(%w[platform-architect])
      expect(d::PLATFORM_ARCHITECT_POLICIES).to eq(
        "dev.campaign_propose" => "auto_approve",
        "dev.governance_materialize" => "require_approval"
      )
      expect(d.owner_of("dev.governance_materialize")).to eq("platform-architect")
      # The core seed writes dev.campaign_propose on the Platform Architect at
      # the same verb; the extension's declaration must never disagree with it.
      core_seed = File.read(Rails.root.join("db/seeds/ai_engineering_agents_seed.rb"))
      expect(core_seed).to match(/"dev\.campaign_propose"\s*=>\s*"auto_approve"/)
      expect(Ai::InterventionPolicy::ENGINEERING_CATEGORIES).to include("dev.campaign_propose")
    end

    it "keeps the Platform Architect OUT of the hierarchy reconciler's attach list (core owns its delegation)" do
      expect(System::Governance::HierarchyReconciler::CHILD_IDENTITIES.keys).not_to include("platform-architect")
      expect(System::Governance::HierarchyReconciler::CHILD_IDENTITIES.size)
        .to eq(System::Governance::PolicyDeclarations::AGENT_IDENTITIES.size - 1)
    end

    it "resolves the Platform Architect through AgentResolver like any declared owner" do
      architect
      expect(System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "platform-architect"))
        .to eq(architect)
    end

    it "scores the propose lane: the offer IS the remediation (an applier, not an exemption)" do
      expect(System::Fleet::DecisionEngine::REMEDIATION_APPLIERS).to have_key("system.governance_gap")
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS).not_to include("system.governance_gap")
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES).not_to include("dev.campaign_propose")
    end
  end

  describe "deciding" do
    before do
      architect
      policy!(architect, "dev.campaign_propose", "auto_approve")
    end

    it "gates under the Platform Architect, files the offer and reports it as the applied remediation" do
      decision = engine.decide(signal)

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:owner]).to eq("platform-architect")
      expect(decision[:agent_id]).to eq(architect.id)
      expect(decision[:skill_result][:success]).to be(true)

      offer = Ai::ImprovementRecommendation.where(account: account).first
      expect(offer).to be_present
      expect(offer.evidence["fingerprint"]).to eq(fingerprint)
      expect(decision[:remediation]).to include(applied: true, offer_id: offer.id)
    end

    it "mints ONE pending outcome for the fingerprint, so the gap's persistence is what gets scored" do
      decision = engine.decide(signal)
      validator = System::Fleet::RemediationValidator.new(account: account, agent: fleet)

      expect { validator.record_proceeded!(decisions: [ decision ], signals: [ signal ]) }
        .to change { System::Fleet::RemediationOutcome.where(account: account, fingerprint: fingerprint).count }.by(1)
      outcome = System::Fleet::RemediationOutcome.where(account: account, fingerprint: fingerprint).first
      expect(outcome.status).to eq("pending")
      expect(outcome.action_category).to eq("dev.campaign_propose")
      expect(outcome.metadata["sensor"]).to eq("GovernanceGapSensor")
    end

    it "blocks LOUDLY as a misconfigured lane when the Platform Architect has no row (never silently)" do
      Ai::InterventionPolicy.where(account: account, action_category: "dev.campaign_propose").delete_all
      allow(Rails.logger).to receive(:error)

      decision = engine.decide(signal)

      expect(decision[:decision]).to eq(:blocked)
      expect(decision[:gate]).to eq(System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)
      expect(Ai::ImprovementRecommendation.where(account: account)).to be_empty
    end

    it "escalates a gap that stood N settle windows as fleet.governance_gap_stuck, forcing an operator decision" do
      count = System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD
      count.times do |i|
        System::Fleet::RemediationOutcome.create!(
          account: account, signal_kind: "system.governance_gap", fingerprint: fingerprint,
          action_category: "dev.campaign_propose", status: "ineffective",
          acted_at: (count - i + 1).hours.ago, settle_until: (count - i).hours.ago, validated_at: (count - i).hours.ago
        )
      end

      decision = nil
      expect { decision = engine.decide(signal) }
        .to change { System::FleetEvent.where(account: account, kind: "fleet.governance_gap_stuck").count }.by(1)
      expect(System::FleetEvent.where(account: account, kind: "fleet.remediation_stuck").count).to eq(0)

      expect(decision[:remediation_stuck]).to be(true)
      expect(decision[:decision]).to eq(:pending)
      expect(decision[:gate]).to eq("require_approval")
      expect(decision[:agent_id]).to eq(architect.id)
      event = System::FleetEvent.where(account: account, kind: "fleet.governance_gap_stuck").last
      expect(event.severity).to eq("high")
      expect(event.payload).to include("fingerprint" => fingerprint, "ineffective_streak" => count)
    end
  end

  # HIER-P3 review — the structural gate this increment exists to enforce is
  # "no governance write without an Ai::InterventionPolicy resolution". That
  # holds only while GapMaterializer#apply! has exactly one door: .execute,
  # which the Ai::AutonomyGate auto-proceed and the approved replay call. A
  # PUBLIC apply! would be a second, ungated door into every write below it.
  describe "System::Governance::GapMaterializer's write path" do
    it "exposes no public writer — apply! is private, reachable only through .execute" do
      expect(System::Governance::GapMaterializer.instance_methods(false)).not_to include(:apply!)
      expect(System::Governance::GapMaterializer.private_instance_methods(false)).to include(:apply!)
      expect(System::Governance::GapMaterializer.public_instance_methods(false).sort).to eq([ :call ])
    end
  end
end
