# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260819140000_backfill_federation_peer_id_on_fleet_events.rb"
)

# IMP-592827c29ec4 — the rename fixed NEW events; these are the old ones.
#
# Two emitters historically stamped `peer_id` with a System::FederationPeer id:
# FederationPeer#broadcast_peer_state! (fixed in 5bfdb206) and
# ClusterMember::PgReplicaSetupService#emit_event! (fixed in 80a8ec08 —
# IMP-79b5bb5fee24, which this task's direction asks about by name; its @peer IS
# a FederationPeer, so it belongs to the same family). All four per-peer readers
# match `payload->>'federation_peer_id'`, so every row those two wrote before
# the rename is permanently invisible to the audit log, the WORM sweep and the
# federation audit-excerpts API.
#
# The rows that must NOT be touched are the ones where `peer_id` means a
# DIFFERENT model: Sdwan::Peer, e.g. MembershipCredentialSigner's
# `sdwan.credential_refresh_failed`.
RSpec.describe BackfillFederationPeerIdOnFleetEvents do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:peer) do
    ::System::FederationPeer.create!(
      account: account, remote_instance_url: "https://p-#{SecureRandom.hex(4)}.example.com",
      peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band", status: "active"
    )
  end

  def legacy_event(kind:, payload:)
    ::System::FleetEvent.create!(
      account: account, kind: kind, severity: "low", source: "spec",
      emitted_at: 40.days.ago, payload: payload
    )
  end

  describe "rows it repairs" do
    # Every kind broadcast_peer_state! can emit: "heartbeat" plus one per
    # FederationPeer::STATUSES entry (broadcast_status_transition! passes the
    # new status as the kind).
    (%w[heartbeat] + ::System::FederationPeer::STATUSES).each do |kind|
      it "makes a federation.peer.#{kind} event visible to the per-peer readers" do
        ev = legacy_event(kind: "federation.peer.#{kind}", payload: { "peer_id" => peer.id })

        migration.up

        expect(ev.reload.payload["federation_peer_id"]).to eq(peer.id)
      end
    end

    it "repairs the pg_replica_ready event from the sibling emitter" do
      ev = legacy_event(kind: "platform.cluster_member.pg_replica_ready",
                        payload: { "peer_id" => peer.id, "slot" => "s1" })

      migration.up

      expect(ev.reload.payload["federation_peer_id"]).to eq(peer.id)
    end

    it "keeps the legacy key — the frontend still reads it as a fallback" do
      ev = legacy_event(kind: "federation.peer.revoked",
                        payload: { "peer_id" => peer.id, "reason" => "key compromised" })

      migration.up

      payload = ev.reload.payload
      expect(payload["peer_id"]).to eq(peer.id)
      expect(payload["reason"]).to eq("key compromised"), "the backfill clobbered unrelated payload keys"
    end

    it "stamps provenance so a later shipment can explain its overlapping period" do
      ev = legacy_event(kind: "federation.peer.active", payload: { "peer_id" => peer.id })

      migration.up

      expect(ev.reload.payload["payload_key_backfilled_at"]).to be_present
    end
  end

  describe "rows it must leave alone" do
    # The peer_id here is a real FederationPeer id, so ONLY the kind filter
    # keeps this row out. Sdwan::Peer events legitimately use peer_id for a
    # different model.
    it "does not touch an sdwan.* event even when its peer_id resolves to a federation peer" do
      ev = legacy_event(kind: "sdwan.credential_refresh_failed", payload: { "peer_id" => peer.id })

      migration.up

      expect(ev.reload.payload).not_to have_key("federation_peer_id")
    end

    # Right-biased `||`: without the NOT-exists guard, the legacy value would
    # overwrite the canonical one on a row carrying both.
    it "never lets a legacy peer_id overwrite an existing federation_peer_id" do
      other = ::System::FederationPeer.create!(
        account: account, remote_instance_url: "https://q-#{SecureRandom.hex(4)}.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band", status: "active"
      )
      ev = legacy_event(kind: "federation.peer.degraded",
                        payload: { "peer_id" => other.id, "federation_peer_id" => peer.id })

      migration.up

      expect(ev.reload.payload["federation_peer_id"]).to eq(peer.id)
    end

    # Only the referent check keeps this out: right kind, but the id belongs to
    # no federation peer, so copying it would invent a reference.
    it "does not copy a peer_id that resolves to no federation peer" do
      ev = legacy_event(kind: "federation.peer.active", payload: { "peer_id" => SecureRandom.uuid })

      migration.up

      expect(ev.reload.payload).not_to have_key("federation_peer_id")
    end
  end

  it "is idempotent — a second run changes nothing" do
    ev = legacy_event(kind: "federation.peer.enrolled", payload: { "peer_id" => peer.id })
    migration.up
    first = ev.reload.payload["payload_key_backfilled_at"]

    migration.up

    expect(ev.reload.payload["payload_key_backfilled_at"]).to eq(first)
  end
end
