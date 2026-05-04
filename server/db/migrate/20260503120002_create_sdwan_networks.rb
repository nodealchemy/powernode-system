# frozen_string_literal: true

# Account-scoped SDWAN overlay network. Each network owns a deterministic
# /64 carved from its account's /48 (see Sdwan::PrefixAllocator). Members
# join via Sdwan::Peer. Topology compilation flows through the pluggable
# Sdwan::TopologyCompiler — the network row carries no edge data, only
# membership shape.
#
# Slice 1 of the SDWAN plan.
class CreateSdwanNetworks < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_networks, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description

      # The carved /64. Persisted (not derived on each read) so a future
      # rename of the network's id-derived path can't silently re-assign.
      t.string :cidr_64, null: false

      # registered → active is the normal path; suspended is operator-driven;
      # archived stops compilation (peers are kept for audit but not pushed).
      t.string :status, default: "registered", null: false

      # Per-network knobs the compiler reads. Not exposed as columns because
      # the set is intentionally extensible (mtu, listen_port_default,
      # persistent_keepalive, allowed_ip_overrides …).
      t.jsonb :settings, default: {}, null: false
      t.string :tags, array: true, default: []
      t.jsonb :metadata, default: {}, null: false

      t.datetime :last_compiled_at

      t.timestamps
    end

    add_index :sdwan_networks, [:account_id, :name], unique: true
    add_index :sdwan_networks, [:account_id, :slug], unique: true
    add_index :sdwan_networks, :cidr_64, unique: true
    add_index :sdwan_networks, :status
  end
end
