# frozen_string_literal: true

require "rails_helper"

# IMP-5a2b801f3386 — operator-path rows for the instance-pool categories that
# are ACTUALLY gated, and for no others.
#
# THE FINDING. POLICY_SETS "instance-pool-operator" (agent_key nil, scope
# "global") seeded EVERY declared instance-pool category onto the operator
# path, while only four of them are passed by a gate site:
# `system.instance_pool_create` and `_delete` (InstancePoolsController#create /
# #destroy) and `_ceiling_raise` / `_archive` (#update's GATED_UPDATE_CATEGORIES,
# IMP-24daa05e7a22). The other four — `_acquire`, `_drain`, `_replenish`,
# `_update` — rendered in the Autonomy modal as controls an operator can edit
# that no code path reads. `_drain` was the sharpest case: declared
# `require_approval`, so the operator was shown an approval requirement that
# nothing enforces.
#
# That is exactly the defect RUNTIME_OPERATOR_GATED_KEYS was introduced to
# prevent (IMP-9b9653e6514e; its mirror is
# spec/db/seeds/system_runtime_operator_policies_spec.rb) and the same ruling
# is applied here: the OPERATOR set is the gated subset,
# INSTANCE_POOL_OPERATOR_POLICIES. The AGENT set keeps all eight on the
# Capacity Manager (CAPACITY_MANAGER_POLICIES) — a separate audience.
#
# WHAT THIS SPEC DOES NOT CLAIM. It does not assert the four ungated verbs
# should stay ungated — that is an operator decision, recorded in
# spec/lint/instance_pool_replenish_gating_spec.rb and in
# System::Executors::InstancePool::ReplenishPool, not derived here. It asserts
# only that a written operator row exists exactly where a gate site reads one.
#
# ONE WRITER (proposal §5 ruling 7, IMP-10e4f6c3bcd2). The first-boot seed
# that used to write both audiences (system_instance_pool_policies.rb) is
# gone; System::Governance::PolicyReconciler writes the operator set from the
# `instance-pool-operator` POLICY_SETS entry and the agent set from the
# `capacity-manager` entry — on every boot, the first one included, and via
# `rails system:governance:reconcile`. There is no second writer left to
# re-mint a trimmed row, and no seed that could leave a duplicate on the
# former owner after the owner's own rows exist.
#
# WHAT THE WRITER DOES NOT DO IS DELETE. The examples below assert that the
# four ungated categories are never CREATED at the operator shape; none
# asserts they are absent from an install that already has them, because
# PolicyReconciler is create-only by explicit design, so an already-booted
# install kept the four rows its first boot wrote until the one-shot
# collection landed: db/migrate/20260903033000_collect_inert_instance_pool_
# operator_policies.rb (IMP-57a4b1ef94b3) deletes them once on the next deploy
# migrate — see the note on PolicyDeclarations::INSTANCE_POOL_OPERATOR_GATED_KEYS
# for why no RECURRING sweep collects this row shape.
RSpec.describe "instance-pool operator-path intervention policies" do
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "pool-admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  # The reconciler resolves this agent through System::Governance::AgentResolver
  # — the account's own row wins over a canonical — so an ACCOUNT-scoped agent
  # of the declared identity is where the agent set lands. The name is read
  # from AGENT_IDENTITIES rather than written out, so this file follows a
  # rename of the owner instead of silently going vacuous.
  let(:owner_identity) do
    System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("capacity-manager")
  end

  let!(:owner_agent) do
    create(:ai_agent, account: account, provider: provider,
           name: owner_identity[:name], agent_type: owner_identity[:agent_type])
  end

  # Fleet Autonomy is the FORMER owner. Kept present, and asserted EMPTY below:
  # a writer that puts the agent set onto it leaves rows the reconciler can
  # never re-home once the owner has its own, so "no row here" is the
  # assertion, not an absence of setup.
  let!(:fleet_agent) do
    create(:ai_agent, account: account, provider: provider,
           name: "Fleet Autonomy", agent_type: "monitor")
  end

  # The agent-scoped rows carry `trust_tier_minimum: "monitored"`, so without a
  # trust score the agent path falls THROUGH its own row — and, before this
  # fix, landed on the conditionless operator row instead. Scored here so the
  # agent-dispatch example below tests the agent's row rather than the
  # fall-through.
  let!(:owner_trust) { create(:ai_agent_trust_score, :monitored, account: account, agent: owner_agent) }

  def reconcile!
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
  end

  before { reconcile! }

  let(:service) { Ai::InterventionPolicyService.new(account: account) }

  # Restated independently of the declaration so a silent edit to either side
  # shows up as a failing expectation rather than as a change in what an
  # operator gets. These are the four categories an InstancePoolsController
  # gate site passes to Ai::GatedActions.
  let(:gated_verbs) do
    {
      "system.instance_pool_create"        => "require_approval",
      "system.instance_pool_delete"        => "require_approval",
      "system.instance_pool_ceiling_raise" => "require_approval",
      "system.instance_pool_archive"       => "require_approval"
    }
  end

  # The declared categories with no gate site. Named here rather than derived
  # by subtraction so that gating one of them reds this file and forces the
  # census in spec/lint/instance_pool_replenish_gating_spec.rb to be revisited
  # in the same change.
  let(:ungated_categories) do
    %w[
      system.instance_pool_acquire
      system.instance_pool_drain
      system.instance_pool_replenish
      system.instance_pool_update
    ]
  end

  it "writes an active operator-path row for every gated pool verb" do
    missing = gated_verbs.keys.reject do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, scope: "global",
        action_category: category, is_active: true
      )
    end

    expect(missing).to be_empty,
                       "no operator-path (agent-less) policy written for: #{missing.inspect}"
  end

  # The behavioural oracle for the gated half. Every gated pool verb is
  # declared `require_approval`, which is ALSO the absent-row default — so
  # comparing the resolved verb alone cannot tell a written row from no row at
  # all. The discriminating assertion is that a RECORD backs the answer.
  it "resolves every gated verb to its recorded row for an agent-less caller" do
    gated_verbs.each do |category, verb|
      result = service.resolve(action_category: category, agent: nil)

      expect(result[:policy]).to eq(verb), "#{category} resolved to #{result[:policy]}"
      expect(result[:record]).not_to be_nil, "#{category} resolved with no operator row behind it"
    end
  end

  # The inverse enumeration, and the guard against the tempting over-fix: an
  # ungated category must NOT gain an operator row, because the row renders as
  # a working control and is read by nothing.
  it "writes no operator row for a pool category that has no gate site" do
    leaked = ungated_categories.select do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, scope: "global", action_category: category
      )
    end

    expect(leaked).to be_empty,
                      "operator rows written for ungated categories: #{leaked.inspect}"
  end

  # ...and those categories resolve to the default on the operator path, which
  # is the honest answer for an action no gate consults. `_replenish` and
  # `_acquire` are declared auto_approve and `_update` notify_and_proceed, so
  # this example fails loudly if a row leaks: the verb changes, not just the
  # record.
  it "leaves the ungated pool categories on the require_approval default" do
    ungated_categories.each do |category|
      result = service.resolve(action_category: category, agent: nil)

      expect(result[:policy]).to eq("require_approval"), "#{category} resolved to #{result[:policy]}"
      expect(result[:record]).to be_nil, "an operator policy leaked onto ungated #{category}"
    end
  end

  # The two audiences stay separate. The OWNING agent's set keeps ALL EIGHT
  # categories: trimming the operator set must not shrink the agent's own
  # vocabulary, which is a different decision on a different path.
  it "still writes the owning agent every declared pool category" do
    declared = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.keys

    written = Ai::InterventionPolicy
              .where(account: account, ai_agent_id: owner_agent.id, scope: "agent")
              .where(action_category: declared)
              .pluck(:action_category)

    expect(written).to match_array(declared)
  end

  it "still resolves the agent-dispatch path against the owning agent's own rows" do
    categories = gated_verbs.keys + ungated_categories

    displaced = categories.reject do |category|
      service.resolve(action_category: category, agent: owner_agent)[:record]&.ai_agent_id == owner_agent.id
    end

    expect(displaced).to be_empty,
                         "agent-path resolution lost #{owner_identity[:name]}'s row for: #{displaced.inspect}"
  end

  # HIER-P2B — the agent set lands on the DECLARED OWNER and nowhere else. A
  # row on the former owner would be an active control the gate never reads,
  # permanently: `reconcile!` answers `present` and never consults
  # `rehomable_row` for a category the owner already has.
  it "writes no agent-scoped pool row onto the former owner" do
    declared = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.keys

    orphaned = Ai::InterventionPolicy
               .where(account: account, ai_agent_id: fleet_agent.id, scope: "agent")
               .where(action_category: declared)
               .pluck(:action_category)

    expect(orphaned).to be_empty,
                        "pool rows written onto Fleet Autonomy, which no longer declares them: #{orphaned.inspect}"
  end

  # And the declaration really does name the Capacity Manager, so the assertion
  # above cannot be satisfied by pointing the writer at any agent at all.
  it "derives the Capacity Manager as the declared owner of every pool category" do
    System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.each_key do |category|
      expect(System::Governance::PolicyDeclarations.owner_of(category)).to eq("capacity-manager"),
        "#{category} is declared on #{System::Governance::PolicyDeclarations.owner_of(category).inspect}"
    end
  end

  it "still reconciles the gated pool verbs onto the operator path after they are removed" do
    Ai::InterventionPolicy.where(account: account, ai_agent_id: nil, scope: "global").destroy_all

    reconcile!

    missing = gated_verbs.keys.reject do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, scope: "global", action_category: category
      )
    end

    expect(missing).to be_empty, "the reconciler left gated verbs unwritten: #{missing.inspect}"
  end

  it "is idempotent across a second pass" do
    expect { reconcile! }
      .not_to change {
        Ai::InterventionPolicy.where(account: account)
                              .order(:action_category, :ai_agent_id)
                              .pluck(:action_category, :ai_agent_id, :policy)
      }
  end
end
