# frozen_string_literal: true

# Sdwan::AccountBgp — one row per account that opts into iBGP. Owns the
# private AS number (RFC 6996 4-byte private range 4200000000-4294967294)
# and the router-id derivation strategy. The model exists separately from
# Sdwan::Network because an account's AS is shared across all of its
# iBGP networks (same AS, multiple networks = multiple iBGP fabrics).
#
# Slice 9c of the SDWAN plan.
class CreateSdwanAccountBgps < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_account_bgps, id: :uuid do |t|
      t.references :account, null: false, type: :uuid,
                   foreign_key: true, index: { unique: true }

      # 4-byte private AS — fits a bigint comfortably (range up to 4.29B).
      t.bigint :as_number, null: false

      t.string :router_id_strategy, null: false, default: "peer_overlay_ipv6_hash"

      t.references :default_route_policy, type: :uuid, foreign_key: false
      t.integer :default_local_pref, null: false, default: 100

      t.boolean :enabled, null: false, default: true
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_account_bgps, :as_number, unique: true
    add_check_constraint :sdwan_account_bgps,
                         "as_number >= 4200000000 AND as_number <= 4294967294",
                         name: "sdwan_account_bgps_rfc6996_private"
  end
end
