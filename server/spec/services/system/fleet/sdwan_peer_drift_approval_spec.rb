# frozen_string_literal: true

require "rails_helper"

# IMP-01a0ed52 — a drift signal never rotates a WireGuard key on its own.
#
# system.sdwan_peer_drift used to bind SdwanPeerRemediateExecutor under
# system.sdwan_peer_remediate (notify_and_proceed), so a sensor tick revoked a
# peer's working key and generated a new one with no person involved, dropping a
# tunnel that had only stopped handshaking. The lane's automatic step is now
# diagnosis plus ONE approval request under sdwan.peer_key_rotate, and the
# rotation runs only on approval, through Sdwan::PeerKeyRotationService.
#
# The safety is in code, not in a policy row: rows already seeded on running
# installs are not rewritten by a declaration change, so the specs below set the
# old category to notify_and_proceed / auto_approve and prove nothing rotates.
RSpec.describe "SDWAN peer drift approval lane" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let(:network) { create(:sdwan_network, account: account) }
  let!(:peer) do
    p = create(:sdwan_peer, :active, account: account, network: network)
    Sdwan::KeyDistributor.ensure_key_for!(p)
    p.reload
  end
  let!(:original_key) { peer.active_key }
  let(:fingerprint) { "sdwan_peer_drift:#{peer.id}" }
  let(:signal) do
    { kind: "system.sdwan_peer_drift", severity: :high, fingerprint: fingerprint,
      payload: { peer_id: peer.id, network_id: network.id, handshake_age_seconds: 1900,
                 last_handshake_at: 40.minutes.ago.utc.iso8601 } }
  end

  # The chain the fleet lane parks its requests on (as decision_engine_spec does).
  before do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
  end

  def policy!(category, verb)
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: category, policy: verb, is_active: true)
  end

  def pending_requests
    Ai::ApprovalRequest.where(account: account, source_type: System::Fleet::FleetAutonomyService::SOURCE_TYPE)
  end

  %w[notify_and_proceed auto_approve].each do |verb|
    context "with system.sdwan_peer_remediate seeded #{verb}" do
      before do
        policy!("system.sdwan_peer_remediate", verb)
        # The row the governance reconcile declares for the SDWAN Manager.
        policy!("sdwan.peer_key_rotate", "require_approval")
      end

      it "makes zero KeyDistributor.rotate! calls and files exactly one sdwan.peer_key_rotate request" do
        expect(Sdwan::KeyDistributor).not_to receive(:rotate!)

        decision = engine.decide(signal)

        expect(decision[:decision]).to eq(:pending)
        expect(decision[:action_category]).to eq("sdwan.peer_key_rotate")
        expect(pending_requests.count).to eq(1)
        expect(peer.reload.active_key.id).to eq(original_key.id)
        expect(original_key.reload.revoked?).to be(false)
      end
    end
  end

  context "when sdwan.peer_key_rotate itself has been loosened to auto_approve on a row" do
    before { policy!("sdwan.peer_key_rotate", "auto_approve") }

    it "still files a request and rotates nothing (the lane forces approval in code)" do
      expect(Sdwan::KeyDistributor).not_to receive(:rotate!)

      decision = engine.decide(signal)

      expect(decision[:decision]).to eq(:pending)
      expect(pending_requests.count).to eq(1)
      expect(original_key.reload.revoked?).to be(false)
    end
  end

  describe "the filed request" do
    before { policy!("sdwan.peer_key_rotate", "require_approval") }

    it "carries the peer, the drift evidence, the signal fingerprint and the proposed rotation, and no private key" do
      engine.decide(signal)
      data = pending_requests.sole.request_data
      payload = data["payload"]

      expect(payload["peer_id"]).to eq(peer.id)
      expect(payload["signal_fingerprint"]).to eq(fingerprint)
      expect(payload["handshake_age_seconds"]).to eq(1900)
      expect(payload["skill_plan"]).to include("would_rotate_from" => original_key.id,
                                               "would_rotate_from_pubkey" => original_key.public_key)
      expect(data.to_json).not_to match(/private/i)
    end
  end

  describe "the operator's answer" do
    before do
      policy!("sdwan.peer_key_rotate", "require_approval")
      engine.decide(signal)
    end

    let(:request) { pending_requests.sole }

    it "rotates through PeerKeyRotationService on approval, revokes the old key, and audits signal and peer" do
      request.record_decision!(approver: create(:user, account: account), decision: "approved")
      expect(Sdwan::PeerKeyRotationService).to receive(:new).and_call_original

      result = engine.execute_approved!(request.reload)

      expect(result[:applied]).to be(true)
      expect(original_key.reload.revoked?).to be(true)
      new_key = peer.reload.active_key
      expect(new_key.id).not_to eq(original_key.id)
      expect(new_key.rotated_from_id).to eq(original_key.id)
      expect(result.to_json).to include(new_key.id)

      audit = AuditLog.where(action: Sdwan::PeerKeyRotationService::AUDIT_ACTION, resource_id: peer.id.to_s).sole
      expect(audit.metadata["reason"]).to include(fingerprint).and include(request.id)
      expect(audit.metadata["new_key_id"]).to eq(new_key.id)
      expect(audit.metadata.to_json).not_to match(/private/i)
      expect(result.to_json).not_to match(/private/i)
    end

    it "leaves the keyring untouched when the request is declined" do
      request.record_decision!(approver: create(:user, account: account), decision: "rejected")
      expect(Sdwan::KeyDistributor).not_to receive(:rotate!)

      # The act arm only replays APPROVED requests.
      expect(service.execute_approved_actions!(engine)).to eq([])

      expect(peer.reload.active_key.id).to eq(original_key.id)
      expect(original_key.reload.revoked?).to be(false)
    end
  end

  describe "the proceed path" do
    it "never actuates: the applier refuses without an approved request" do
      expect(Sdwan::KeyDistributor).not_to receive(:rotate!)

      result = engine.send(:apply_remediation!,
                           System::Fleet::Signal.from_hash(signal), nil)

      expect(result[:applied]).to be(false)
      expect(original_key.reload.revoked?).to be(false)
    end
  end
end
