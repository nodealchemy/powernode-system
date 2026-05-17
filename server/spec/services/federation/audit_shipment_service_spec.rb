# frozen_string_literal: true

require "rails_helper"

# P9.2 — Federation::AuditShipmentService spec.
#
# Locks the WORM-shipping behavior: only events older than 30d are
# shipped, only events tagged with the peer's federation_peer_id /
# peer_id are scoped, the seal is sha256-verified, source rows get
# `worm_shipped_at` stamped so they're not re-shipped, and per-peer
# failures don't poison the rest of the sweep.
RSpec.describe ::Federation::AuditShipmentService, type: :service do
  let(:account) { create(:account) }
  let(:peer) do
    ::System::FederationPeer.create!(
      account:             account,
      remote_instance_url: "https://peer-#{SecureRandom.hex(4)}.example.com",
      peer_kind:           "platform",
      spawn_role:          "symmetric",
      spawn_mode:          "out_of_band",
      status:              "active"
    )
  end

  let(:now) { ::Time.utc(2026, 5, 17, 12, 0, 0) }
  let(:cutoff) { now - 30.days }

  let(:seal_dir) { ::Dir.mktmpdir("audit-shipment-spec-") }

  around do |example|
    saved = ENV["POWERNODE_AUDIT_SHIPMENT_DIR"]
    ENV["POWERNODE_AUDIT_SHIPMENT_DIR"] = seal_dir
    example.run
  ensure
    ENV["POWERNODE_AUDIT_SHIPMENT_DIR"] = saved
    ::FileUtils.rm_rf(seal_dir)
  end

  def make_event(peer_id:, emitted_at:, kind: "test.event")
    ::System::FleetEvent.create!(
      account:     account,
      kind:        kind,
      severity:    "low",
      payload:     { "federation_peer_id" => peer_id, "note" => "from spec" },
      emitted_at:  emitted_at,
      source:      "spec"
    )
  end

  describe "#run!" do
    it "ships events older than the 30-day cutoff and stamps source rows" do
      old_event = make_event(peer_id: peer.id, emitted_at: cutoff - 1.day)
      _new_event = make_event(peer_id: peer.id, emitted_at: cutoff + 1.day)

      result = described_class.run!(account: account, now: now)

      expect(result.shipped).to eq(1)
      expect(result.events).to eq(1)

      shipment = ::System::FederationAuditShipment.where(federation_peer: peer).last
      expect(shipment).not_to be_nil
      expect(shipment.status).to eq("verified")
      expect(shipment.event_count).to eq(1)
      expect(shipment.sha256).to match(/\A[a-f0-9]{64}\z/)
      expect(::File.exist?(shipment.sealed_path)).to be(true)

      # Source row got the worm marker
      old_event.reload
      expect(old_event.payload["worm_shipped_at"]).to be_present
      expect(old_event.payload["shipment_id"]).to eq(shipment.id)
    end

    it "doesn't re-ship events already stamped worm_shipped_at" do
      make_event(peer_id: peer.id, emitted_at: cutoff - 2.days)

      described_class.run!(account: account, now: now)
      first_shipment = ::System::FederationAuditShipment.last

      # Second run — nothing new to ship
      result = described_class.run!(account: account, now: now)
      expect(result.shipped).to eq(0)
      expect(::System::FederationAuditShipment.where(federation_peer: peer).count).to eq(1)
      expect(::System::FederationAuditShipment.last.id).to eq(first_shipment.id)
    end

    it "scopes events to the peer (no leakage between peers)" do
      other_peer = ::System::FederationPeer.create!(
        account: account, remote_instance_url: "https://other.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      make_event(peer_id: peer.id,       emitted_at: cutoff - 1.day)
      make_event(peer_id: other_peer.id, emitted_at: cutoff - 1.day)

      described_class.run!(account: account, now: now)

      mine   = ::System::FederationAuditShipment.where(federation_peer: peer).last
      theirs = ::System::FederationAuditShipment.where(federation_peer: other_peer).last
      expect(mine.event_count).to eq(1)
      expect(theirs.event_count).to eq(1)
    end

    it "skips revoked peers" do
      peer.update!(status: "revoked")
      make_event(peer_id: peer.id, emitted_at: cutoff - 1.day)

      result = described_class.run!(account: account, now: now)
      expect(result.swept_peers).to eq(0)
      expect(result.shipped).to eq(0)
    end

    it "writes a sha256-addressable seal file with the JSON-Lines content" do
      make_event(peer_id: peer.id, emitted_at: cutoff - 1.day, kind: "deterministic.kind")

      described_class.run!(account: account, now: now)
      shipment = ::System::FederationAuditShipment.last

      content = ::File.read(shipment.sealed_path)
      lines = content.lines
      expect(lines.size).to eq(1)
      parsed = ::JSON.parse(lines.first)
      expect(parsed["kind"]).to eq("deterministic.kind")
      expect(::Digest::SHA256.hexdigest(content)).to eq(shipment.sha256)
    end

    it "creates no shipment when there are no eligible events" do
      result = described_class.run!(account: account, now: now)
      expect(result.shipped).to eq(0)
      expect(::System::FederationAuditShipment.where(federation_peer: peer)).to be_empty
    end
  end
end
