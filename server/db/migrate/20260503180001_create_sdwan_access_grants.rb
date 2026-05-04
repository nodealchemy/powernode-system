# frozen_string_literal: true

# Sdwan::AccessGrant — a user's permission to attach VPN clients to one
# SDWAN network. Without an active grant a user cannot own UserDevice
# rows on that network; revoking the grant cascades device revocation
# (compiler-driven, soft revoke — vault entries linger for 90-day audit
# retention).
#
# Slice 4 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
class CreateSdwanAccessGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_access_grants, id: :uuid do |t|
      t.references :sdwan_network,  null: false, type: :uuid, foreign_key: true
      t.references :user,           null: false, type: :uuid, foreign_key: true
      t.references :account,        null: false, type: :uuid, foreign_key: true
      t.references :granted_by,     null: true,  type: :uuid,
                   foreign_key: { to_table: :users }

      # active → suspended (operator-paused) → revoked (terminal).
      # Suspended grants block new device issuance + bootstrap downloads
      # but keep existing devices working (so an operator can reverse
      # the suspension without re-issuing every device).
      t.string :status, default: "active", null: false

      t.string :tags, array: true, default: []

      t.datetime :granted_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :revoked_at
      t.string   :revocation_reason

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # A user has at most one grant per network. New grants for an existing
    # (user, network) pair must explicitly reactivate the prior row.
    add_index :sdwan_access_grants, %i[sdwan_network_id user_id], unique: true
    add_index :sdwan_access_grants, :status
  end
end
