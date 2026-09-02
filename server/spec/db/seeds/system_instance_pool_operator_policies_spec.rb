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
# INSTANCE_POOL_OPERATOR_POLICIES. The AGENT set keeps all eight — Fleet
# Autonomy's own vocabulary is a separate audience and is not what this task
# found.
#
# WHAT THIS SPEC DOES NOT CLAIM. It does not assert the four ungated verbs
# should stay ungated — that is an operator decision, recorded in
# spec/lint/instance_pool_replenish_gating_spec.rb and in
# System::Executors::InstancePool::ReplenishPool, not derived here. It asserts
# only that a seeded operator row exists exactly where a gate site reads one.
#
# BOTH WRITERS ARE PINNED. The seed is one producer of these rows;
# System::Governance::PolicyReconciler is the other (it creates declared rows
# that an already-booted install is missing, and db:seed runs on first boot
# only). A fix applied to the seed alone would be re-minted by the reconciler
# on the next boot, so both are asserted below.
#
# WHAT NEITHER WRITER DOES IS DELETE. Both examples below assert that the four
# ungated categories are never CREATED at the operator shape; neither asserts
# they are absent from an install that already has them, because the fix cannot
# make that true. db:seed is first-boot only and PolicyReconciler is create-only
# by explicit design, so an already-booted install keeps the four rows its first
# boot wrote. That residue is filed separately as improvement
# 01a063db-c869-7117-b7f6-f88b7061ab4a — see the note on
# PolicyDeclarations::INSTANCE_POOL_OPERATOR_GATED_KEYS for why no existing
# sweep collects this row shape.
RSpec.describe "instance-pool operator-path intervention policies" do
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "pool-admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  # The seed resolves this agent by NAME through Ai::Agent.resolve_for, exactly
  # as the runtime does; without it the agent-scoped half of the seed skips and
  # the audience-separation examples below would be vacuous.
  let!(:fleet_agent) do
    create(:ai_agent, account: account, provider: provider,
           name: "Fleet Autonomy", agent_type: "monitor")
  end

  # The agent-scoped rows carry `trust_tier_minimum: "monitored"`, so without a
  # trust score the agent path falls THROUGH its own row — and, before this
  # fix, landed on the conditionless operator row instead. Scored here so the
  # agent-dispatch example below tests the agent's row rather than the
  # fall-through.
  let!(:fleet_trust) { create(:ai_agent_trust_score, :monitored, account: account, agent: fleet_agent) }

  def load_pool_policy_seed!
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_instance_pool_policies.rb")
    end
  end

  before { load_pool_policy_seed! }

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

  it "seeds an active operator-path row for every gated pool verb" do
    missing = gated_verbs.keys.reject do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, scope: "global",
        action_category: category, is_active: true
      )
    end

    expect(missing).to be_empty,
                       "no operator-path (agent-less) policy seeded for: #{missing.inspect}"
  end

  # The behavioural oracle for the gated half. Every gated pool verb is
  # declared `require_approval`, which is ALSO the absent-row default — so
  # comparing the resolved verb alone cannot tell a seeded row from no row at
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
  it "seeds no operator row for a pool category that has no gate site" do
    leaked = ungated_categories.select do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, scope: "global", action_category: category
      )
    end

    expect(leaked).to be_empty,
                      "operator rows seeded for ungated categories: #{leaked.inspect}"
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

  # The two audiences stay separate. Fleet Autonomy's agent-scoped set keeps
  # ALL EIGHT categories: trimming the operator set must not shrink the agent's
  # own vocabulary, which is a different decision on a different path.
  it "still seeds the Fleet Autonomy agent every declared pool category" do
    declared = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.keys

    seeded = Ai::InterventionPolicy
             .where(account: account, ai_agent_id: fleet_agent.id, scope: "agent")
             .where(action_category: declared)
             .pluck(:action_category)

    expect(seeded).to match_array(declared)
  end

  it "still resolves the agent-dispatch path against Fleet Autonomy's own rows" do
    categories = gated_verbs.keys + ungated_categories

    displaced = categories.reject do |category|
      service.resolve(action_category: category, agent: fleet_agent)[:record]&.ai_agent_id == fleet_agent.id
    end

    expect(displaced).to be_empty,
                         "agent-path resolution lost Fleet Autonomy's row for: #{displaced.inspect}"
  end

  # The OTHER producer. PolicyReconciler creates declared rows an install is
  # missing, so a seed-only fix is undone on the next boot of any install whose
  # first boot predates it.
  describe "System::Governance::PolicyReconciler" do
    it "creates no operator row for an ungated pool category" do
      System::Governance::PolicyReconciler.new(account: account).reconcile!

      leaked = ungated_categories.select do |category|
        Ai::InterventionPolicy.exists?(
          account: account, ai_agent_id: nil, scope: "global", action_category: category
        )
      end

      expect(leaked).to be_empty,
                        "the reconciler re-minted operator rows for: #{leaked.inspect}"
    end

    it "still reconciles the gated pool verbs onto the operator path" do
      Ai::InterventionPolicy.where(account: account, ai_agent_id: nil, scope: "global").destroy_all

      System::Governance::PolicyReconciler.new(account: account).reconcile!

      missing = gated_verbs.keys.reject do |category|
        Ai::InterventionPolicy.exists?(
          account: account, ai_agent_id: nil, scope: "global", action_category: category
        )
      end

      expect(missing).to be_empty, "the reconciler left gated verbs unseeded: #{missing.inspect}"
    end
  end

  it "is idempotent across a re-run" do
    expect { load_pool_policy_seed! }
      .not_to change {
        Ai::InterventionPolicy.where(account: account)
                              .order(:action_category, :ai_agent_id)
                              .pluck(:action_category, :ai_agent_id, :policy)
      }
  end
end
