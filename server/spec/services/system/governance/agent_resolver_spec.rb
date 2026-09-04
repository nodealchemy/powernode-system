# frozen_string_literal: true

require "rails_helper"

# HIER-P2I — the fleet agents are seeded as GLOBAL canonicals, and a canonical
# never executes (proposal §5 ruling 8: Ai::Tools::BaseTool refuses a NULL-
# account principal). AgentResolver is the ONE rule both the reconciler (writer)
# and the tick (reader) resolve through, so it is where "which row acts for
# <agent_key> on this account" must answer with the account's CLONE — minted
# lazily on first use through Ai::Agents::AccountPrincipalResolver, with the
# account's policy rows re-homed onto it so the first tick still acts.
RSpec.describe System::Governance::AgentResolver do
  let(:seeding_account) { create(:account, name: "Powernode Admin") }
  let(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  def global!(name:, source_key:, agent_type: "monitor")
    create(:ai_agent, :global, owner_account: seeding_account, name: name, source_key: source_key,
                               agent_type: agent_type, is_system: true)
  end

  describe ".resolve with only the GLOBAL canonical present" do
    it "returns the account's clone — an account-scoped principal — not the canonical" do
      canonical = global!(name: "Fleet Autonomy", source_key: "fleet-autonomy")

      resolved = described_class.resolve(account_id: account.id, agent_key: "fleet-autonomy")

      expect(resolved).to be_present
      expect(resolved.id).not_to eq(canonical.id)
      expect(resolved.global?).to be(false)
      expect(resolved.account_id).to eq(account.id)
      expect(resolved.cloned_from_id).to eq(canonical.id)
    end

    it "resolves the same clone on every call and mints once" do
      global!(name: "SDWAN Manager", source_key: "sdwan-manager")
      first = described_class.resolve(account_id: account.id, agent_key: "sdwan-manager")

      expect { described_class.resolve(account_id: account.id, agent_key: "sdwan-manager") }
        .not_to change(Ai::Agent, :count)
      expect(described_class.resolve(account_id: account.id, agent_key: "sdwan-manager").id).to eq(first.id)
    end

    it "re-homes the account's rows written against the canonical onto the clone, so the gate reads them" do
      canonical = global!(name: "Fleet Autonomy", source_key: "fleet-autonomy")
      row = Ai::InterventionPolicy.create!(account: account, ai_agent_id: canonical.id, scope: "agent",
                                           action_category: "system.cert_rotate", policy: "auto_approve",
                                           priority: 10, is_active: true)

      clone = described_class.resolve(account_id: account.id, agent_key: "fleet-autonomy")

      expect(row.reload.ai_agent_id).to eq(clone.id)
      expect(System::Fleet::FleetAutonomyService.new(account: account, agent: clone).permitted_actions)
        .to include("system.cert_rotate")
    end

    it "resolves a key with no AGENT_IDENTITIES entry by source_key and still clones" do
      canonical = global!(name: "Custom Twin", source_key: "custom-twin", agent_type: "assistant")

      resolved = described_class.resolve(account_id: account.id, agent_key: "custom-twin")

      expect(resolved.cloned_from_id).to eq(canonical.id)
      expect(resolved.account_id).to eq(account.id)
    end
  end

  describe ".resolve with an account row" do
    it "still prefers the account's own override and mints nothing" do
      global!(name: "Fleet Autonomy", source_key: "fleet-autonomy")
      override = create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy", creator: user)

      expect { expect(described_class.resolve(account_id: account.id, agent_key: "fleet-autonomy")).to eq(override) }
        .not_to change(Ai::Agent, :count)
    end
  end

  it "returns nil when nothing carries the identity or the key" do
    expect(described_class.resolve(account_id: account.id, agent_key: "fleet-autonomy")).to be_nil
  end
end
