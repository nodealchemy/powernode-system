# frozen_string_literal: true

require "rails_helper"
require File.expand_path("../../../../db/seeds/concerns/agent_setup_helpers.rb", __dir__)

RSpec.describe System::Seeds::AgentSetupHelpers do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }

  def policy!(category)
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: category, policy: "notify_and_proceed", is_active: true
    )
  end

  # Audit F3-10 — Fleet Autonomy is a SHARED agent: sibling seeds attach
  # project.* (system_provisioning_intervention_policies.rb) and
  # system.instance_pool_* (system_instance_pool_policies.rb) policies to it.
  # The unrestricted cleanup destroyed all 12 on any targeted re-run of
  # fleet_autonomy_agent.rb, after which project + pool autonomy gated as
  # blocked "not_permitted".
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

  describe ".clean_stale_policies! namespace ownership (F3-10)" do
    it "destroys only stale policies inside the owned namespace" do
      kept         = policy!("system.cert_rotate")
      stale        = policy!("system.retired_action")
      provisioning = policy!("project.adapt")
      pool         = policy!("system.instance_pool_create")

      destroyed = described_class.clean_stale_policies!(
        account: account, agent: agent,
        keep_keys: [ "system.cert_rotate" ],
        owned_prefixes: [ "system." ],
        excluded_prefixes: [ "system.instance_pool_" ]
      )

      expect(destroyed).to eq(1)
      expect(Ai::InterventionPolicy.exists?(stale.id)).to be false
      expect(Ai::InterventionPolicy.exists?(kept.id)).to be true
      expect(Ai::InterventionPolicy.exists?(provisioning.id)).to be true
      expect(Ai::InterventionPolicy.exists?(pool.id)).to be true
    end

    it "keeps the unrestricted whole-agent cleanup when no ownership is given" do
      stale_foreign = policy!("project.adapt")

      destroyed = described_class.clean_stale_policies!(
        account: account, agent: agent, keep_keys: [ "system.cert_rotate" ]
      )

      expect(destroyed).to eq(1)
      expect(Ai::InterventionPolicy.exists?(stale_foreign.id)).to be false
    end
  end

  # IMP-187124ca2984 — the operator path resolves with agent = nil (gate! passes
  # no `agent:`), which agent-scoped rows can never match. These two helpers own
  # the agent-less mirror of the same per-verb table.
  describe ".upsert_operator_policies! / .clean_stale_operator_policies!" do
    def operator_row(category)
      Ai::InterventionPolicy.find_by(account: account, ai_agent_id: nil,
                                     scope: "action_type", action_category: category)
    end

    it "writes agent-less rows an agent-less caller can match" do
      described_class.upsert_operator_policies!(
        account: account, definitions: { "sdwan.peer_create" => "notify_and_proceed" }
      )

      row = operator_row("sdwan.peer_create")
      expect(row).to be_present
      expect(row.policy).to eq("notify_and_proceed")
      expect(row.send(:agent_matches?, nil)).to be(true),
                                                "an operator request could not match its own policy row"
      # Inert on the operator path (conditions_met? skips the tier check with no
      # agent record) but load-bearing on the agent path, where this same row is
      # a fallback: it must stop matching when the agent-scoped row does, or a
      # trust demotion stops escalating. Pinned end-to-end in
      # spec/db/seeds/system_sdwan_operator_policies_spec.rb.
      expect(row.conditions).to eq({ "trust_tier_minimum" => "monitored" })
    end

    it "is idempotent — a re-run reports no changes" do
      definitions = { "sdwan.peer_create" => "notify_and_proceed" }
      described_class.upsert_operator_policies!(account: account, definitions: definitions)

      expect(described_class.upsert_operator_policies!(account: account, definitions: definitions))
        .to eq(0)
    end

    # The agent-scoped and operator sets are disjoint by construction. Neither
    # cleanup may reach into the other, or a targeted re-run of one seed silently
    # disarms the other audience.
    it "reaps only stale operator rows inside the owned namespace" do
      described_class.upsert_operator_policies!(
        account: account,
        definitions: {
          "sdwan.peer_create"    => "notify_and_proceed",
          "sdwan.retired_action" => "require_approval",
          "system.cert_rotate"   => "notify_and_proceed"
        }
      )
      agent_row = policy!("sdwan.peer_create")

      destroyed = described_class.clean_stale_operator_policies!(
        account: account, keep_keys: [ "sdwan.peer_create" ], owned_prefixes: [ "sdwan." ]
      )

      expect(destroyed).to eq(1)
      expect(operator_row("sdwan.retired_action")).to be_nil
      expect(operator_row("sdwan.peer_create")).to be_present
      expect(operator_row("system.cert_rotate")).to be_present, "reaped outside the owned namespace"
      expect(Ai::InterventionPolicy.exists?(agent_row.id)).to be(true),
                                                              "the operator cleanup destroyed an agent-scoped row"
    end

    it "leaves operator rows alone when the agent-scoped cleanup runs" do
      described_class.upsert_operator_policies!(
        account: account, definitions: { "sdwan.retired_action" => "require_approval" }
      )

      described_class.clean_stale_policies!(
        account: account, agent: agent, keep_keys: [ "sdwan.peer_create" ]
      )

      expect(operator_row("sdwan.retired_action")).to be_present,
                                                      "the agent-scoped cleanup destroyed an operator row"
    end
  end
end
