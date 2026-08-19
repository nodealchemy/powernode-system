# frozen_string_literal: true

# IMP-592827c29ec4 — make the peer-state events already on disk visible again.
#
# All four per-peer readers of this envelope match `payload->>'federation_peer_id'`:
# Ai::Tools::SdwanTool#get_audit_log, Federation::AuditShipmentService
# #events_for_peer (WORM sealing), FederationApi::AuditExcerptsController
# #events_for_peer, and the frontend PeerLivenessMonitor. Two emitters used to
# stamp `peer_id` instead:
#
#   * FederationPeer#broadcast_peer_state!            — fixed in 5bfdb206
#   * ClusterMember::PgReplicaSetupService#emit_event! — fixed in 80a8ec08
#
# Those fixes only changed what is written NEXT. Every row written before them
# is still on disk and still invisible to all four readers, so each peer's
# status history — including its revocation, the one transition an operator
# opens the log to explain — has a permanent gap. This closes it.
#
# SCOPE, and why it is drawn this way. Three independent conditions, each
# excluding something a different one would let through:
#
#   1. KIND. `peer_id` is not a reserved word: MembershipCredentialSigner emits
#      `sdwan.credential_refresh_failed` with an Sdwan::Peer id under the same
#      key, and that is a DIFFERENT MODEL. Only the two families above qualify.
#      (The direction asks whether pg_replica_ready joins the family: it does —
#      80a8ec08's own `@peer` is a System::FederationPeer.)
#   2. THE REFERENT EXISTS. Kind alone is a naming heuristic; this checks the
#      thing that actually matters, that the id names a real federation peer.
#      Copying an id that resolves to nothing would invent a reference and put
#      an unattributable row into a compliance export.
#   3. NO CANONICAL KEY ALREADY. `||` is RIGHT-BIASED, so on a row carrying both
#      keys the legacy value would overwrite the canonical one — silently
#      re-pointing an audit record at a different peer. This is the guard the
#      operator direction calls out by name.
#
# ADDITIVE ONLY: `peer_id` is kept. PeerLivenessMonitor still reads it as a
# fallback, and deleting the original of a record you are repairing is not a
# repair. Unrelated payload keys are untouched — `||` merges.
#
# The provenance stamp is not decoration. These rows are older than the sweep's
# 30-day boundary, so becoming visible means they ship NOW, in periods derived
# from their own timestamps (AuditShipmentService#ship_for_peer!), which will
# OVERLAP shipments already sealed for the same peer. Nothing raises — the only
# constraint is period_end > period_start. Per the operator direction the
# overlap is accepted and EXPLAINED rather than hidden: the stamp is what
# AuditShipmentService reads to record on the shipment why its period overlaps.
#
# Data-only, no DDL. Idempotent: a repaired row gains federation_peer_id and so
# fails condition 3 on any later run.
class BackfillFederationPeerIdOnFleetEvents < ActiveRecord::Migration[8.1]
  BACKFILL_TASK  = "IMP-592827c29ec4"
  PG_REPLICA_KIND = "platform.cluster_member.pg_replica_ready"
  BATCH_SIZE     = 1_000

  # Local model: a migration must not depend on an app model whose validations,
  # callbacks and columns drift out from under it.
  class FleetEventRow < ActiveRecord::Base
    self.table_name = "system_fleet_events"
  end

  def up
    stamped_at = Time.current.utc.iso8601
    total = 0

    backfillable.in_batches(of: BATCH_SIZE) do |batch|
      total += batch.update_all(merge_sql(stamped_at))
    end

    say "backfilled federation_peer_id onto #{total} legacy peer-state fleet event(s)"
    say "these rows are past the 30-day WORM boundary and will ship in periods that " \
        "overlap already-sealed ones; each carries payload.payload_key_backfilled_at " \
        "and its shipment records the reason" if total.positive?
  end

  def down
    # Deliberately not reversible. Removing the canonical key would restore the
    # audit gap this exists to close, and the legacy key it was copied from is
    # still present, so nothing was destroyed to restore.
  end

  private

  # jsonb_exists(payload, 'k') rather than `payload ? 'k'`: the jsonb existence
  # operator is also ActiveRecord's bind placeholder, so the literal form gets
  # eaten by the sanitizer. Same operator, same semantics, no escaping.
  def backfillable
    FleetEventRow
      .where("kind LIKE 'federation.peer.%' OR kind = ?", PG_REPLICA_KIND)
      .where("jsonb_exists(payload, 'peer_id')")
      .where("NOT jsonb_exists(payload, 'federation_peer_id')")
      .where(
        "EXISTS (SELECT 1 FROM system_federation_peers p WHERE p.id::text = payload->>'peer_id')"
      )
  end

  # Compared as TEXT, not cast to uuid: a legacy row whose peer_id is not a
  # valid uuid would make the cast raise and take the whole migration with it.
  def merge_sql(stamped_at)
    ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        payload = payload || jsonb_build_object(
          'federation_peer_id',        payload->>'peer_id',
          'payload_key_backfilled_at', ?::text,
          'payload_key_backfill_task', ?::text
        )
      SQL
      stamped_at, BACKFILL_TASK
    ])
  end
end
