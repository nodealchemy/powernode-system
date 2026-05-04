# frozen_string_literal: true

# Per-account SDWAN configuration row. Persists the deterministic IPv6 ULA
# anchors used by Sdwan::PrefixAllocator: a per-install /40 root and a
# per-account /48 carved from it. Storing both makes future re-derivation
# stable across deploys and gives the federation overlap-check a single
# place to read from.
#
# Slice 1 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
class CreateSdwanConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_configurations, id: :uuid do |t|
      t.references :account, null: false, type: :uuid,
                   foreign_key: true, index: { unique: true }

      # The /40 root is shared across every account on this Powernode install.
      # Generated once on first allocation and never rewritten — the persistence
      # contract is the whole point of this row. Stored as a string so we can
      # validate format without bringing in an inet/cidr cast at this layer.
      t.string :instance_prefix_40, null: false

      # Per-account /48 carved from the instance /40 by 8-bit hash + rejection
      # sampling against the Sdwan::Configuration table. Stable for the life
      # of the account.
      t.string :account_prefix_48, null: false

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_configurations, :account_prefix_48, unique: true
    add_index :sdwan_configurations, :instance_prefix_40
  end
end
