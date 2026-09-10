# frozen_string_literal: true

require "rails_helper"
require File.expand_path("../../../../db/seeds/concerns/agent_setup_helpers.rb", __dir__)

RSpec.describe System::Seeds::AgentSetupHelpers do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }

  # The policy upserts and their stale-row sweeps (`upsert_policies!`,
  # `upsert_operator_policies!`, `clean_stale_policies!`,
  # `clean_stale_operator_policies!`) are GONE (proposal §5 ruling 7,
  # IMP-10e4f6c3bcd2): PolicyReconciler is the single writer of declared rows
  # and no seed writes one — spec/db/seeds/policy_single_writer_spec pins it.
  it "no longer offers a policy-row writer or a shape-keyed sweep" do
    expect(described_class).not_to respond_to(:upsert_policies!, :upsert_operator_policies!,
                                               :clean_stale_policies!, :clean_stale_operator_policies!)
    expect(described_class.const_defined?(:DEFAULT_TRUST_CONDITIONS)).to be false
  end

  # HIER-P1 canonical rule: a seed never adopts a stray account-scoped agent.
  # IMP-01a06b99. bootstrap_admin_context! raised on a missing account, user or
  # provider, so on a fresh install with no accounts the 13 canonical
  # system-agent seeds wrote NOTHING — not even the global agent DEFINITION,
  # which needs none of the three. The roster came up short and
  # Ai::ClaudeExport::AgentSkeletonSync had no canonical rows to export.
  #
  # Core settled the same question for its own agents in IMP-6cda93db7f31
  # (ai_utility_agents_seed.rb:6-11): write the global row with a nil creator
  # and provider, skip the account-keyed extras until setup completes. These
  # examples carry that decision into the extension.
  describe "a fresh install with no Account" do
    before do
      allow(Account).to receive(:find_by).and_call_original
      allow(Account).to receive(:find_by).with(name: "Powernode Admin").and_return(nil)
      allow(Account).to receive(:first).and_return(nil)
    end

    it "returns a context instead of raising" do
      expect { described_class.bootstrap_admin_context! }.not_to raise_error
    end

    # Per-key nils, not a bare nil context: a seed reading ctx[:creator] must
    # get nil (which Ai::Agent#creator accepts), not a NoMethodError.
    it "answers nil for each key rather than a nil context" do
      ctx = described_class.bootstrap_admin_context!

      expect(ctx).to be_a(Hash)
      expect(ctx[:account]).to be_nil
      expect(ctx[:creator]).to be_nil
    end

    it "does not raise merely because no provider exists either" do
      allow(::Ai::Provider).to receive(:where).and_return(::Ai::Provider.none)
      allow(::Ai::Provider).to receive(:first).and_return(nil)

      ctx = described_class.bootstrap_admin_context!

      expect(ctx[:provider]).to be_nil
    end
  end

  # The two per-ACCOUNT writers. Both models belongs_to :account with no
  # `optional: true`, so a nil account raises on save — and the global agent
  # definition they accompany is valid without either.
  describe "the per-account writers on a nil account" do
    it "writes no trust score" do
      expect {
        expect(described_class.ensure_trust_score!(
                 account: nil, agent: agent, tier: "monitored", overall: 0.7
               )).to be_nil
      }.not_to change(::Ai::AgentTrustScore, :count)
    end

    it "writes no approval chain" do
      expect {
        expect(described_class.ensure_approval_chain!(
                 account: nil, name: "Fleet Autonomy Actions", label: "Fleet Autonomy",
                 timeout_hours: 4, steps: [ { "name" => "x", "approvers" => [], "required_approvals" => 1 } ]
               )).to be_nil
      }.not_to change(::Ai::ApprovalChain, :count)
    end
  end

  describe ".ensure_approval_chain!" do
    let(:steps) do
      [ { "name" => "Operator Approval",
          "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
          "required_approvals" => 1 } ]
    end

    def upsert(timeout_hours: 4)
      described_class.ensure_approval_chain!(
        account: account, name: "Fleet Autonomy Actions", label: "Fleet Autonomy",
        timeout_hours: timeout_hours, steps: steps
      )
    end

    # The shared defaults the 11 inline blocks each carried verbatim. Pinned
    # because extracting them is only safe if they are actually identical to
    # what every seed wrote.
    it "writes the chain with the defaults every seed had copied" do
      chain = upsert

      expect(chain).to be_persisted
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.status).to eq("active")
      expect(chain.is_sequential).to be true
      expect(chain.timeout_action).to eq("reject")
      expect(chain.timeout_hours).to eq(4)
      expect(chain.steps).to eq(steps)
    end

    it "is idempotent — a second run creates no second row" do
      upsert
      expect { upsert }.not_to change(::Ai::ApprovalChain, :count)
    end

    it "updates an existing row in place when a value changes" do
      chain = upsert
      expect { upsert(timeout_hours: 12) }.not_to change(::Ai::ApprovalChain, :count)
      expect(chain.reload.timeout_hours).to eq(12)
    end
  end

  describe ".find_or_initialize_global_agent" do
    it "returns the existing GLOBAL row" do
      global = create(:ai_agent, account: nil, name: "Fleet Autonomy", agent_type: "monitor",
                                 is_system: true, source_key: "fleet-autonomy",
                                 creator: create(:user, account: account))

      found = described_class.find_or_initialize_global_agent(
        name: "Fleet Autonomy", agent_type: "monitor", source_key: "fleet-autonomy"
      )
      expect(found).to eq(global)
      expect(found.account_id).to be_nil
    end

    it "initializes a new GLOBAL row when nothing of that name exists" do
      built = described_class.find_or_initialize_global_agent(
        name: "Fleet Autonomy", agent_type: "monitor", source_key: "fleet-autonomy"
      )
      expect(built).to be_new_record
      expect(built.account_id).to be_nil
      expect(built.is_system).to be true
      expect(built.source_key).to eq("fleet-autonomy")
    end

    it "raises a conflict naming the ACCOUNT row instead of adopting it as the canonical" do
      stray = agent # account-scoped "Fleet Autonomy" (monitor)

      expect {
        described_class.find_or_initialize_global_agent(
          name: "Fleet Autonomy", agent_type: "monitor", source_key: "fleet-autonomy"
        )
      }.to raise_error(described_class::CanonicalAgentConflict) { |e|
        expect(e.message).to include(stray.id)
        expect(e.message).to include(account.id)
        expect(e.message).to include("fleet-autonomy")
      }

      expect(stray.reload.account_id).to eq(account.id)
      expect(Ai::Agent.global.where(name: "Fleet Autonomy")).to be_empty
    end

    it "leaves an account row alone once the global canonical exists (it is the override shape)" do
      global = create(:ai_agent, account: nil, name: "Fleet Autonomy", agent_type: "monitor",
                                 is_system: true, source_key: "fleet-autonomy",
                                 creator: create(:user, account: account))
      override = agent

      found = described_class.find_or_initialize_global_agent(
        name: "Fleet Autonomy", agent_type: "monitor", source_key: "fleet-autonomy"
      )
      expect(found).to eq(global)
      expect(override.reload.account_id).to eq(account.id)
    end
  end
end
