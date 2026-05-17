# frozen_string_literal: true

# P9.3 — Records each peer's reported platform_version + bootstraps
# the schema compatibility matrix that pairs of peers consult during
# heartbeat to determine which capabilities can flow.
#
# Plan reference:
#   - Decentralized Federation Social Contract #10 ("Backwards compat
#     window — N-1 federation compatibility").
#   - Architectural Fix 1 motivated FederationManager AI to flag
#     version drift; this is the data the AI needs to make that call.
class AddSchemaVersionToFederationPeers < ActiveRecord::Migration[8.1]
  def change
    add_column :system_federation_peers, :platform_version, :string, limit: 64, null: true
    add_index  :system_federation_peers, :platform_version, name: "idx_federation_peers_platform_version"

    create_table :system_federation_schema_compatibility, id: :uuid do |t|
      t.references :account, null: true, type: :uuid, foreign_key: { to_table: :accounts }

      t.string  :local_version,  null: false, limit: 64
      t.string  :remote_version, null: false, limit: 64
      t.string  :status,         null: false, limit: 32, default: "compatible"
      t.string  :notes,          null: true,  limit: 1024
      # Operator/AI can override the default N-1 rule for specific
      # pairs (e.g. "0.3.1 ↔ 0.4.0 incompatible because of a breaking
      # FederationGrant scope change"). When source = "default" the row
      # was inserted by the seed bootstrap; "operator" rows take
      # precedence.
      t.string  :source,         null: false, limit: 32, default: "default"
      t.timestamps
    end

    add_index :system_federation_schema_compatibility,
              %i[local_version remote_version],
              unique: true,
              name: "idx_schema_compat_pair_unique"
    add_index :system_federation_schema_compatibility, :status,
              name: "idx_schema_compat_status"
  end
end
