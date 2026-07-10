# frozen_string_literal: true

# Increment 21 (campaign 019f3458) — one per-instance Gitea deploy key per
# dev-cell NodeInstance. The Ed25519 keypair is generated in-service; the
# PRIVATE half lives ONLY in Vault (mirrors System::ClaudeCodeCredential /
# System::AcmeDnsCredential — no encrypted_credentials column, so a Vault
# outage fails closed instead of ever landing the private key in Postgres).
# The public (non-secret) columns are kept for idempotent rotate-on-bootstrap
# and remote-key revocation: `deploy_key_id` is the Gitea key id to delete,
# `source_repo` the "owner/repo" it was registered on, `public_key_openssh`
# the registered "ssh-ed25519 AAAA..." line, `fingerprint` its SHA256.
class CreateSystemDevCellDeployKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :system_dev_cell_deploy_keys, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :node_instance_id, null: false
      t.string :vault_path_credentials
      t.datetime :migrated_to_vault_at

      t.string :algorithm
      t.text :public_key_openssh
      t.string :fingerprint
      t.bigint :deploy_key_id
      t.string :source_repo
      t.string :title

      t.timestamps
    end

    add_index :system_dev_cell_deploy_keys, :node_instance_id, unique: true
  end
end
