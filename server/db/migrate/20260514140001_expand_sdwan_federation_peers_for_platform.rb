# frozen_string_literal: true

# P3.1 — Promote Sdwan::FederationPeer from v1 data-plane-only scaffold
# to the symmetric control-plane peer record described in the
# Decentralized Federation plan §C.
#
# Adds (additive only — no rename in this migration; namespace rename
# from Sdwan::FederationPeer → System::FederationPeer is the P3.9
# follow-up that touches ~10 consumer files):
#
#   - peer_kind            "platform" | "sdwan_only" (backfilled to sdwan_only)
#   - spawn_mode           managed_child | autonomous_peer | cluster_member | out_of_band
#   - spawn_role           parent | child | symmetric (nil for out_of_band)
#   - parent_peer_id       self-FK; non-nil for spawned-child rows
#   - contract_version_agreed   integer; mutual social-contract version
#   - endpoints_jsonb      priority-ordered LAN→SDWAN→WAN dial map (Plan §J)
#   - last_heartbeat_at, last_handshake_at, last_capability_sync_at
#   - extension_slugs_jsonb   which extensions this peer hosts
#   - node_certificate_id  FK to system_node_certificates (subject_kind="federation_peer")
#   - capabilities_jsonb   forward-compat for P4 (per-pair capability snapshot)
#   - sync_cursor_jsonb    forward-compat for P4 (per-table sync cursor)
#
# Plan reference: Decentralized Federation §C + P3.1.
class ExpandSdwanFederationPeersForPlatform < ActiveRecord::Migration[8.0]
  def change
    change_table :sdwan_federation_peers do |t|
      t.string  :peer_kind,    null: false, default: "sdwan_only", limit: 32
      t.string  :spawn_mode,   limit: 32
      t.string  :spawn_role,   limit: 16
      t.integer :contract_version_agreed
      t.jsonb   :endpoints,         null: false, default: []
      t.jsonb   :extension_slugs,   null: false, default: []
      t.jsonb   :capabilities,      null: false, default: {}
      t.jsonb   :sync_cursor,       null: false, default: {}
      t.datetime :last_heartbeat_at
      t.datetime :last_handshake_at
      t.datetime :last_capability_sync_at

      # parent_peer_id is a SELF-FK — for spawned children pointing at
      # the parent peer record they enrolled against.
      t.references :parent_peer,
        type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_federation_peers, on_delete: :nullify }

      # mTLS cert minted for THIS peer (subject_kind="federation_peer").
      t.references :node_certificate,
        type: :uuid, null: true,
        foreign_key: { to_table: :system_node_certificates, on_delete: :nullify }
    end

    add_index :sdwan_federation_peers, :peer_kind
    add_index :sdwan_federation_peers, %i[peer_kind status],
      name: "idx_federation_peers_kind_status"
    add_index :sdwan_federation_peers, :last_heartbeat_at,
      where: "peer_kind = 'platform'",
      name: "idx_federation_peers_platform_heartbeat"

    add_check_constraint :sdwan_federation_peers,
      "peer_kind IN ('platform', 'sdwan_only')",
      name: "federation_peers_peer_kind_enum"

    # Backfill existing rows as sdwan_only (data-plane only). This is the
    # default but stating it explicitly handles any rows that bypassed the
    # default (e.g., bulk inserts).
    reversible do |dir|
      dir.up do
        execute "UPDATE sdwan_federation_peers SET peer_kind = 'sdwan_only' WHERE peer_kind IS NULL"
      end
    end
  end
end
