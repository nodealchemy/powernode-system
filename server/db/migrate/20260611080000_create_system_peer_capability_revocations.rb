# frozen_string_literal: true

# Audit F2-04 — A2A capability tokens are verified OFFLINE by the on-node
# agent, so revoking a peer's grant (or disabling the peer) did not
# invalidate outstanding tokens. This table is the revocation channel: rows
# are published when a peer is disabled or its grants change, advertised to
# agents alongside capability_keys, and expire after the maximum token TTL
# (no token minted before the revocation can outlive it).
class CreateSystemPeerCapabilityRevocations < ActiveRecord::Migration[8.1]
  def change
    create_table :system_peer_capability_revocations, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Token claim being revoked: `sub` (the caller NodeInstance id) for
      # peer-wide revocations; `jti` reserved for single-token revocation.
      t.string :sub
      t.string :jti
      t.string :reason

      # Advertisement cutoff — now + MAX_TTL_SECONDS at publish time. Rows
      # past this are inert (every token they could cover has expired).
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :system_peer_capability_revocations, %i[account_id expires_at]
  end
end
