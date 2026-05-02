# frozen_string_literal: true

# Golden Eclipse M0.M — extend NodeModuleVersion + NodeInstance + Node with
# runtime tracking, provenance metadata, and bootstrap-flow scaffolding.
#
# NodeModuleVersion gets OCI/SLSA fields + promotion lifecycle columns.
# NodeInstance gets agent runtime telemetry + mTLS identity columns.
# Node gets an internal_ca_id pointer (multi-tenant CA support hook).
class AddRuntimeAndProvenanceFieldsToSystemModels < ActiveRecord::Migration[8.0]
  PROMOTION_STATES = %w[built staging blessed live retired].freeze

  def change
    # ---------- NodeModuleVersion ----------
    change_table :system_node_module_versions, bulk: true do |t|
      # OCI artifact provenance (denormalized convenience — full detail lives
      # in system_module_artifacts; these fields satisfy the hot path).
      t.string :oci_digest
      t.string :fsverity_root_hash
      t.string :sbom_uri
      t.string :provenance_uri
      t.string :vex_uri

      # Promotion lifecycle (AASM in a follow-up; column-only for now)
      t.string  :promotion_state, null: false, default: "built"
      t.datetime :staging_baked_at
      t.datetime :blessed_at
      t.datetime :live_at
      t.datetime :retired_at
    end
    add_index :system_node_module_versions, :oci_digest
    add_index :system_node_module_versions, :promotion_state
    add_check_constraint :system_node_module_versions,
                         "promotion_state IN ('built','staging','blessed','live','retired')",
                         name: "system_node_module_versions_promotion_state_check"

    # ---------- NodeInstance ----------
    change_table :system_node_instances, bulk: true do |t|
      t.string  :agent_version                              # ipn-agent version reported via heartbeat
      t.datetime :last_heartbeat_at
      t.string  :boot_id                                    # uniquely identifies the current boot
      t.string  :architecture, default: "amd64", null: false
      t.string  :mtls_subject                               # CN derived from issued cert
      t.references :enrollment_token, type: :uuid,
                   foreign_key: { to_table: :system_bootstrap_tokens }
      t.jsonb   :running_module_digests, null: false, default: {}
                                                            # { module_id => oci_digest } reported by agent
    end
    add_index :system_node_instances, :last_heartbeat_at
    add_index :system_node_instances, :architecture
    add_index :system_node_instances, :mtls_subject
    add_index :system_node_instances, :running_module_digests, using: :gin
    add_check_constraint :system_node_instances,
                         "architecture IN ('amd64','arm64')",
                         name: "system_node_instances_architecture_check"

    # ---------- Node ----------
    # internal_ca_id is a forward-compat hook for multi-tenant CA support
    # (each account or node-class can pin a different CA). Nullable for now;
    # downstream (M0.N) wires NodeCertificate.issuer_subject against this.
    change_table :system_nodes, bulk: true do |t|
      t.uuid :internal_ca_id                                # FK target deferred to M0.N
    end
    add_index :system_nodes, :internal_ca_id
  end
end
