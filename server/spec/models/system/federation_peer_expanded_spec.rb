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
    let(:cert) { build_stubbed(:system_node_certificate) }  # any stand-in

    it "transitions accepted → enrolled and stores handshake artifacts" do
      result = peer.enroll!(
        node_certificate: nil,  # cert may be issued separately
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
      expect(peer.enroll!(node_certificate: nil)).to be false
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
end
