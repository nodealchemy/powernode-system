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

  # IMP-592827c29ec4 — backfilled events ship in OVERLAPPING periods, on purpose.
  #
  # The peer-state rows repaired by BackfillFederationPeerIdOnFleetEvents are
  # older than the 30-day boundary, so the moment they become visible they ship
  # — in a period derived from their OWN timestamps (#ship_for_peer!), which
  # will overlap shipments already sealed for this peer. Nothing raises: the
  # only constraint is period_end > period_start.
  #
  # The operator direction chose a complete-and-explained archive over either a
  # silent gap or a silent overlap, so the shipment has to say why.
  describe "backfilled events" do
    def backfilled_event(emitted_at:)
      ::System::FleetEvent.create!(
        account: account, kind: "federation.peer.revoked", severity: "high",
        emitted_at: emitted_at, source: "federation_peer",
        payload: { "federation_peer_id" => peer.id,
                   "peer_id" => peer.id,
                   "payload_key_backfilled_at" => "2026-08-19T12:00:00Z",
                   "payload_key_backfill_task" => "IMP-592827c29ec4" }
      )
    end

    it "records on the shipment how many of its events were backfilled, and why that overlaps" do
      backfilled_event(emitted_at: cutoff - 2.days)
      make_event(peer_id: peer.id, emitted_at: cutoff - 1.day)

      described_class.run!(account: account, now: now)

      shipment = ::System::FederationAuditShipment.order(created_at: :desc).first
      expect(shipment.metadata["backfilled_event_count"]).to eq(1)
      expect(shipment.metadata["backfill_task"]).to eq("IMP-592827c29ec4")
      expect(shipment.metadata["note"].to_s).to match(/overlap/i)
    end

    it "leaves the metadata clean for an ordinary shipment" do
      make_event(peer_id: peer.id, emitted_at: cutoff - 1.day)

      described_class.run!(account: account, now: now)

      shipment = ::System::FederationAuditShipment.order(created_at: :desc).first
      expect(shipment.metadata).not_to have_key("backfilled_event_count")
    end
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

    # IMP-79b5bb5fee24 cross-seam: every other example fabricates its
    # FleetEvents with the payload key this reader already queries, so
    # they exercise the reader against a synthetic writer and cannot see
    # a writer/reader key mismatch. This one drives the REAL writer —
    # System::ClusterMember::PgReplicaSetupService#emit_event! — and
    # asserts its pg_replica_ready event enters the sealed WORM archive.
    # The compliance contract (operator ruling): WORM sealing captures
    # ALL events referencing a federation peer regardless of kind.
    it "seals the pg_replica_ready event the cluster_member setup service emits" do
      member_peer = create(:system_federation_peer, :platform,
                           account: account,
                           spawn_mode: "cluster_member",
                           spawn_role: "parent",
                           status: "proposed",
                           remote_instance_url: "https://child.example.com")
      vault = instance_double(::Security::VaultCredentialProvider, store_credential: true)
      result = ::System::ClusterMember::PgReplicaSetupService.new(
        peer: member_peer,
        sql_executor: ->(_sql, _binds = []) { [] },
        vault: vault
      ).run!
      expect(result.ok?).to be(true)

      emitted = ::System::FleetEvent.where(
        account: account, kind: "platform.cluster_member.pg_replica_ready"
      ).last
      expect(emitted).to be_present,
                         "expected PgReplicaSetupService#run! to emit a pg_replica_ready FleetEvent"

      # Sweep from 31 days in the future so the just-emitted event is
      # older than the 30-day retention boundary.
      described_class.run!(account: account, now: ::Time.current + 31.days)

      emitted.reload
      expect(emitted.payload["worm_shipped_at"]).to be_present,
                                                    "pg_replica_ready event was not WORM-sealed — the writer stamps payload " \
                                                    "#{emitted.payload.keys.sort.inspect}, events_for_peer filters on federation_peer_id"
      shipment = ::System::FederationAuditShipment.where(federation_peer: member_peer).last
      expect(shipment).to be_present
      expect(emitted.payload["shipment_id"]).to eq(shipment.id)
    end
  end
end
