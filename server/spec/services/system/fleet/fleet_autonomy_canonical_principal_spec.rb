# frozen_string_literal: true

require "rails_helper"

# HIER-P2I — an autonomy tick on an account that has NO clone of the seeded
# (global) Fleet Autonomy canonical must still act: the tick resolves the
# account's clone through the same rule the reconciler writes with
# (System::Governance::AgentResolver → Ai::Agents::AccountPrincipalResolver),
# mints it on first use, and the acting agent — the one every skill executor
# and nested tool receives as `agent:` — has account_id = the account. Without
# this the tool seam's canonical refusal (Ai::Tools::BaseTool, ruling 8) would
# break fleet autonomy on the first tick.
RSpec.describe System::Fleet::FleetAutonomyService, "canonical principals never execute (HIER-P2I)" do
  let(:seeding_account) { create(:account, name: "Powernode Admin") }
  let(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:canonical) do
    create(:ai_agent, :global, owner_account: seeding_account, name: "Fleet Autonomy",
                               source_key: "fleet-autonomy", agent_type: "monitor", is_system: true)
  end

  describe ".tick! on an account with no clone" do
    it "acts through a lazily minted clone whose account_id is the account, with the account's rows re-homed" do
      row = Ai::InterventionPolicy.create!(account: account, ai_agent_id: canonical.id, scope: "agent",
                                           action_category: "system.cert_rotate", policy: "auto_approve",
                                           priority: 10, is_active: true)
      acting = nil
      allow(described_class).to receive(:new).and_wrap_original do |original, **kwargs|
        acting ||= kwargs[:agent]
        original.call(**kwargs)
      end

      result = described_class.tick!(account: account)

      expect(result[:ok]).to be(true), result.inspect
      expect(acting).to be_present
      expect(acting.id).not_to eq(canonical.id)
      expect(acting.global?).to be(false)
      expect(acting.account_id).to eq(account.id)
      expect(acting.cloned_from_id).to eq(canonical.id)
      expect(row.reload.ai_agent_id).to eq(acting.id)
    end

    it "keeps reporting the seed gap when no Fleet Autonomy exists at all" do
      canonical.update_columns(name: "Something Else", source_key: "something-else")

      result = described_class.tick!(account: account)

      expect(result[:ok]).to be(false)
      expect(result[:reason]).to match(/not seeded/)
    end
  end

  describe "#for_owner with only the GLOBAL owner canonical" do
    it "gates the binding under the account's clone of the owner, never the canonical" do
      sdwan = create(:ai_agent, :global, owner_account: seeding_account, name: "SDWAN Manager",
                                         source_key: "sdwan-manager", agent_type: "monitor", is_system: true)
      fleet = System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "fleet-autonomy")
      service = described_class.new(account: account, agent: fleet)

      gate = service.for_owner("sdwan-manager")

      expect(gate.agent.id).not_to eq(sdwan.id)
      expect(gate.agent.account_id).to eq(account.id)
      expect(gate.agent.cloned_from_id).to eq(sdwan.id)
    end
  end
end
