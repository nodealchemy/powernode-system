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
end
