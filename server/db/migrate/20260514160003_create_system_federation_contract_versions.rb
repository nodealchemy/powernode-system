# frozen_string_literal: true

# P4.3 — Versioned social contract. The text of the 12-commitment
# operator agreement is stored verbatim per version so federation
# peers can handshake on the version they agreed to and the platform
# can prove (years later) what the operator acknowledged at signup.
#
# Plan reference: Decentralized Federation §"Social Contracts" + P4.3.
class CreateSystemFederationContractVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_contract_versions, id: :uuid do |t|
      t.integer  :version,         null: false
      t.text     :contract_text,   null: false
      t.string   :contract_digest, null: false, limit: 64  # sha256 hex
      t.date     :effective_at,    null: false
      t.date     :deprecated_at
      t.jsonb    :metadata,        null: false, default: {}

      t.timestamps
    end

    add_index :system_federation_contract_versions, :version, unique: true
    add_index :system_federation_contract_versions, :contract_digest, unique: true
    add_index :system_federation_contract_versions, :deprecated_at,
      where: "deprecated_at IS NOT NULL"
  end
end
