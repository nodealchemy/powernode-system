# frozen_string_literal: true

require "rails_helper"

# Autonomy safety rail (increment #28 / imp 019f6d6b-4427): the emergency
# kill-switch must be AUTHORITATIVE across every reconciler that can actuate.
# FleetAutonomyService#tick! must no-op while the account is under emergency
# halt — no sensing, no deciding, no reaping, no task dispatch.
#
# Deliberately independent of Ai::ApprovalChain (business extension) so it runs
# in core mode too: the kill-switch short-circuit happens before any approval
# machinery is reached.
RSpec.describe System::Fleet::FleetAutonomyService, "kill-switch guard" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { described_class.new(account: account, agent: agent) }

  describe "#kill_switch_engaged?" do
    it "reflects the account's emergency-halt state" do
      expect(service.kill_switch_engaged?).to be false
      account.suspend_ai!
      expect(service.kill_switch_engaged?).to be true
    end
  end

  describe "#tick! while the kill-switch is engaged" do
    before { account.suspend_ai! }

    it "no-ops and reports halted without sensing or deciding" do
      expect(service).not_to receive(:collect_signals)
      result = service.tick!
      expect(result[:ok]).to be false
      expect(result[:halted]).to be true
    end

    it "dispatches no reconcile task" do
      expect { service.tick! }.not_to change(System::Task, :count)
    end
  end
end
