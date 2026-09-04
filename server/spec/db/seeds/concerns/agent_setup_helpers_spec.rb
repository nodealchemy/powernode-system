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
