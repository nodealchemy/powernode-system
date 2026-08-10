# frozen_string_literal: true

require "rails_helper"

# RCP v2 dual-plane fence wiring (IMP-b1df020ea612): ControlPlaneRole.active?
# is documented as "the ONLY thing between a partition and dual-active" — but a
# gate nothing consults fences nothing. Every reconciler that can actuate must
# consult it immediately after the kill-switch check and stand down on the
# non-active plane.
#
# The gate's own semantics (arming, freshness, election, fail-toward-standby)
# are covered by control_plane_role_spec; these specs pin the WIRING only, so
# the gate is stubbed at its public boundary.
RSpec.describe "control-plane fence wiring" do
  let(:account) { create(:account) }

  describe System::Fleet::FleetAutonomyService do
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { described_class.new(account: account, agent: agent) }

    it "stands down without sensing when this plane is not active" do
      expect(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
      expect(service).not_to receive(:collect_signals)

      result = service.tick!

      expect(result[:ok]).to be false
      expect(result[:standby]).to be true
    end

    it "ticks normally while the gate is inert (unarmed single-plane deployment)" do
      # No coordinator SiteSetting exists in the test DB — armed? is false, so
      # the REAL gate must answer true and the tick must proceed to sensing.
      expect(service).to receive(:collect_signals).and_return([ [], [] ])

      result = service.tick!

      expect(result[:standby]).to be_nil
    end

    it "reports halted, not standby, when the kill-switch is engaged on a standby plane" do
      # The emergency halt outranks the fence: an operator who pressed stop
      # must see "halted" as the reason on every plane, active or not.
      account.suspend_ai!
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)

      result = service.tick!

      expect(result[:halted]).to be true
      expect(result[:standby]).to be_nil
    end
  end

  describe System::CveOps::CveResponderService do
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "CVE Responder") }
    let(:service) { described_class.new(account: account, agent: agent) }

    it "stands down without sensing when this plane is not active" do
      expect(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
      expect(service).not_to receive(:collect_signals)

      result = service.tick!

      expect(result[:ok]).to be false
      expect(result[:standby]).to be true
    end

    it "ticks normally while the gate is inert" do
      expect(service).to receive(:collect_signals).and_return([])

      result = service.tick!

      expect(result[:standby]).to be_nil
    end
  end
end
