# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — DecisionEngine routes signals to skills + actions.
RSpec.describe System::Fleet::DecisionEngine do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)   { described_class.new(autonomy_service: service) }

  describe "#decide" do
    context "with an unrecognized signal kind" do
      it "skips with reason" do
        d = engine.decide(kind: "system.unknown_thing", severity: :low, payload: {}, fingerprint: "x")
        expect(d[:decision]).to eq(:skipped)
        expect(d[:reason]).to match(/no binding/)
      end
    end

    context "with a system.cert_expiring signal (no skill, just gate)" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      it "routes to system.cert_rotate and proceeds via auto_approve" do
        d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                          payload: { certificate_id: "c-1", instance_id: "i-1" },
                          fingerprint: "cert_expiring:c-1")
        expect(d[:action_category]).to eq("system.cert_rotate")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:gate]).to eq("auto_approve")
      end
    end

    context "with a system.instance_silent signal (skill-driven)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }

      # NOTE: an `ai_approval_chain` row was previously created here for
      # parity with the business-extension Ai::ApprovalChain model, but
      # the system-extension DecisionEngine has no path that consults
      # ApprovalChain — gating is driven entirely by Ai::InterventionPolicy
      # below. The chain row was cross-extension dead weight (the
      # ApprovalChain class lives in extensions/business and is absent in
      # core mode), so it was removed. Add it back only if a real code
      # path in the system extension starts consulting ApprovalChain.

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
      end

      it "invokes the drift_remediate skill and gates as require_approval" do
        d = engine.decide(kind: "system.instance_silent", severity: :high,
                          payload: { "instance_id" => instance.id },
                          fingerprint: "instance_silent:#{instance.id}")
        expect(d[:action_category]).to eq("system.instance_reprovision")
        expect(d[:skill_result]).to be_present
        expect(d[:skill_result][:success]).to be true
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
      end
    end

    # Audit finding F3-04: invoke_skill's class-name case statement silently
    # dropped the four SDWAN executors bound in SIGNAL_BINDINGS (fell through
    # to `else nil`), so peer key rotation and BGP session remediation never
    # ran. Dispatch now flows through each binding's input_mapper.
    context "with SDWAN signals (executor dispatch)" do
      it "invokes SdwanPeerRemediateExecutor with peer_id and proceeds via notify_and_proceed" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.sdwan_peer_remediate",
                                       policy: "notify_and_proceed", is_active: true)
        executor = instance_double(System::Ai::Skills::SdwanPeerRemediateExecutor)
        allow(System::Ai::Skills::SdwanPeerRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(peer_id: "peer-1")
                                             .and_return({ success: true, data: { resolved: true } })

        d = engine.decide(kind: "system.sdwan_peer_drift", severity: :high,
                          payload: { peer_id: "peer-1", network_id: "net-1" },
                          fingerprint: "sdwan_peer_drift:peer-1")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:skill_result]).to eq({ success: true, data: { resolved: true } })
      end

      it "invokes SdwanFailoverExecutor with the network_id" do
        executor = instance_double(System::Ai::Skills::SdwanFailoverExecutor)
        allow(System::Ai::Skills::SdwanFailoverExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(network_id: "net-1")
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_hub_unreachable", severity: :critical,
                      payload: { network_id: "net-1" },
                      fingerprint: "sdwan_hub_unreachable:net-1")
      end

      it "invokes SdwanBgpSessionRemediateExecutor with session, peer and neighbor address" do
        executor = instance_double(System::Ai::Skills::SdwanBgpSessionRemediateExecutor)
        allow(System::Ai::Skills::SdwanBgpSessionRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute)
          .with(bgp_session_id: "bgp-1", peer_id: "peer-1", neighbor_address: "10.0.0.2")
          .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_bgp_session_unhealthy", severity: :high,
                      payload: { bgp_session_id: "bgp-1", peer_id: "peer-1",
                                 neighbor_address: "10.0.0.2" },
                      fingerprint: "bgp:bgp-1")
      end

      it "invokes SdwanVipFailoverExecutor with the virtual_ip_id" do
        executor = instance_double(System::Ai::Skills::SdwanVipFailoverExecutor)
        allow(System::Ai::Skills::SdwanVipFailoverExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(virtual_ip_id: "vip-1")
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_vip_unreachable", severity: :critical,
                      payload: { virtual_ip_id: "vip-1" },
                      fingerprint: "vip:vip-1")
      end
    end
  end

  describe "SIGNAL_BINDINGS" do
    it "declares a callable input_mapper for every binding with a skill" do
      missing = described_class::SIGNAL_BINDINGS
                  .select { |_kind, b| b[:skill] && !b[:input_mapper].respond_to?(:call) }
      expect(missing.keys).to eq([])
    end
  end

  describe "#decide_all" do
    it "returns one decision per signal" do
      signals = [
        { kind: "system.unknown1", severity: :low, payload: {}, fingerprint: "x" },
        { kind: "system.unknown2", severity: :low, payload: {}, fingerprint: "y" }
      ]
      decisions = engine.decide_all(signals)
      expect(decisions.size).to eq(2)
      expect(decisions.map { |d| d[:decision] }).to all(eq(:skipped))
    end
  end
end
