# frozen_string_literal: true

# P9.2 — Federation Audit Shipment ledger.
#
# Tracks WORM (write-once-read-many) shipments of per-peer audit log
# excerpts older than 30 days, per Architectural Fix 2 of the
# Decentralized Federation plan and Social Contract commitment #5.
#
# Each row records:
#   - account_id + federation_peer_id — who the audit relates to
#   - period (start..end) — what time window the shipment covers
#   - event_count — how many FleetEvent rows were in the batch
#   - sha256 — the seal's content-addressable hash
#   - sealed_path — where the JSON-Lines export lives (Vault path or
#     filesystem path; operator-configurable via env)
#   - status (pending|sealed|verified|failed) — lifecycle
#   - shipped_at — when WORM materialized
#
# After a successful WORM shipment, the source FleetEvent rows get
# `payload.worm_shipped_at` stamped (out-of-band note that they're
# now mirrored in WORM). The hot DB still keeps them for queryability
# until a separate retention sweep prunes anything past the configured
# hot-window (defaults to 90 days).
class CreateSystemFederationAuditShipments < ActiveRecord::Migration[8.1]
  def change
    create_table :system_federation_audit_shipments, id: :uuid do |t|
      t.references :account,          null: false, type: :uuid, foreign_key: { to_table: :accounts }
      t.references :federation_peer,  null: false, type: :uuid, foreign_key: { to_table: :system_federation_peers }

      t.datetime :period_start,  null: false
      t.datetime :period_end,    null: false

      t.integer  :event_count,   null: false, default: 0
      t.string   :sha256,        null: true,  limit: 64
      t.string   :sealed_path,   null: true,  limit: 512
      t.string   :status,        null: false, default: "pending", limit: 32

      t.datetime :shipped_at,    null: true
      t.string   :error_message, null: true

      t.jsonb    :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :system_federation_audit_shipments, %i[federation_peer_id period_start],
              name: "idx_audit_shipment_peer_period_start"
    add_check_constraint :system_federation_audit_shipments,
                         "period_end > period_start",
                         name: "audit_shipment_period_valid"
  end
end
