# frozen_string_literal: true

require "rails_helper"

# Phase 3c — federation peer liveness remediation.
RSpec.describe System::Ai::Skills::FederationPeerRemediateExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }

  # Stub the outbound federation probe. `reachable: true` → fetch_catalog
  # returns; `reachable: false` → it raises a PeerClient::ConnectionError
  # (the unreachable failure mode the executor catches).
  def stub_probe(reachable:)
    client = instance_double(::Federation::PeerClient)
    if reachable
      allow(client).to receive(:fetch_catalog).and_return("offerings" => [])
    else
      allow(client).to receive(:fetch_catalog)
        .and_raise(::Federation::PeerClient::ConnectionError, "peer offline")
    end
    allow(::Federation::PeerClient).to receive(:new).and_return(client)
    client
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and metadata" do
      d = described_class.descriptor
      expect(d[:name]).to eq("federation_peer_remediate")
      expect(d[:category]).to eq("federation")
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
      expect(d.dig(:inputs, :federation_peer_id, :required)).to be true
      expect(d[:outputs].keys).to include(:remediated, :action, :reason, :peer_status, :reachable)
    end
  end

  describe "#execute — guard rails" do
    it "binds to the SDWAN Manager agent under the canonical slug" do
      entry = System::Ai::Skills::SkillBindings.by_skill
                .find { |e| e[:executor].name == described_class.name }
      expect(entry).not_to be_nil
      expect(entry[:skill_slug]).to eq("system-federation-peer-remediate")
      expect(entry[:agents]).to include("sdwan-manager")
    end

    it "fails on an unknown reason" do
      peer = create(:system_federation_peer, :active, account: account)
      result = exec.execute(federation_peer_id: peer.id, reason: "explode")
      expect(result[:success]).to be false
      expect(result[:error]).to match(/reason must be one of/)
    end

    it "fails when the peer does not exist in the account" do
      result = exec.execute(federation_peer_id: SecureRandom.uuid)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/not found in account/)
    end

    it "refuses to remediate a non-platform (sdwan_only) peer" do
      peer = create(:system_federation_peer, account: account,
                                             peer_kind: "sdwan_only", status: "accepted")
      result = exec.execute(federation_peer_id: peer.id)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/only applies to platform peers/)
    end

    it "scopes to the current account" do
      other = create(:account)
      peer  = create(:system_federation_peer, :active, account: other)
      result = exec.execute(federation_peer_id: peer.id)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/not found in account/)
    end
  end

  describe "#execute — dry_run" do
    it "reports the planned action without probing or mutating" do
      peer = create(:system_federation_peer, :active, account: account)
      expect(::Federation::PeerClient).not_to receive(:new)

      result = exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale", dry_run: true)
      expect(result[:success]).to be true
      expect(result[:data][:remediated]).to be false
      expect(result[:data][:action]).to match(/degrade if unreachable/)
      expect(peer.reload.status).to eq("active")
    end
  end

  describe "#execute — heartbeat_stale" do
    it "re-handshakes when the peer is reachable (no forced state change)" do
      peer = create(:system_federation_peer, :active, account: account, last_heartbeat_at: 10.minutes.ago)
      stub_probe(reachable: true)

      result = exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale")
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq("rehandshaked")
      expect(result[:data][:reachable]).to be true
      # We never forge a heartbeat: status stays active (the real inbound
      # heartbeat path does record_heartbeat!), it is not flipped here.
      expect(peer.reload.status).to eq("active")
    end

    it "degrades an unreachable ACTIVE peer (active → degraded)" do
      peer = create(:system_federation_peer, :active, account: account, last_heartbeat_at: 10.minutes.ago)
      stub_probe(reachable: false)

      result = exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale")
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq("degraded")
      expect(result[:data][:reachable]).to be false
      expect(peer.reload.status).to eq("degraded")
    end

    it "alerts (does not degrade) an unreachable ENROLLED peer" do
      peer = create(:system_federation_peer, :enrolled, account: account, last_heartbeat_at: nil)
      stub_probe(reachable: false)

      result = exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale")
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq("alerted")
      expect(result[:data][:remediated]).to be false
      # enrolled cannot transition to degraded (V1_TRANSITIONS) — left intact.
      expect(peer.reload.status).to eq("enrolled")
    end

    it "emits a FleetEvent on degrade" do
      peer = create(:system_federation_peer, :active, account: account, last_heartbeat_at: 10.minutes.ago)
      stub_probe(reachable: false)

      # The active → degraded transition fires FederationPeer#broadcast_peer_state!
      # — the single canonical state-change event (severity is the string "medium"
      # to match broadcast_peer_state!); the executor no longer emits a duplicate.
      #
      # The permissive stub first: since APO-2d every BaseSkillExecutor#execute
      # also emits its own skill.execute_started/_finished audit through this
      # same door, and a bare constrained expectation would raise
      # RSpec::Mocks::MockExpectationError on the FIRST of those. This example
      # is about the degrade event, not about being the only emit.
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_call_original
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!).with(
        hash_including(account: account, kind: "federation.peer.degraded", severity: "medium")
      ).and_call_original

      exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale")
    end

    it "is idempotent — re-running on an already-degraded peer alerts rather than re-degrading" do
      peer = create(:system_federation_peer, account: account, peer_kind: "platform",
                                             spawn_role: "symmetric", status: "degraded",
                                             last_heartbeat_at: 20.minutes.ago)
      stub_probe(reachable: false)

      result = exec.execute(federation_peer_id: peer.id, reason: "heartbeat_stale")
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq("alerted")
      expect(peer.reload.status).to eq("degraded")
    end
  end

  describe "#execute — cert remediation (operator-driven)" do
    let(:cert) do
      ::System::NodeCertificate.create!(
        account: account, subject_kind: "federation_peer",
        subject: "peer-#{SecureRandom.uuid}", serial: SecureRandom.hex(16),
        not_before: 60.days.ago, not_after: 5.days.from_now,
        pem_chain: "stub", issuer_subject: "CN=Powernode Internal CA"
      )
    end

    it "alerts (never auto-rotates) on cert_expiring" do
      peer = create(:system_federation_peer, :active, account: account, outbound_certificate: cert)
      # The probe must never run for a cert remediation.
      expect(::Federation::PeerClient).not_to receive(:new)

      result = exec.execute(federation_peer_id: peer.id, reason: "cert_expiring")
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq("alerted")
      expect(result[:data][:requires_operator_action]).to be true
      expect(result[:data][:certificate_id]).to eq(cert.id)
    end

    it "emits a high-severity FleetEvent on cert_expired" do
      peer = create(:system_federation_peer, :active, account: account, outbound_certificate: cert)
      # See the degrade example: the executor's own APO-2d audit events reach
      # this same collaborator and must not fail the constrained expectation.
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_call_original
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!).with(
        hash_including(kind: "federation.peer.cert_rotation_required", severity: :high)
      ).and_call_original

      result = exec.execute(federation_peer_id: peer.id, reason: "cert_expired")
      expect(result[:data][:action]).to eq("alerted")
    end
  end
end
