# frozen_string_literal: true

# Golden Eclipse M0.L — foundational tables for the modernized bootstrap stack.
#
# - system_bootstrap_tokens : single-use enrollment tokens (mTLS bootstrap)
# - system_node_certificates : issued mTLS certs for NodeInstances (Vault-backed pem_chain)
# - system_module_artifacts  : OCI-stored module artifacts (multi-arch + provenance)
#
# References:
# - Plan: ~/.claude/plans/we-are-working-on-golden-eclipse.md (Migration Inventory + Data Model Deltas)
# - Memory: project_credential_pattern.md (VaultCredential concern, vault_credential_type = node_pki)
class CreateBootstrapTokensNodeCertificatesModuleArtifacts < ActiveRecord::Migration[8.0]
  def change
    # ---------- Bootstrap tokens ----------
    create_table :system_bootstrap_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string  :token_hash, null: false                # SHA-256 of plaintext token
      t.references :node, type: :uuid, null: false,
                   foreign_key: { to_table: :system_nodes }
      t.references :node_instance, type: :uuid, null: true,
                   foreign_key: { to_table: :system_node_instances }
      t.string  :intended_subject, null: false           # CN the issued cert must carry
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.string  :consumed_from_ip
      t.boolean :single_use, null: false, default: true
      t.text    :purpose                                  # human-readable ("first boot", "rotate")
      t.timestamps
    end
    add_index :system_bootstrap_tokens, :token_hash, unique: true
    add_index :system_bootstrap_tokens, :expires_at
    add_index :system_bootstrap_tokens, :consumed_at

    # ---------- Node certificates ----------
    create_table :system_node_certificates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :node_instance, type: :uuid, null: false,
                   foreign_key: { to_table: :system_node_instances }
      t.string  :serial, null: false                     # cert serial number (hex)
      t.string  :subject, null: false                    # full CN/DN
      t.datetime :not_before, null: false
      t.datetime :not_after, null: false
      t.text    :pem_chain                                # encrypted via VaultCredential concern;
                                                          # falls back to encrypted DB col if Vault offline
      t.string  :vault_path                               # set when stored in Vault
      t.datetime :migrated_to_vault_at
      t.uuid    :encryption_key_id                        # rotation tracking
      t.text    :encrypted_credentials                    # alt path used by VaultCredential concern
      t.datetime :revoked_at
      t.string  :revocation_reason
      t.string  :issuer_subject                           # which CA signed this cert
      t.timestamps
    end
    add_index :system_node_certificates, :serial, unique: true
    add_index :system_node_certificates, :subject
    add_index :system_node_certificates, :not_after
    add_index :system_node_certificates, :revoked_at

    # ---------- Module artifacts ----------
    create_table :system_module_artifacts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :node_module_version, type: :uuid, null: false,
                   foreign_key: { to_table: :system_node_module_versions }
      t.string  :oci_ref, null: false                     # registry/path:tag
      t.string  :oci_digest, null: false                  # sha256:abc...
      t.string  :media_type, null: false                  # application/vnd.powernode.module.v1
      t.string  :architecture, null: false                # amd64 | arm64 | ...
      t.bigint  :size_bytes, null: false, default: 0
      t.string  :fsverity_root_hash                       # SHA-256 hex; fs-verity Merkle root
      t.text    :cosign_bundle                            # cosign --bundle output (signature + cert)
      t.string  :sbom_uri                                 # SBOM (CycloneDX) blob URI
      t.string  :provenance_uri                           # SLSA provenance attestation URI
      t.string  :vex_uri                                  # VEX vulnerability statement URI
      t.datetime :built_at, null: false
      t.timestamps
    end
    add_index :system_module_artifacts,
              [:node_module_version_id, :architecture],
              unique: true,
              name: "idx_uniq_system_module_artifacts_version_arch"
    add_index :system_module_artifacts, :oci_digest
    add_index :system_module_artifacts, :architecture
  end
end
