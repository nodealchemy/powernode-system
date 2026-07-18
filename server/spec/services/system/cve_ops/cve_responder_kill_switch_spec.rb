# frozen_string_literal: true

require "rails_helper"

# Autonomy safety rail (increment #28 / imp 019f6d6b-4427): the emergency
# kill-switch must be AUTHORITATIVE across every reconciler that can actuate.
# CveResponderService#tick! must no-op while the account is under emergency
# halt — no sensing, no deciding, no inline CVE remediation dispatch.
#
# Deliberately independent of Ai::ApprovalChain (business extension) so it runs
# in core mode too: the kill-switch short-circuit happens before any gate or
# dispatch is reached.
RSpec.describe System::CveOps::CveResponderService, "kill-switch guard" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider) }
  let(:agent) do
    Ai::Agent.create!(
      account: account, creator: user, provider: provider,
      name: "CVE Responder", agent_type: "monitor", status: "active"
    )
  end
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

    it "no-ops and reports halted without sensing or dispatching" do
      expect(service).not_to receive(:collect_signals)
      result = service.tick!
      expect(result[:ok]).to be false
      expect(result[:halted]).to be true
    end
  end
end
