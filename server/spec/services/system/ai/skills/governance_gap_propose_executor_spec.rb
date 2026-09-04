# frozen_string_literal: true

require "rails_helper"

# HIER-P3 — sense → PROPOSE → materialise. The Platform Architect's executor
# turns one governance-gap signal into ONE reviewable Ai::ImprovementRecommendation
# (the offer IS the human gate; re-detections update it, never a second row)
# and, for a gap the runtime can close, materialises it through the platform's
# own seams under the ruling-3 gates: skill/prompt refinements auto-approve
# from the `trusted` tier (the P2B-ENG pair rows), structural changes park
# whatever the tier (`dev.governance_materialize`, require_approval).
RSpec.describe System::Ai::Skills::GovernanceGapProposeExecutor do
  let(:account)  { create(:account) }
  let!(:user)    { create(:user, account: account) }
  let(:provider) { create(:ai_provider, account: account) }

  # The account's OWN Platform Architect (the shape HIER-P2I's clone seam
  # leaves behind), so nothing here mints a principal.
  let(:architect) do
    create(:ai_agent, account: account, name: "Platform Architect", agent_type: "assistant",
                      source_key: "platform-architect", slug: "platform-architect", is_governance: true,
                      provider: provider, creator: user)
  end

  def policy!(category, verb, priority: 10, conditions: {})
    Ai::InterventionPolicy.create!(account: account, scope: "agent", ai_agent_id: architect.id,
                                   action_category: category, policy: verb, priority: priority,
                                   conditions: conditions, is_active: true)
  end

  # The P2B-ENG refine PAIR: auto_approve conditioned on `trusted` above an
  # unconditioned require_approval — the SAME declaration parks a supervised
  # agent and proceeds for a trusted one.
  def refine_pair!(category)
    policy!(category, "auto_approve", priority: 20, conditions: { "trust_tier_minimum" => "trusted" })
    policy!(category, "require_approval", priority: 10)
  end

  before do
    policy!("dev.campaign_propose", "auto_approve")
    policy!("dev.governance_materialize", "require_approval")
    refine_pair!("dev.skill_refine")
    refine_pair!("dev.prompt_refine")
  end

  let(:executor) { described_class.new(account: account, agent: architect, user: nil) }

  let(:category_gap) do
    {
      "gap_kind" => "category_unowned", "subject" => "system.orphan_lane",
      "recommendation_type" => "capability_gap", "severity" => "high",
      "summary" => "system.orphan_lane is registered but no agent set declares it",
      "files" => [ "extensions/system/server/app/services/system/governance/policy_declarations.rb" ],
      "materialization" => nil
    }
  end

  def offers
    Ai::ImprovementRecommendation.where(account: account)
  end

  describe "the declaration" do
    it "binds to the Platform Architect through the core-canonical alias and gates on dev.campaign_propose" do
      expect(described_class.action_category).to eq("dev.campaign_propose")
      expect(described_class.gate_required?).to be(true)
      registration = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor].name == described_class.name }
      expect(registration[:agents]).to eq([ "Platform Architect" ])
    end
  end

  describe "proposing" do
    it "files exactly one pending offer of the gap's type, fingerprinted on the gap, targeting the account" do
      result = executor.execute(gap: category_gap, fingerprint: "governance_gap:category_unowned:system.orphan_lane")

      expect(result[:success]).to be(true)
      expect(offers.count).to eq(1)
      offer = offers.first
      expect(offer.recommendation_type).to eq("capability_gap")
      expect(offer.status).to eq("pending")
      expect(offer.target_type).to eq("Account")
      expect(offer.target_id).to eq(account.id)
      expect(offer.evidence).to include(
        "fingerprint" => "governance_gap:category_unowned:system.orphan_lane",
        "gap_kind" => "category_unowned",
        "files" => category_gap["files"],
        "proposed_by" => "platform-architect"
      )
      expect(offer.evidence["title"]).to include("system.orphan_lane")
      expect(offer.recommended_config["fix"]).to be_present
      expect(result[:data]).to include(offer_id: offer.id, deduped: false, recommendation_type: "capability_gap")
    end

    it "updates the open offer on a re-detection instead of filing a second one" do
      first = executor.execute(gap: category_gap, fingerprint: "governance_gap:category_unowned:system.orphan_lane")
      second = described_class.new(account: account, agent: architect, user: nil)
                              .execute(gap: category_gap.merge("severity" => "critical"),
                                       fingerprint: "governance_gap:category_unowned:system.orphan_lane")

      expect(offers.count).to eq(1)
      expect(second[:data][:offer_id]).to eq(first[:data][:offer_id])
      expect(second[:data][:deduped]).to be(true)
      expect(offers.first.evidence["detections"]).to eq(2)
      expect(offers.first.evidence["severity"]).to eq("critical")
    end

    it "files a fresh offer once the previous one was dismissed (a dismissed gap that returns is news)" do
      executor.execute(gap: category_gap, fingerprint: "governance_gap:category_unowned:system.orphan_lane")
      offers.first.dismiss!

      described_class.new(account: account, agent: architect, user: nil)
                     .execute(gap: category_gap, fingerprint: "governance_gap:category_unowned:system.orphan_lane")

      expect(offers.count).to eq(2)
      expect(offers.pending.count).to eq(1)
    end

    it "under dry_run reports the plan and files nothing" do
      result = executor.execute(gap: category_gap, fingerprint: "governance_gap:category_unowned:system.orphan_lane",
                                dry_run: true)

      expect(result[:success]).to be(true)
      expect(result[:data][:dry_run]).to be(true)
      expect(result[:data][:recommendation_type]).to eq("capability_gap")
      expect(offers.count).to eq(0)
    end

    it "refuses a gap whose type is not an Ai::ImprovementRecommendation type" do
      result = executor.execute(gap: category_gap.merge("recommendation_type" => "not_a_type"), fingerprint: "fp")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/recommendation_type/)
      expect(offers.count).to eq(0)
    end
  end

  describe "materialising a skill binding (a refinement — ruling 3)" do
    let(:storage) do
      create(:ai_agent, account: nil, name: "Storage Manager", agent_type: "monitor", source_key: "storage-manager",
                        slug: "storage-manager", is_system: true, provider: provider, creator: user)
    end
    let(:skill) { create(:ai_skill, :global, slug: "system-restore-volume") }
    let(:binding_gap) do
      {
        "gap_kind" => "agent_without_skills", "subject" => "storage-manager", "agent_id" => storage.id,
        "recommendation_type" => "skill_creation", "severity" => "medium",
        "summary" => "Storage Manager carries 3 policies and binds no skill",
        "files" => [ "extensions/system/server/app/services/system/ai/skills/skill_bindings.rb" ],
        "materialization" => {
          "kind" => "skill_binding",
          "bindings" => [ { "agent_id" => storage.id, "skill_id" => skill.id, "skill_slug" => "system-restore-volume" } ]
        }
      }
    end
    let(:fingerprint) { "governance_gap:agent_without_skills:storage-manager" }

    context "when the Platform Architect is below the trusted tier" do
      before { create(:ai_agent_trust_score, :monitored, account: account, agent: architect) }

      it "files the offer and PARKS the binding under dev.skill_refine — nothing is written" do
        result = executor.execute(gap: binding_gap, fingerprint: fingerprint)

        expect(result[:success]).to be(true)
        expect(result[:data][:materialization]).to include(status: "pending", action_category: "dev.skill_refine")
        expect(Ai::AgentSkill.where(ai_agent_id: storage.id)).to be_empty

        op = Ai::DeferredOperation.find(result[:data][:materialization][:deferred_operation_id])
        expect(op.status).to eq("pending")
        expect(op.action_category).to eq("dev.skill_refine")
        expect(op.executor_class).to eq("System::Governance::GapMaterializer")
        expect(op.ai_agent_id).to eq(architect.id)
        expect(op.approval_request).to be_present

        offer = offers.first
        expect(offer.status).to eq("pending")
        expect(offer.evidence["materialization"]).to include("status" => "pending", "deferred_operation_id" => op.id)
      end

      it "does not park a second operation while the first is still pending" do
        executor.execute(gap: binding_gap, fingerprint: fingerprint)
        described_class.new(account: account, agent: architect, user: nil).execute(gap: binding_gap, fingerprint: fingerprint)

        expect(Ai::DeferredOperation.where(account: account, action_category: "dev.skill_refine").count).to eq(1)
        expect(offers.count).to eq(1)
      end

      it "applies the parked binding on approval through the replay seam and closes the offer" do
        result = executor.execute(gap: binding_gap, fingerprint: fingerprint)
        op = Ai::DeferredOperation.find(result[:data][:materialization][:deferred_operation_id])

        op.execute_now!

        expect(Ai::AgentSkill.where(ai_agent_id: storage.id, ai_skill_id: skill.id, is_active: true)).to exist
        expect(op.reload.status).to eq("completed")
        expect(offers.first.reload.status).to eq("applied")
      end
    end

    context "when the Platform Architect is trusted" do
      before { create(:ai_agent_trust_score, :trusted, account: account, agent: architect) }

      it "APPLIES the binding, marks the offer applied, and writes the audit row and the fleet event naming the offer" do
        result = executor.execute(gap: binding_gap, fingerprint: fingerprint)

        expect(result[:success]).to be(true)
        expect(result[:data][:materialization]).to include(status: "applied", action_category: "dev.skill_refine")
        expect(Ai::AgentSkill.where(ai_agent_id: storage.id, ai_skill_id: skill.id, is_active: true)).to exist

        offer = offers.first
        expect(offer.status).to eq("applied")
        expect(offer.applied_at).to be_present
        expect(offer.evidence["materialization"]).to include("status" => "applied", "kind" => "skill_binding")

        audit = AuditLog.where(account: account, action: System::Governance::GapMaterializer::AUDIT_ACTION).last
        expect(audit).to be_present
        expect(audit.metadata).to include("offer_id" => offer.id, "kind" => "skill_binding", "fingerprint" => fingerprint)

        event = System::FleetEvent.where(account: account, kind: System::Governance::GapMaterializer::EVENT_KIND).last
        expect(event).to be_present
        expect(event.payload).to include("offer_id" => offer.id, "kind" => "skill_binding", "agent_id" => architect.id)
      end

      it "still PARKS a structural change (a lineage edge) under dev.governance_materialize" do
        concierge = create(:ai_agent, account: nil, name: "System Concierge", agent_type: "assistant",
                                      source_key: "system-concierge", slug: "system-concierge", is_system: true,
                                      provider: provider, creator: user)
        edge_gap = {
          "gap_kind" => "lineage_edge_missing", "subject" => "system-concierge/storage-manager",
          "recommendation_type" => "team_composition", "severity" => "medium",
          "summary" => "Storage Manager has no active lineage edge under System Concierge",
          "files" => [ "extensions/system/server/app/services/system/governance/hierarchy_reconciler.rb" ],
          "materialization" => { "kind" => "lineage_edge", "child_agent_id" => storage.id,
                                 "parent_agent_id" => concierge.id, "agent_key" => "storage-manager" }
        }

        result = executor.execute(gap: edge_gap, fingerprint: "governance_gap:lineage_edge_missing:system-concierge/storage-manager")

        expect(result[:data][:materialization]).to include(status: "pending", action_category: "dev.governance_materialize")
        expect(Ai::AgentLineage.for_child(storage.id).active).to be_empty
        expect(offers.first.status).to eq("pending")

        Ai::DeferredOperation.find(result[:data][:materialization][:deferred_operation_id]).execute_now!
        expect(Ai::AgentLineage.for_child(storage.id).active.pluck(:parent_agent_id)).to eq([ concierge.id ])
        expect(offers.first.reload.status).to eq("applied")
      end

      it "materialises a delegation policy through the hierarchy seam under the structural gate" do
        gap = {
          "gap_kind" => "delegation_policy_missing", "subject" => "storage-manager",
          "recommendation_type" => "team_composition", "severity" => "medium",
          "summary" => "Storage Manager has no delegation policy",
          "files" => [ "extensions/system/server/app/services/system/governance/hierarchy_reconciler.rb" ],
          "materialization" => { "kind" => "delegation_policy", "agent_id" => storage.id,
                                 "attributes" => { "inheritance_policy" => "conservative", "max_depth" => 2,
                                                   "allowed_delegate_types" => [], "allowed_actions" => [] } }
        }
        result = executor.execute(gap: gap, fingerprint: "governance_gap:delegation_policy_missing:storage-manager")
        expect(result[:data][:materialization][:status]).to eq("pending")

        Ai::DeferredOperation.find(result[:data][:materialization][:deferred_operation_id]).execute_now!

        policy = Ai::DelegationPolicy.resolve_for(agent_id: storage.id, account_id: account.id)
        expect(policy).to be_present
        expect(policy.max_depth).to eq(2)
        expect(policy.inheritance_policy).to eq("conservative")
      end

      it "refines a canonical skill's prompt as a new Ai::SkillVersion under dev.prompt_refine" do
        skill.update!(system_prompt: "Restore a volume from its latest snapshot.")
        gap = {
          "gap_kind" => "prompt_refinement", "subject" => "system-restore-volume",
          "recommendation_type" => "prompt_refinement", "severity" => "low",
          "summary" => "system-restore-volume's prompt does not name the data-loss gate",
          "files" => [],
          "materialization" => { "kind" => "prompt_refinement", "skill_id" => skill.id,
                                 "system_prompt" => "Restore a volume from its latest snapshot; refuse when replication lag exceeds the promote gate.",
                                 "reason" => "name the data-loss gate" }
        }

        result = executor.execute(gap: gap, fingerprint: "governance_gap:prompt_refinement:system-restore-volume")

        expect(result[:data][:materialization]).to include(status: "applied", action_category: "dev.prompt_refine")
        version = Ai::SkillVersion.where(ai_skill_id: skill.id).active.first
        expect(version).to be_present
        expect(version.system_prompt).to include("refuse when replication lag")
        expect(version.created_by_agent_id).to eq(architect.id)
        expect(version.metadata["previous_system_prompt"]).to eq("Restore a volume from its latest snapshot.")
        expect(skill.reload.system_prompt).to include("refuse when replication lag")
        expect(offers.first.status).to eq("applied")
      end
    end

    context "when the account has no policy row at all for the refine category" do
      before do
        Ai::InterventionPolicy.where(account: account, action_category: "dev.skill_refine").delete_all
        create(:ai_agent_trust_score, :trusted, account: account, agent: architect)
      end

      it "meets the unmatched default and parks (fail-safe)" do
        result = executor.execute(gap: binding_gap, fingerprint: fingerprint)

        expect(result[:data][:materialization][:status]).to eq("pending")
        expect(Ai::AgentSkill.where(ai_agent_id: storage.id)).to be_empty
      end
    end

    # IMP-a51963f8717f (proposal §5 ruling 11c) WIDENED this lane, and the
    # widening is the point of this context rather than an aside.
    #
    # Ai::Engineering::ReleaseDispatchFloorSeeder writes a scope-"global"
    # auto_approve FLOOR for dev.skill_refine / dev.prompt_refine on EVERY
    # account (core's db/seeds/ai_engineering_agents_seed.rb calls `ensure_all!`,
    # and so does every boot reconcile door). The trust-conditioned PAIR that
    # would outrank it is written only on the "Powernode Admin" account's
    # canonicals. So on ANY other account the acting Platform Architect — the
    # per-account clone HIER-P2I's AgentResolver mints — owns no refine row, and
    # Ai::InterventionPolicyService#resolve admits scope-"global" rows for an
    # agent caller. The floor is then what decides, at EVERY trust tier.
    #
    # The context above stays true only because it deletes the floor too. Both
    # are real states: the floor's absence parks, its presence applies.
    context "when the account carries the account-wide refine floor and the architect owns no refine row" do
      before do
        Ai::InterventionPolicy
          .where(account: account, action_category: %w[dev.skill_refine dev.prompt_refine])
          .delete_all
        Ai::Engineering::ReleaseDispatchFloorSeeder.ensure_for!(account)
      end

      it "APPLIES the binding at the SUPERVISED tier — the floor decides, not the trust pair" do
        expect(Ai::AgentTrustScore.find_by(agent_id: architect.id)).to be_nil # supervised by default

        result = executor.execute(gap: binding_gap, fingerprint: fingerprint)

        expect(result[:data][:materialization]).to include(status: "applied", action_category: "dev.skill_refine")
        expect(Ai::AgentSkill.where(ai_agent_id: storage.id, ai_skill_id: skill.id, is_active: true)).to exist
        expect(offers.first.status).to eq("applied")

        # The floor is what matched: scope "global", agent-less, auto_approve.
        floor = Ai::Engineering::ReleaseDispatchFloorSeeder.find_for(account, "dev.skill_refine")
        expect(floor).to have_attributes(scope: "global", ai_agent_id: nil, policy: "auto_approve")
      end

      it "still PARKS a structural change — no floor covers dev.governance_materialize" do
        concierge = create(:ai_agent, account: nil, name: "System Concierge", agent_type: "assistant",
                                      source_key: "system-concierge", slug: "system-concierge", is_system: true,
                                      provider: provider, creator: user)
        edge_gap = {
          "gap_kind" => "lineage_edge_missing", "subject" => "system-concierge/storage-manager",
          "recommendation_type" => "team_composition", "severity" => "medium",
          "summary" => "Storage Manager has no active lineage edge under System Concierge",
          "files" => [],
          "materialization" => { "kind" => "lineage_edge", "child_agent_id" => storage.id,
                                 "parent_agent_id" => concierge.id, "agent_key" => "storage-manager" }
        }

        result = executor.execute(gap: edge_gap,
                                  fingerprint: "governance_gap:lineage_edge_missing:system-concierge/storage-manager")

        expect(result[:data][:materialization]).to include(status: "pending",
                                                           action_category: "dev.governance_materialize")
        expect(Ai::AgentLineage.for_child(storage.id).active).to be_empty
      end
    end
  end
end
