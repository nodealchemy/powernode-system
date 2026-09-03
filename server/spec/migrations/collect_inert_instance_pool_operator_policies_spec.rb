# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260903033000_collect_inert_instance_pool_operator_policies.rb"
)

# IMP-57a4b1ef94b3 — the half IMP-5a2b801f3386 could not reach.
#
# Trimming POLICY_SETS "instance-pool-operator" to the four gated verbs stops
# the operator-path rows for `_acquire` / `_drain` / `_replenish` / `_update`
# being CREATED. It does nothing about the rows every already-booted install
# has: db:seed runs on first boot only, PolicyReconciler is create-only by
# explicit design, AgentSetupHelpers.clean_stale_operator_policies! keys on
# scope "action_type" (these are scope "global"), and the orphan-cleanup seed
# collects only DEREGISTERED categories — all eight stay registered via the
# agent set. So the disposition is a bounded one-shot SWEEP, and the sweep is
# this migration — which is what an operator's install actually executes.
#
# THE PREDICATE IS THE OPERATOR RULING (R2, 2026-09-03), restated here so a
# silent widening reds this file: scope "global", ai_agent_id nil, one of the
# four ungated categories, AND the verb still equal to the seeded default. A
# row an operator retuned is kept — and said — even though it is just as
# inert, because "still at the seeded verb" is the only evidence available
# that nobody ever meant it.
#
# Rows are written through the migration's OWN local model rather than
# Ai::InterventionPolicy, for the same reason the migration declares one: a
# migration that survives its app model's validations drifting must be tested
# against the table, not against today's model.
RSpec.describe CollectInertInstancePoolOperatorPolicies do
  subject(:migration) { described_class.new }

  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  # The seeded default for each of the four, restated independently of both
  # the migration's constant and PolicyDeclarations::INSTANCE_POOL_POLICIES so
  # a drift in either shows up as a failing expectation, not as a change in
  # what an install loses.
  let(:seeded_verbs) do
    {
      "system.instance_pool_acquire"   => "auto_approve",
      "system.instance_pool_drain"     => "require_approval",
      "system.instance_pool_replenish" => "auto_approve",
      "system.instance_pool_update"    => "notify_and_proceed"
    }
  end

  def policy(category, verb:, account_row: account, scope: "global", agent_id: nil,
             user_id: nil, active: true)
    described_class::PolicyRow.create!(
      account_id: account_row.id, action_category: category, policy: verb,
      scope: scope, ai_agent_id: agent_id, user_id: user_id,
      priority: 5, is_active: active, conditions: {}, preferred_channels: %w[notification]
    )
  end

  def seed_all_four(account_row: account)
    seeded_verbs.map { |category, verb| policy(category, verb: verb, account_row: account_row) }
  end

  # `say` writes through Migration#write, which puts to $stdout when verbose.
  def run_up
    migration.verbose = true
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    begin
      migration.up
    ensure
      $stdout = original
    end
    captured.string
  end

  it "pins the seeded default it collects against, verb by verb" do
    expect(described_class::INERT_OPERATOR_CATEGORIES).to eq(seeded_verbs)
  end

  describe "#up" do
    it "collects every seeded-verb row at the operator shape, across ALL accounts" do
      mine   = seed_all_four
      theirs = seed_all_four(account_row: other_account)

      expect { run_up }.to change { described_class::PolicyRow.count }.by(-8)

      expect(described_class::PolicyRow.where(id: (mine + theirs).map(&:id))).to be_empty
    end

    # The ruling's boundary: a retuned verb is the one signal that an operator
    # meant the row, so it stays — and the migration says so rather than
    # deleting around it silently.
    it "keeps a row whose verb an operator has retuned, and says why" do
      tuned = policy("system.instance_pool_drain", verb: "auto_approve")
      policy("system.instance_pool_acquire", verb: "auto_approve")

      output = run_up

      expect(tuned.reload.policy).to eq("auto_approve")
      expect(output).to include("KEEPING system.instance_pool_drain")
      expect(output).to include('policy="auto_approve"')
      expect(output).to include('seeded "require_approval"')
      expect(output).to include("no gate site reads it")
    end

    it "leaves the Fleet Autonomy agent-scoped rows for the same categories alone" do
      provider = create(:ai_provider, account: account, provider_type: "anthropic", is_active: true)
      agent = create(:ai_agent, account: account, provider: provider,
                     name: "Fleet Autonomy", agent_type: "monitor")
      agent_rows = seeded_verbs.map do |category, verb|
        policy(category, verb: verb, scope: "agent", agent_id: agent.id)
      end
      seed_all_four

      run_up

      expect(described_class::PolicyRow.where(id: agent_rows.map(&:id)).count).to eq(4)
    end

    # The `ai_agent_id: nil` clause needs its OWN oracle: the agent-scoped
    # example above is already excluded by `scope`, so it cannot tell that
    # clause from a missing one. This row is at the operator SCOPE and a
    # seeded verb, and is spared only because it carries an agent.
    it "leaves an agent-bound row at scope global alone: the agent clause, on its own" do
      provider = create(:ai_provider, account: account, provider_type: "anthropic", is_active: true)
      agent = create(:ai_agent, account: account, provider: provider,
                     name: "Fleet Autonomy", agent_type: "monitor")
      global_agent_row = policy("system.instance_pool_acquire", verb: "auto_approve",
                                scope: "global", agent_id: agent.id)

      run_up

      expect(global_agent_row.reload).to be_present
    end

    it "leaves the four GATED operator verbs alone" do
      gated = %w[
        system.instance_pool_create
        system.instance_pool_delete
        system.instance_pool_ceiling_raise
        system.instance_pool_archive
      ].map { |category| policy(category, verb: "require_approval") }
      seed_all_four

      run_up

      expect(described_class::PolicyRow.where(id: gated.map(&:id)).count).to eq(4)
    end

    it "leaves a user-bound row alone: no seed ever wrote one" do
      user = create(:user, account: account)
      user_bound = policy("system.instance_pool_update", verb: "notify_and_proceed",
                          user_id: user.id)

      run_up

      expect(user_bound.reload).to be_present
    end

    it "leaves unrelated categories alone" do
      bystander = policy("system.package_module_create", verb: "require_approval")
      seed_all_four

      run_up

      expect(bystander.reload).to be_present
    end

    # A hand-deactivated seeded row is "harmless and equally inert" (the
    # IMP-5a2b801f3386 note); its verb is still the seeded one, so it goes too,
    # and the record says it was inactive.
    it "collects a deactivated row still at its seeded verb, and records that it was inactive" do
      policy("system.instance_pool_replenish", verb: "auto_approve", active: false)

      output = run_up

      expect(described_class::PolicyRow.where(action_category: "system.instance_pool_replenish")).to be_empty
      expect(output).to include("is_active=false")
    end

    it "records every row it collects — category, account, scope, verb — before deleting" do
      seed_all_four

      output = run_up

      seeded_verbs.each do |category, verb|
        expect(output).to include("collecting #{category}")
        expect(output).to include("policy=#{verb.inspect}")
      end
      expect(output).to include("account_id=#{account.id.inspect}")
      expect(output).to include('scope="global"')
      expect(output).to include("Collected 4 inert instance-pool operator policy row(s)")
    end

    it "is a no-op on a second run" do
      seed_all_four
      run_up

      expect { expect(run_up).to include("No inert instance-pool operator policy rows to collect") }
        .not_to change { described_class::PolicyRow.count }
    end
  end

  describe "#down" do
    it "refuses: it cannot know which rows an install had, and restoring them would re-render inert controls" do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
