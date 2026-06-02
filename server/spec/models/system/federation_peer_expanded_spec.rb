# frozen_string_literal: true

require "rails_helper"

# Covers the P3.3 expansion of System::FederationPeer for platform-level
# federation. The pre-P3 behavior (sdwan_only peers, prefix overlap
# detection) is exercised elsewhere; this spec focuses on the new
# platform_peer state machine + helpers.
RSpec.describe System::FederationPeer, type: :model do
  describe "constants" do
    it "defines PEER_KINDS, SPAWN_MODES, SPAWN_ROLES, STATUSES" do
      expect(described_class::PEER_KINDS).to eq(%w[sdwan_only platform])
      expect(described_class::SPAWN_MODES).to eq(%w[managed_child autonomous_peer cluster_member out_of_band])
      expect(described_class::SPAWN_ROLES).to eq(%w[parent child symmetric])
      expect(described_class::STATUSES).to eq(%w[proposed accepted enrolled active degraded suspended revoked])
    end
  end

  describe "TRANSITIONS" do
    it "permits accepted → enrolled → active" do
      peer = build(:system_federation_peer, :platform, status: "accepted")
      expect(peer.can_transition_to?("enrolled")).to be true

      peer.status = "enrolled"
      expect(peer.can_transition_to?("active")).to be true
    end

    it "permits active ⇄ degraded" do
      peer = build(:system_federation_peer, :active)
      expect(peer.can_transition_to?("degraded")).to be true

      peer.status = "degraded"
      expect(peer.can_transition_to?("active")).to be true
    end

    it "marks revoked as terminal" do
      peer = build(:system_federation_peer, status: "revoked")
      %w[proposed accepted enrolled active degraded suspended].each do |target|
        expect(peer.can_transition_to?(target)).to be false
      end
    end
  end

  describe "validations" do
    it "requires spawn_role on platform peers" do
      peer = build(:system_federation_peer, peer_kind: "platform", spawn_role: nil)
      expect(peer).not_to be_valid
      expect(peer.errors[:spawn_role]).to include(/required/)
    end

    it "allows nil spawn_role on sdwan_only peers" do
      peer = build(:system_federation_peer, peer_kind: "sdwan_only", spawn_role: nil)
      expect(peer).to be_valid
    end

    it "rejects unknown peer_kind" do
      peer = build(:system_federation_peer, peer_kind: "bogus")
      expect(peer).not_to be_valid
      expect(peer.errors[:peer_kind]).to be_present
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }

    let!(:proposed)  { create(:system_federation_peer, account: account, status: "proposed") }
    let!(:enrolled)  { create(:system_federation_peer, :enrolled, account: account) }
    let!(:active)    { create(:system_federation_peer, :active, account: account) }
    let!(:degraded)  { create(:system_federation_peer, :platform, account: account, status: "degraded", last_heartbeat_at: 10.minutes.ago) }
    let!(:sdwan_only_peer) { create(:system_federation_peer, account: account, status: "accepted") }

    it ".platform_peers excludes sdwan_only rows" do
      expect(described_class.platform_peers).to include(enrolled, active, degraded)
      expect(described_class.platform_peers).not_to include(sdwan_only_peer)
    end

    it ".reachable returns enrolled + active + degraded (degraded can self-recover via heartbeat)" do
      expect(described_class.reachable).to include(enrolled, active, degraded)
      expect(described_class.reachable).not_to include(proposed)
    end

    it ".heartbeat_stale returns active/enrolled platform peers past the threshold" do
      stale_active = create(:system_federation_peer, :active,
                             account: account, last_heartbeat_at: 10.minutes.ago)
      expect(described_class.heartbeat_stale).to include(stale_active)
      expect(described_class.heartbeat_stale).not_to include(active)  # fresh
      expect(described_class.heartbeat_stale).not_to include(sdwan_only_peer)
    end
  end

  describe "#platform_peer? + #sdwan_only_peer?" do
    it "returns true for platform peers" do
      peer = build(:system_federation_peer, :platform)
      expect(peer.platform_peer?).to be true
      expect(peer.sdwan_only_peer?).to be false
    end

    it "returns true for sdwan-only peers" do
      peer = build(:system_federation_peer)
      expect(peer.sdwan_only_peer?).to be true
      expect(peer.platform_peer?).to be false
    end
  end

  describe "#heartbeat_stale?" do
    it "returns false for sdwan_only peers regardless of heartbeat" do
      peer = create(:system_federation_peer, last_heartbeat_at: nil)
      expect(peer.heartbeat_stale?).to be false
    end

    it "returns true for platform peers with no heartbeat ever" do
      peer = create(:system_federation_peer, :enrolled, last_heartbeat_at: nil)
      expect(peer.heartbeat_stale?).to be true
    end

    it "returns true for platform peers past the threshold" do
      peer = create(:system_federation_peer, :active, last_heartbeat_at: 10.minutes.ago)
      expect(peer.heartbeat_stale?).to be true
    end

    it "returns false for recently-heartbeated platform peers" do
      peer = create(:system_federation_peer, :active, last_heartbeat_at: 30.seconds.ago)
      expect(peer.heartbeat_stale?).to be false
    end
  end

  describe "#enroll!" do
    let(:peer) { create(:system_federation_peer, :platform, status: "accepted") }

    it "transitions accepted → enrolled and stores handshake artifacts" do
      result = peer.enroll!(
        capabilities: { "skill" => { "read" => true } },
        extension_slugs: %w[trading],
        endpoints: [ { "url" => "https://peer.example.com:443", "scope" => "wan", "priority" => 1 } ]
      )
      expect(result).to be true
      peer.reload
      expect(peer.status).to eq("enrolled")
      expect(peer.capabilities).to eq("skill" => { "read" => true })
      expect(peer.extension_slugs).to eq(%w[trading])
      expect(peer.endpoints.first["scope"]).to eq("wan")
      expect(peer.last_handshake_at).to be_within(2.seconds).of(Time.current)
    end

    it "refuses to enroll from non-accepted states" do
      peer.update!(status: "proposed")
      expect(peer.enroll!).to be false
      expect(peer.reload.status).to eq("proposed")
    end
  end

  describe "#record_heartbeat!" do
    it "transitions enrolled → active on first heartbeat" do
      peer = create(:system_federation_peer, :enrolled)
      peer.record_heartbeat!
      expect(peer.reload.status).to eq("active")
    end

    it "transitions degraded → active on recovery heartbeat" do
      peer = create(:system_federation_peer, :platform, status: "degraded")
      peer.record_heartbeat!
      expect(peer.reload.status).to eq("active")
    end

    it "leaves active peers active (just refreshes the timestamp)" do
      peer = create(:system_federation_peer, :active, last_heartbeat_at: 1.minute.ago)
      peer.record_heartbeat!
      peer.reload
      expect(peer.status).to eq("active")
      expect(peer.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "merges capability + endpoint updates atomically" do
      peer = create(:system_federation_peer, :enrolled)
      peer.record_heartbeat!(
        capabilities: { "v" => 2 },
        endpoints: [ { "url" => "x" } ]
      )
      expect(peer.reload.capabilities).to eq("v" => 2)
      expect(peer.endpoints).to eq([ { "url" => "x" } ])
    end
  end

  describe "#mark_degraded!" do
    it "transitions active → degraded with the supplied reason" do
      peer = create(:system_federation_peer, :active)
      peer.mark_degraded!(reason: "missed 5 heartbeats")
      peer.reload
      expect(peer.status).to eq("degraded")
      expect(peer.metadata["degraded_reason"]).to eq("missed 5 heartbeats")
    end
  end

  # ── Phase 3a — real-time peer-state push ──────────────────────────────
  describe "real-time peer-state broadcasts" do
    it "emits a federation.peer.heartbeat FleetEvent on record_heartbeat!" do
      # A first heartbeat on an enrolled peer also transitions enrolled →
      # active, so the status-transition callback fires a federation.peer.active
      # event alongside the heartbeat ping. Allow both; assert the heartbeat.
      peer = create(:system_federation_peer, :enrolled)
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!)
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .with(hash_including(kind: "federation.peer.heartbeat", account: peer.account))
      peer.record_heartbeat!
    end

    it "emits a single federation.peer.heartbeat (no status event) for an already-active peer" do
      # No status change → broadcast_status_transition! does not fire; only the
      # liveness ping is emitted.
      peer = create(:system_federation_peer, :active, last_heartbeat_at: 1.minute.ago)
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .once
        .with(hash_including(kind: "federation.peer.heartbeat"))
      peer.record_heartbeat!
    end

    it "emits a federation.peer.degraded FleetEvent (severity medium) on mark_degraded!" do
      peer = create(:system_federation_peer, :active)
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .with(hash_including(kind: "federation.peer.degraded", severity: "medium"))
      peer.mark_degraded!(reason: "stale")
    end

    it "emits a federation.peer.accepted FleetEvent (severity low) on accept!" do
      peer = create(:system_federation_peer, :platform, status: "proposed")
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .with(hash_including(kind: "federation.peer.accepted", severity: "low"))
      peer.accept!
    end

    it "emits a federation.peer.suspended FleetEvent (severity medium) on suspend!" do
      peer = create(:system_federation_peer, :active)
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .with(hash_including(kind: "federation.peer.suspended", severity: "medium"))
      peer.suspend!(reason: "operator pause")
    end

    it "emits a federation.peer.revoked FleetEvent (severity high) on revoke!" do
      peer = create(:system_federation_peer, :active)
      expect(::System::Fleet::EventBroadcaster)
        .to receive(:emit!)
        .with(hash_including(kind: "federation.peer.revoked", severity: "high"))
      peer.revoke!(reason: "trust withdrawn")
    end

    it "does not emit for sdwan_only peers (platform-only observability)" do
      # sdwan_only peers don't progress past accepted; force a heartbeat-eligible
      # state to confirm the platform_peer? guard short-circuits the broadcast.
      peer = create(:system_federation_peer, status: "accepted", peer_kind: "sdwan_only")
      expect(::System::Fleet::EventBroadcaster).not_to receive(:emit!)
      peer.send(:broadcast_peer_state!, kind: "heartbeat")
    end
  end

  describe "#suspend!" do
    it "transitions any pre-revoked state to suspended" do
      peer = create(:system_federation_peer, :active)
      peer.suspend!(reason: "operator pause")
      expect(peer.reload.status).to eq("suspended")
      expect(peer.metadata["suspension_reason"]).to eq("operator pause")
    end
  end

  describe "spawned-child relationship" do
    it "links child peers to their parent peer via parent_peer_id" do
      parent = create(:system_federation_peer, :platform, spawn_role: "parent",
                                                          spawn_mode: "managed_child")
      child = create(:system_federation_peer, :spawned_child, parent_peer: parent)
      expect(child.parent_peer).to eq(parent)
      expect(parent.child_peers).to include(child)
    end
  end

  # ── Federation mTLS Phase 2 — three separated certificate concerns ────
  # The conflated single `node_certificate` was split into: outbound
  # identity (what we present), inbound_subject (what the peer presents),
  # and trusted_ca_pem (the peer CA we accept on the federation route).
  describe "certificate directionality (Phase 2)" do
    let(:account) { create(:account) }

    it "binds an outbound_certificate — the cert WE present to the peer" do
      cert = create(:system_node_certificate, :federation_peer, account: account)
      peer = create(:system_federation_peer, :enrolled, account: account,
                                                         outbound_certificate: cert)
      expect(peer.reload.outbound_certificate).to eq(cert)
    end

    it "no longer responds to the removed node_certificate association" do
      peer = build(:system_federation_peer, :platform)
      expect(peer).not_to respond_to(:node_certificate)
    end

    it "stores an inbound_subject — the CN the peer presents to us" do
      peer = create(:system_federation_peer, :enrolled, account: account,
                                                         inbound_subject: "fed:abc")
      expect(peer.reload.inbound_subject).to eq("fed:abc")
    end

    it "enforces inbound_subject uniqueness so no peer can claim another's identity" do
      create(:system_federation_peer, :enrolled, account: account, inbound_subject: "fed:dup")
      dup = build(:system_federation_peer, :enrolled, account: account, inbound_subject: "fed:dup")
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    describe ".trusted_ca_pems" do
      it "collects non-blank anchors from reachable platform peers only" do
        create(:system_federation_peer, :active,   account: account, trusted_ca_pem: "-----CA-A-----")
        create(:system_federation_peer, :enrolled, account: account, trusted_ca_pem: "-----CA-B-----")
        # proposed → not reachable, excluded
        create(:system_federation_peer, :platform, account: account, status: "proposed",
                                                    trusted_ca_pem: "-----CA-C-----")
        # reachable but no anchor (hierarchical child off our own CA) → excluded
        create(:system_federation_peer, :active,   account: account, trusted_ca_pem: nil)

        expect(described_class.trusted_ca_pems).to contain_exactly("-----CA-A-----", "-----CA-B-----")
      end

      it "deduplicates identical anchors" do
        create(:system_federation_peer, :active,   account: account, trusted_ca_pem: "-----SAME-----")
        create(:system_federation_peer, :enrolled, account: account, trusted_ca_pem: "-----SAME-----")
        expect(described_class.trusted_ca_pems).to eq([ "-----SAME-----" ])
      end
    end
  end
end
