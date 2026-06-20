# frozen_string_literal: true
class SystemBaseline < ActiveRecord::Migration[8.1]
  def change
  # These are extensions that must be enabled in order to support this database

  create_table "system_acme_certificates", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "challenge_type", limit: 16, default: "dns-01", null: false
    t.string "common_name", limit: 255, null: false
    t.datetime "created_at", null: false
    t.uuid "dns_credential_id"
    t.datetime "expires_at"
    t.datetime "issued_at"
    t.string "issuer", limit: 64, default: "letsencrypt-prod", null: false
    t.datetime "last_renewal_attempt_at"
    t.text "last_renewal_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.datetime "revoked_at"
    t.jsonb "sans", default: [], null: false
    t.string "status", limit: 32, default: "pending", null: false
    t.string "traefik_resolver_name"
    t.datetime "updated_at", null: false
    t.string "vault_path_account_key"
    t.string "vault_path_certificate"
    t.string "vault_path_chain"
    t.string "vault_path_private_key"
    t.index ["account_id", "common_name"], name: "idx_acme_certs_acct_cn_unique_active", unique: true, where: "((status)::text <> 'revoked'::text)"
    t.index ["account_id"]
    t.index ["dns_credential_id"]
    t.index ["expires_at"]
    t.index ["issuer"]
    t.index ["migrated_to_vault_at"], name: "index_acme_certificates_on_migrated_to_vault_at", where: "(migrated_to_vault_at IS NOT NULL)"
    t.index ["revoked_at"]
    t.index ["status"]
  end

  create_table "system_acme_dns_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_validated_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.string "name", limit: 255, null: false
    t.string "provider", limit: 64, null: false
    t.string "status", limit: 32, default: "untested", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path_credentials"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["migrated_to_vault_at"], name: "index_acme_dns_credentials_on_migrated_to_vault_at", where: "(migrated_to_vault_at IS NOT NULL)"
    t.index ["provider"]
    t.index ["status"]
  end

  create_table "system_bootstrap_tokens", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "consumed_at"
    t.string "consumed_from_ip"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "intended_subject", null: false
    t.uuid "node_id", null: false
    t.uuid "node_instance_id"
    t.text "purpose"
    t.boolean "single_use", default: true, null: false
    t.string "token_hash", null: false
    t.datetime "updated_at", null: false
    t.index ["consumed_at"]
    t.index ["expires_at"]
    t.index ["node_id"]
    t.index ["node_instance_id"]
    t.index ["token_hash"], unique: true
  end

  create_table "system_cve_exposures", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "cve_id", null: false
    t.datetime "detected_at", default: -> { "now()" }, null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "node_module_version_id", null: false
    t.string "package_name", null: false
    t.string "package_version"
    t.string "resolution_note"
    t.datetime "resolved_at"
    t.string "state", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["cve_id", "node_module_version_id", "package_name"], unique: true
    t.index ["cve_id"]
    t.index ["detected_at"]
    t.index ["node_module_version_id"]
    t.index ["state"]
    t.check_constraint "state::text = ANY (ARRAY['open'::character varying::text, 'remediating'::character varying::text, 'resolved'::character varying::text, 'wont_fix'::character varying::text])", name: "ck_cve_exposures_state"
  end

  create_table "system_cves", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "affected_packages", default: [], null: false
    t.datetime "created_at", null: false
    t.string "cve_id", null: false
    t.string "feed_source"
    t.datetime "ingested_at", default: -> { "now()" }
    t.jsonb "metadata", default: {}, null: false
    t.datetime "published_at"
    t.string "reference_url"
    t.string "severity", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.index ["affected_packages"], name: "index_system_cves_on_affected_packages", using: :gin
    t.index ["cve_id"], unique: true
    t.index ["ingested_at"]
    t.index ["published_at"]
    t.index ["severity"]
    t.check_constraint "severity::text = ANY (ARRAY['critical'::character varying::text, 'high'::character varying::text, 'medium'::character varying::text, 'low'::character varying::text, 'unknown'::character varying::text])", name: "ck_cves_severity"
  end

  create_table "system_disk_image_publications", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "arch", null: false
    t.integer "attempt_count", default: 1, null: false
    t.text "attestation_bundle", comment: "cosign attest-blob bundle over the publication payload predicate"
    t.text "cosign_bundle", comment: "cosign sign-blob bundle over the .img bytes"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.uuid "file_object_id"
    t.string "firmware_ref", comment: "rpi4-firmware module ref pinned at build time"
    t.string "git_sha", null: false
    t.uuid "node_platform_id", null: false
    t.string "oci_ref", comment: "Source OCI artifact ref (null for direct-upload mode)"
    t.jsonb "payload", default: {}, null: false
    t.uuid "prior_file_object_id"
    t.datetime "published_at"
    t.datetime "purged_at"
    t.datetime "retired_at"
    t.string "sha256", null: false
    t.bigint "size_bytes", null: false
    t.string "status", default: "queued", null: false, comment: "queued|awaiting_upload|verifying|published|failed|retired|purged"
    t.uuid "triggered_by_worker_id"
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.uuid "webhook_id"
    t.index ["account_id"]
    t.index ["file_object_id"]
    t.index ["node_platform_id", "created_at"], order: { created_at: :desc }
    t.index ["node_platform_id", "git_sha"], unique: true
    t.index ["node_platform_id", "status"]
    t.index ["node_platform_id"]
    t.index ["prior_file_object_id"]
    t.index ["status"]
    t.index ["triggered_by_worker_id"]
    t.index ["webhook_id"]
  end

  create_table "system_disk_image_webhooks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false, comment: "Operator-chosen identifier (e.g. 'main-ci', 'release-pipeline')"
    t.datetime "last_received_at"
    t.datetime "last_rotated_at"
    t.integer "received_count", default: 0, null: false
    t.text "secret", null: false, comment: "HMAC secret for X-Powernode-Signature verification. Encrypted at rest via `encrypts :secret`. Plaintext shown to operator exactly once at create/rotate."
    t.string "secret_preview", null: false, comment: "First 8 chars of the secret for operator UI disambiguation (so they can identify which secret is which without seeing the full value)."
    t.string "status", default: "active", null: false, comment: "active|disabled|revoked"
    t.datetime "updated_at", null: false
    t.index ["account_id", "label"], unique: true
    t.index ["account_id"]
    t.index ["created_by_id"]
    t.index ["status"]
  end

  create_table "system_federation_audit_shipments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "error_message"
    t.integer "event_count", default: 0, null: false
    t.uuid "federation_peer_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "period_end", null: false
    t.datetime "period_start", null: false
    t.string "sealed_path", limit: 512
    t.string "sha256", limit: 64
    t.datetime "shipped_at"
    t.string "status", limit: 32, default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["federation_peer_id", "period_start"]
    t.index ["federation_peer_id"]
    t.check_constraint "period_end > period_start", name: "audit_shipment_period_valid"
  end

  create_table "system_federation_capabilities", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "conflict_resolution", limit: 48, default: "newer_wins_logical_clock", null: false
    t.datetime "created_at", null: false
    t.string "direction", limit: 32, null: false
    t.uuid "federation_peer_id", null: false
    t.jsonb "filter", default: {}, null: false
    t.datetime "last_synced_at"
    t.string "policy", limit: 32, default: "manual", null: false
    t.string "resource_kind", limit: 64, null: false
    t.jsonb "sync_cursor", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "resource_kind"]
    t.index ["federation_peer_id", "resource_kind", "direction"], unique: true
    t.index ["policy"]
    t.check_constraint "conflict_resolution::text = ANY (ARRAY['newer_wins_logical_clock'::character varying::text, 'local_wins'::character varying::text, 'remote_wins'::character varying::text, 'prompt'::character varying::text])", name: "federation_capabilities_conflict_resolution_enum"
    t.check_constraint "direction::text = ANY (ARRAY['push_local_to_remote'::character varying::text, 'pull_remote_to_local'::character varying::text, 'bidirectional'::character varying::text, 'migration_only'::character varying::text])", name: "federation_capabilities_direction_enum"
    t.check_constraint "policy::text = ANY (ARRAY['manual'::character varying::text, 'auto_on_change'::character varying::text, 'auto_periodic'::character varying::text, 'on_match_filter'::character varying::text])", name: "federation_capabilities_policy_enum"
  end

  create_table "system_federation_contract_versions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "contract_digest", limit: 64, null: false
    t.text "contract_text", null: false
    t.datetime "created_at", null: false
    t.date "deprecated_at"
    t.date "effective_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["contract_digest"], unique: true
    t.index ["deprecated_at"], name: "index_system_federation_contract_versions_on_deprecated_at", where: "(deprecated_at IS NOT NULL)"
    t.index ["version"], unique: true
  end

  create_table "system_federation_grants", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.uuid "federation_peer_id", null: false
    t.uuid "grantor_user_id"
    t.datetime "issued_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "node_instance_ids", default: [], null: false
    t.jsonb "permission_scopes", default: [], null: false
    t.string "remote_subject", limit: 256, null: false
    t.uuid "resource_id"
    t.string "resource_kind", limit: 64, null: false
    t.string "revocation_reason", limit: 256
    t.datetime "revoked_at"
    t.jsonb "sdwan_network_ids", default: [], null: false
    t.jsonb "source_cidrs", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "expires_at"], name: "idx_fed_grants_account_expiring", where: "((revoked_at IS NULL) AND (archived_at IS NULL))"
    t.index ["account_id", "revoked_at"], name: "idx_fed_grants_account_revoked", where: "(archived_at IS NULL)"
    t.index ["account_id"]
    t.index ["federation_peer_id", "remote_subject", "resource_kind", "resource_id"], name: "idx_fed_grants_specific_resource_unique", unique: true, where: "(resource_id IS NOT NULL)"
    t.index ["federation_peer_id", "remote_subject", "resource_kind"], name: "idx_fed_grants_kind_wide_unique", unique: true, where: "(resource_id IS NULL)"
    t.index ["federation_peer_id"]
    t.index ["grantor_user_id"]
    t.index ["node_instance_ids"], name: "index_system_federation_grants_on_node_instance_ids", using: :gin
    t.index ["sdwan_network_ids"], name: "index_system_federation_grants_on_sdwan_network_ids", using: :gin
  end

  create_table "system_federation_network_bridges", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.uuid "federation_peer_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "proposed_at"
    t.string "revocation_reason", limit: 256
    t.datetime "revoked_at"
    t.uuid "sdwan_network_id", null: false
    t.string "state", limit: 16, default: "proposed", null: false
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.index ["account_id", "state"]
    t.index ["federation_peer_id", "sdwan_network_id"], unique: true
    t.index ["sdwan_network_id"]
    t.index ["state"]
    t.check_constraint "state::text = ANY (ARRAY['proposed'::character varying::text, 'active'::character varying::text, 'suspended'::character varying::text, 'revoked'::character varying::text])", name: "federation_network_bridges_state_enum"
  end

  create_table "system_federation_peers", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "acceptance_token_digest", comment: "SHA-256 hex digest of the plaintext acceptance token. Plaintext returned exactly once on propose; stored only as digest."
    t.datetime "acceptance_token_expires_at", comment: "When the acceptance token expires. accept! refuses tokens past this time."
    t.uuid "account_id", null: false
    t.jsonb "capabilities", default: {}, null: false
    t.integer "contract_version_agreed"
    t.datetime "created_at", null: false
    t.string "data_residency", limit: 64
    t.text "encrypted_credentials"
    t.jsonb "endpoints", default: [], null: false
    t.datetime "expires_at"
    t.jsonb "extension_slugs", default: [], null: false
    t.string "inbound_subject", limit: 255
    t.datetime "last_capability_sync_at"
    t.datetime "last_handshake_at"
    t.datetime "last_heartbeat_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.uuid "outbound_certificate_id"
    t.uuid "parent_peer_id"
    t.string "peer_kind", limit: 32, default: "sdwan_only", null: false
    t.string "platform_version", limit: 64
    t.uuid "remote_account_id"
    t.uuid "remote_instance_id"
    t.string "remote_instance_url", null: false
    t.string "remote_prefix_advertisement"
    t.datetime "signed_at"
    t.string "spawn_mode", limit: 32
    t.string "spawn_role", limit: 16
    t.string "status", default: "proposed", null: false
    t.jsonb "sync_cursor", default: {}, null: false
    t.text "trusted_ca_pem"
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["acceptance_token_digest"], name: "index_federation_peers_on_token_digest", where: "(acceptance_token_digest IS NOT NULL)"
    t.index ["account_id", "remote_instance_id"], unique: true
    t.index ["account_id"]
    t.index ["data_residency"]
    t.index ["inbound_subject"], name: "index_federation_peers_on_inbound_subject", unique: true, where: "(inbound_subject IS NOT NULL)"
    t.index ["last_heartbeat_at"], name: "idx_federation_peers_platform_heartbeat", where: "((peer_kind)::text = 'platform'::text)"
    t.index ["outbound_certificate_id"]
    t.index ["parent_peer_id"]
    t.index ["peer_kind", "status"]
    t.index ["peer_kind"]
    t.index ["platform_version"]
    t.index ["remote_prefix_advertisement"]
    t.index ["status"]
    t.check_constraint "peer_kind::text = ANY (ARRAY['platform'::character varying::text, 'sdwan_only'::character varying::text])", name: "federation_peers_peer_kind_enum"
  end

  create_table "system_federation_schema_compatibility", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.string "local_version", limit: 64, null: false
    t.string "notes", limit: 1024
    t.string "remote_version", limit: 64, null: false
    t.string "source", limit: 32, default: "default", null: false
    t.string "status", limit: 32, default: "compatible", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["local_version", "remote_version"], unique: true
    t.index ["status"]
  end

  create_table "system_federation_service_offerings", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "capacity_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "default_grant_scopes", default: ["read"], null: false
    t.integer "default_grant_ttl_days", default: 30, null: false
    t.datetime "deprecated_at"
    t.text "description_markdown"
    t.jsonb "latency_metadata", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 255, null: false
    t.datetime "retired_at"
    t.uuid "service_id", null: false
    t.string "slug", limit: 64, null: false
    t.string "status", limit: 16, default: "draft", null: false
    t.text "subscription_terms_markdown"
    t.datetime "updated_at", null: false
    t.index ["account_id", "slug"], unique: true
    t.index ["account_id"]
    t.index ["service_id"]
    t.index ["status"]
  end

  create_table "system_federation_service_subscriptions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "acme_certificate_id"
    t.datetime "activated_at"
    t.integer "backend_port", null: false
    t.string "backend_vip", limit: 255
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.uuid "federation_grant_id", null: false
    t.uuid "federation_peer_id", null: false
    t.string "local_hostname", limit: 255, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "protocol", limit: 16, null: false
    t.uuid "service_offering_id"
    t.string "service_offering_slug", limit: 64, null: false
    t.string "status", limit: 16, default: "pending", null: false
    t.datetime "subscribed_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.index ["account_id", "local_hostname"], unique: true
    t.index ["account_id"]
    t.index ["acme_certificate_id"]
    t.index ["federation_grant_id"]
    t.index ["federation_peer_id", "service_offering_slug"]
    t.index ["federation_peer_id"]
    t.index ["status"]
  end

  create_table "system_fleet_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "certificate_id"
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.uuid "cve_id"
    t.datetime "emitted_at", default: -> { "now()" }, null: false
    t.string "kind", null: false
    t.uuid "node_id"
    t.uuid "node_instance_id"
    t.uuid "node_module_id"
    t.uuid "node_module_version_id"
    t.jsonb "payload", default: {}, null: false
    t.string "severity", default: "low", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["account_id", "emitted_at"]
    t.index ["account_id"]
    t.index ["correlation_id"]
    t.index ["emitted_at"]
    t.index ["kind"]
    t.index ["node_instance_id"]
    t.index ["node_module_id"]
    t.index ["payload"], name: "index_system_fleet_events_on_payload", using: :gin
    t.index ["severity"]
    t.check_constraint "severity::text = ANY (ARRAY['low'::character varying::text, 'medium'::character varying::text, 'high'::character varying::text, 'critical'::character varying::text])", name: "ck_fleet_events_severity"
  end

  create_table "system_fleet_remediation_outcomes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "acted_at", null: false
    t.string "action_category"
    t.uuid "agent_id"
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.jsonb "metadata", default: {}
    t.string "resource_ref"
    t.datetime "settle_until", null: false
    t.string "signal_kind", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.datetime "validated_at"
    t.index ["account_id", "status", "settle_until"]
    t.index ["account_id"]
    t.index ["fingerprint"]
  end

  create_table "system_gitops_repositories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "auto_apply", default: false, null: false
    t.string "branch", default: "main", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "last_diff_count", default: 0, null: false
    t.text "last_error"
    t.string "last_status", default: "pending"
    t.datetime "last_synced_at"
    t.string "last_synced_revision"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "path_prefix", default: ""
    t.string "repo_url", null: false
    t.datetime "updated_at", null: false
    t.string "vault_credential_path"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["enabled"]
    t.index ["last_synced_at"]
  end

  create_table "system_gitops_sync_runs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "diff_count", default: 0, null: false
    t.jsonb "diff_summary", default: {}
    t.text "error_message"
    t.uuid "gitops_repository_id", null: false
    t.uuid "proposal_ids", default: [], array: true
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.string "synced_revision"
    t.datetime "updated_at", null: false
    t.index ["gitops_repository_id"]
    t.index ["started_at"]
    t.index ["status"]
  end

  create_table "system_instance_mount_points", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "mount_point_id", null: false
    t.uuid "node_instance_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["config"], name: "index_system_instance_mount_points_on_config", using: :gin
    t.index ["enabled"]
    t.index ["mount_point_id"]
    t.index ["node_instance_id", "mount_point_id"], unique: true
    t.index ["node_instance_id"]
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'mounted'::character varying::text, 'unmounted'::character varying::text, 'error'::character varying::text])", name: "system_instance_mount_points_status_check"
  end

  create_table "system_instance_pools", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "last_replenished_at"
    t.string "lifecycle_class", default: "ephemeral", null: false
    t.integer "max_size", default: 10, null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "min_size", default: 0, null: false
    t.string "name", null: false
    t.uuid "node_template_id", null: false
    t.text "preferred_regions", default: [], array: true
    t.uuid "provider_instance_type_id"
    t.uuid "provider_region_id"
    t.string "status", default: "active", null: false
    t.integer "target_size", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["node_template_id"]
    t.index ["provider_instance_type_id"]
    t.index ["provider_region_id"]
    t.index ["status", "last_replenished_at"], name: "idx_instance_pools_reaper_targets", where: "((status)::text = ANY (ARRAY[('active'::character varying)::text, ('draining'::character varying)::text]))"
    t.check_constraint "lifecycle_class::text = ANY (ARRAY['ephemeral'::character varying::text, 'spot'::character varying::text])", name: "chk_instance_pools_lifecycle_class"
    t.check_constraint "max_size >= target_size", name: "chk_instance_pools_max_gte_target"
    t.check_constraint "min_size >= 0", name: "chk_instance_pools_min_size_nonneg"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'paused'::character varying::text, 'draining'::character varying::text, 'archived'::character varying::text])", name: "chk_instance_pools_status"
    t.check_constraint "target_size >= 0", name: "chk_instance_pools_target_size_nonneg"
    t.check_constraint "target_size >= min_size", name: "chk_instance_pools_target_gte_min"
  end

  create_table "system_migration_chains", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "audit_log", default: [], null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "current_hop_index", default: 0, null: false
    t.string "error_message"
    t.datetime "failed_at"
    t.jsonb "hop_peer_ids", default: [], null: false
    t.uuid "initiated_by_user_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "operation", limit: 16, null: false
    t.string "root_resource_id", limit: 64, null: false
    t.string "root_resource_kind", limit: 64, null: false
    t.datetime "started_at"
    t.string "status", limit: 32, default: "planned", null: false
    t.integer "total_hops", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"]
    t.index ["account_id"]
    t.index ["initiated_by_user_id"]
    t.index ["status"]
    t.check_constraint "current_hop_index >= 0 AND current_hop_index <= total_hops", name: "migration_chain_hop_index_in_range"
    t.check_constraint "total_hops >= 1", name: "migration_chain_total_hops_positive"
  end

  create_table "system_migration_plan_steps", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "action", limit: 24, null: false
    t.datetime "applied_at"
    t.string "conflict_policy", limit: 32, default: "fail", null: false
    t.datetime "created_at", null: false
    t.string "error_message", limit: 2048
    t.jsonb "metadata", default: {}, null: false
    t.uuid "migration_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "resource_id", null: false
    t.string "resource_kind", limit: 64, null: false
    t.integer "step_order", null: false
    t.datetime "updated_at", null: false
    t.index ["action"]
    t.index ["migration_id", "step_order"], unique: true
    t.index ["migration_id"]
    t.index ["resource_kind", "resource_id"]
    t.check_constraint "action::text = ANY (ARRAY['create'::character varying::text, 'link_local'::character varying::text, 'skip'::character varying::text, 'conflict'::character varying::text])", name: "migration_plan_steps_action_enum"
    t.check_constraint "conflict_policy::text = ANY (ARRAY['skip_if_exists'::character varying::text, 'rename_with_suffix'::character varying::text, 'overwrite'::character varying::text, 'fail'::character varying::text])", name: "migration_plan_steps_conflict_policy_enum"
  end

  create_table "system_migrations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "audit_log", default: [], null: false
    t.datetime "cancelled_at"
    t.integer "chain_position"
    t.datetime "completed_at"
    t.jsonb "conflict_log", default: [], null: false
    t.datetime "created_at", null: false
    t.uuid "destination_peer_id"
    t.boolean "dry_run", default: false, null: false
    t.string "error_message", limit: 2048
    t.datetime "failed_at"
    t.uuid "initiated_by_user_id"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "migration_chain_id"
    t.string "operation", limit: 16, null: false
    t.jsonb "plan_summary", default: {}, null: false
    t.uuid "root_resource_id", null: false
    t.string "root_resource_kind", limit: 64, null: false
    t.uuid "source_account_id"
    t.datetime "started_at"
    t.string "status", limit: 16, default: "planned", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"]
    t.index ["account_id"]
    t.index ["destination_peer_id"]
    t.index ["initiated_by_user_id"]
    t.index ["migration_chain_id"]
    t.index ["operation"]
    t.index ["root_resource_kind", "root_resource_id"]
    t.check_constraint "operation::text = ANY (ARRAY['duplicate'::character varying::text, 'migrate'::character varying::text])", name: "migrations_operation_enum"
    t.check_constraint "status::text = ANY (ARRAY['planned'::character varying::text, 'validating'::character varying::text, 'transferring'::character varying::text, 'conflict'::character varying::text, 'applying'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text])", name: "migrations_status_enum"
  end

  create_table "system_module_artifacts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "architecture", null: false
    t.datetime "built_at", null: false
    t.text "cosign_bundle"
    t.datetime "created_at", null: false
    t.string "fsverity_root_hash"
    t.string "media_type", null: false
    t.uuid "node_module_version_id", null: false
    t.string "oci_digest", null: false
    t.string "oci_ref", null: false
    t.string "provenance_uri"
    t.integer "sbom_packages_count", default: 0, null: false
    t.jsonb "sbom_packages_data", default: []
    t.datetime "sbom_packages_synced_at"
    t.string "sbom_uri"
    t.bigint "size_bytes", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "vex_uri"
    t.index ["architecture"]
    t.index ["node_module_version_id", "architecture"], unique: true
    t.index ["node_module_version_id"]
    t.index ["oci_digest"]
    t.index ["sbom_packages_count"]
    t.index ["sbom_packages_synced_at"]
  end

  create_table "system_module_dependencies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "dependency_id", null: false
    t.string "dependency_type", default: "requires", null: false
    t.uuid "node_module_id", null: false
    t.boolean "required", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "version_constraint"
    t.index ["dependency_id"]
    t.index ["dependency_type"]
    t.index ["node_module_id", "dependency_id"], unique: true
    t.index ["node_module_id"]
    t.check_constraint "dependency_type::text = ANY (ARRAY['requires'::character varying::text, 'recommends'::character varying::text, 'conflicts'::character varying::text, 'provides'::character varying::text])", name: "system_module_dependencies_type_check"
  end

  create_table "system_module_puppet_assignments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "node_module_id", null: false
    t.jsonb "parameters", default: {}, null: false
    t.integer "priority", default: 0, null: false
    t.uuid "puppet_module_id", null: false
    t.datetime "updated_at", null: false
    t.index ["config"], name: "index_system_module_puppet_assignments_on_config", using: :gin
    t.index ["enabled"]
    t.index ["node_module_id", "puppet_module_id"], unique: true
    t.index ["node_module_id"]
    t.index ["parameters"], name: "index_system_module_puppet_assignments_on_parameters", using: :gin
    t.index ["priority"]
    t.index ["puppet_module_id"]
  end

  create_table "system_module_service_dependencies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "depends_on_module_service_id", null: false
    t.string "kind", limit: 32, default: "requires_health", null: false
    t.uuid "module_service_id", null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_module_service_id"]
    t.index ["module_service_id", "depends_on_module_service_id"], unique: true
  end

  create_table "system_module_services", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "capabilities", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "env", default: {}, null: false
    t.jsonb "exposed_ports", default: [], null: false
    t.string "health_endpoint", limit: 256
    t.integer "health_initial_delay_seconds", default: 10, null: false
    t.integer "health_interval_seconds", default: 30, null: false
    t.string "health_method", limit: 8, default: "GET", null: false
    t.integer "health_timeout_seconds", default: 5, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 100, null: false
    t.uuid "node_module_id", null: false
    t.string "restart_policy", limit: 32, default: "always", null: false
    t.uuid "service_user_id"
    t.text "start_command", null: false
    t.text "stop_command"
    t.string "system_user", limit: 32
    t.datetime "updated_at", null: false
    t.string "working_directory", limit: 512
    t.index ["account_id"]
    t.index ["node_module_id", "name"], unique: true
    t.index ["restart_policy"]
    t.index ["service_user_id"]
    t.index ["system_user"]
  end

  create_table "system_module_user_declarations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "node_module_id", null: false
    t.uuid "service_group_id"
    t.uuid "service_user_id"
    t.datetime "updated_at", null: false
    t.index ["node_module_id", "service_group_id"], name: "index_module_user_declarations_unique_group", unique: true, where: "(service_group_id IS NOT NULL)"
    t.index ["node_module_id", "service_user_id"], name: "index_module_user_declarations_unique_user", unique: true, where: "(service_user_id IS NOT NULL)"
    t.index ["node_module_id"]
    t.index ["service_group_id"]
    t.index ["service_user_id"]
    t.check_constraint "service_user_id IS NOT NULL AND service_group_id IS NULL OR service_user_id IS NULL AND service_group_id IS NOT NULL", name: "system_module_user_declarations_exactly_one_target"
  end

  create_table "system_mount_encryption_keys", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "algorithm", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.string "encryption_key_id"
    t.boolean "escrowed", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.uuid "node_instance_id"
    t.datetime "revoked_at"
    t.uuid "storage_assignment_id", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["node_instance_id"]
    t.index ["storage_assignment_id"]
    t.check_constraint "algorithm::text = ANY (ARRAY['aes-xts-plain64'::character varying::text, 'aes-256-gcm'::character varying::text, 'fscrypt-v2'::character varying::text])", name: "system_mount_encryption_keys_algorithm_check"
  end

  create_table "system_node_architectures", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "aliases", default: [], null: false
    t.string "apt_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "display_name"
    t.boolean "enabled", default: true, null: false
    t.string "family", default: "other", null: false
    t.string "image_checksum", comment: "SHA256 checksum of boot image file"
    t.uuid "image_file_object_id"
    t.string "image_format", comment: "Image format (raw, qcow2, vmdk, etc.)"
    t.boolean "is_canonical", default: false, null: false
    t.string "kernel_checksum", comment: "SHA256 checksum of kernel file"
    t.uuid "kernel_file_object_id"
    t.text "kernel_options"
    t.string "kernel_version", comment: "Kernel version string"
    t.string "name", null: false
    t.integer "node_platform_count", default: 0, null: false
    t.integer "package_count", default: 0, null: false
    t.integer "package_repository_count", default: 0, null: false
    t.boolean "public", default: false, null: false
    t.string "ramdisk_checksum", comment: "SHA256 checksum of ramdisk file"
    t.uuid "ramdisk_file_object_id"
    t.string "rpm_name"
    t.datetime "updated_at", null: false
    t.index ["aliases"], name: "idx_node_architectures_aliases_gin", using: :gin
    t.index ["apt_name"], name: "index_system_node_architectures_on_apt_name", where: "(apt_name IS NOT NULL)"
    t.index ["enabled"]
    t.index ["family"]
    t.index ["image_file_object_id"]
    t.index ["is_canonical"]
    t.index ["kernel_file_object_id"]
    t.index ["name"], unique: true
    t.index ["public"]
    t.index ["ramdisk_file_object_id"]
    t.index ["rpm_name"], name: "index_system_node_architectures_on_rpm_name", where: "(rpm_name IS NOT NULL)"
  end

  create_table "system_node_certificates", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.uuid "encryption_key_id"
    t.string "issuer_subject"
    t.datetime "migrated_to_vault_at"
    t.uuid "node_instance_id"
    t.datetime "not_after", null: false
    t.datetime "not_before", null: false
    t.text "pem_chain"
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.string "serial", null: false
    t.string "subject", null: false
    t.string "subject_kind", limit: 32, default: "instance", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["account_id"]
    t.index ["node_instance_id"]
    t.index ["not_after"]
    t.index ["revoked_at"]
    t.index ["serial"], unique: true
    t.index ["subject"]
    t.index ["subject_kind"]
    t.check_constraint "node_instance_id IS NOT NULL OR account_id IS NOT NULL", name: "node_certificates_owner_present"
    t.check_constraint "subject_kind::text = ANY (ARRAY['instance'::character varying::text, 'federation_peer'::character varying::text])", name: "node_certificates_subject_kind_enum"
  end

  create_table "system_node_instance_peers", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "addresses", default: [], array: true
    t.jsonb "capabilities", default: {}
    t.datetime "created_at", null: false
    t.integer "daily_decision_budget", default: 10, null: false
    t.integer "daily_decision_used", default: 0, null: false
    t.datetime "daily_decision_window_start"
    t.jsonb "declared_skills", default: []
    t.boolean "enabled", default: false, null: false
    t.bigint "execution_count", default: 0, null: false
    t.bigint "execution_failure_count", default: 0, null: false
    t.datetime "first_announced_at"
    t.jsonb "granted_mcp_tools", default: [], null: false
    t.jsonb "granted_peer_skills", default: [], null: false
    t.string "handle", null: false
    t.datetime "last_announced_at"
    t.datetime "last_executed_at"
    t.jsonb "metadata", default: {}
    t.uuid "node_instance_id", null: false
    t.string "status", default: "registered", null: false
    t.decimal "trust_score", precision: 5, scale: 4, default: "0.5"
    t.datetime "updated_at", null: false
    t.index ["account_id", "handle"], unique: true
    t.index ["account_id"]
    t.index ["enabled"]
    t.index ["node_instance_id"], unique: true
    t.index ["status"]
  end

  create_table "system_node_instances", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "agent_version"
    t.string "architecture", default: "amd64", null: false
    t.string "boot_id"
    t.jsonb "capabilities", default: {}, null: false
    t.string "claim_code"
    t.datetime "claimed_at"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discovered_at"
    t.string "discovered_dmi_uuid"
    t.string "discovered_hostname"
    t.string "discovered_mac"
    t.uuid "enrollment_token_id"
    t.uuid "instance_pool_id"
    t.text "key"
    t.datetime "last_heartbeat_at"
    t.decimal "latitude", precision: 10, scale: 7, comment: "Latitude coordinate"
    t.decimal "longitude", precision: 10, scale: 7, comment: "Longitude coordinate"
    t.string "mac_address", comment: "Primary MAC address"
    t.string "mtls_subject"
    t.string "name", null: false
    t.string "network_profile", default: "lightweight", null: false, comment: "OVS+OVN dual-profile selector — see System::NodeInstance::NETWORK_PROFILES"
    t.uuid "node_id", null: false
    t.datetime "pool_acquired_at"
    t.string "pool_state"
    t.datetime "pool_warming_started_at"
    t.string "private_ip_address"
    t.boolean "private_netboot", default: false, comment: "Enable private netboot"
    t.uuid "provider_instance_type_id"
    t.uuid "provider_region_id"
    t.string "public_ip_address"
    t.jsonb "running_module_digests", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "variety", default: "cloud", null: false
    t.string "vpn_ip_address"
    t.index ["account_id"]
    t.index ["architecture"]
    t.index ["capabilities"], name: "index_system_node_instances_on_capabilities", using: :gin
    t.index ["claim_code"], name: "idx_node_instances_claim_code_unique", unique: true, where: "(claim_code IS NOT NULL)"
    t.index ["config"], name: "index_system_node_instances_on_config", using: :gin
    t.index ["discovered_mac"]
    t.index ["enrollment_token_id"]
    t.index ["instance_pool_id", "pool_state", "pool_warming_started_at"], name: "idx_node_instances_pool_acquire", where: "(instance_pool_id IS NOT NULL)"
    t.index ["instance_pool_id"]
    t.index ["last_heartbeat_at"]
    t.index ["mac_address"], name: "index_system_node_instances_on_mac_address", unique: true, where: "(mac_address IS NOT NULL)"
    t.index ["mtls_subject"]
    t.index ["network_profile"]
    t.index ["node_id", "name"], unique: true
    t.index ["node_id", "status"]
    t.index ["node_id", "variety"]
    t.index ["node_id"]
    t.index ["provider_instance_type_id"]
    t.index ["provider_region_id", "status"]
    t.index ["provider_region_id"]
    t.index ["running_module_digests"], name: "index_system_node_instances_on_running_module_digests", using: :gin
    t.check_constraint "architecture::text = ANY (ARRAY['amd64'::character varying::text, 'arm64'::character varying::text])", name: "system_node_instances_architecture_check"
    t.check_constraint "instance_pool_id IS NULL AND pool_state IS NULL OR instance_pool_id IS NOT NULL AND pool_state IS NOT NULL", name: "chk_node_instances_pool_consistency"
    t.check_constraint "network_profile::text = ANY (ARRAY['lightweight'::character varying::text, 'heavyweight'::character varying::text])", name: "system_node_instances_network_profile_check"
    t.check_constraint "pool_state IS NULL OR (pool_state::text = ANY (ARRAY['warming'::character varying::text, 'ready'::character varying::text, 'claimed'::character varying::text, 'draining'::character varying::text, 'errored'::character varying::text]))", name: "chk_node_instances_pool_state"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'provisioning'::character varying::text, 'starting'::character varying::text, 'running'::character varying::text, 'stopping'::character varying::text, 'stopped'::character varying::text, 'rebooting'::character varying::text, 'terminated'::character varying::text, 'error'::character varying::text])", name: "system_node_instances_status_check"
    t.check_constraint "variety::text = ANY (ARRAY['cloud'::character varying::text, 'physical'::character varying::text, 'dynamic'::character varying::text])", name: "system_node_instances_variety_check"
  end

  create_table "system_node_module_assignments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.boolean "auto_resolved", default: false, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "node_id", null: false
    t.uuid "node_module_id", null: false
    t.integer "priority", default: 0, null: false
    t.uuid "source_template_module_id"
    t.datetime "updated_at", null: false
    t.index ["auto_resolved"]
    t.index ["config"], name: "index_system_node_module_assignments_on_config", using: :gin
    t.index ["enabled"]
    t.index ["node_id", "node_module_id"], unique: true
    t.index ["node_id"]
    t.index ["node_module_id"]
    t.index ["priority"]
    t.index ["source_template_module_id"]
  end

  create_table "system_node_module_categories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "color"
    t.uuid "config_category_id"
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "icon"
    t.uuid "instance_category_id"
    t.string "name", null: false
    t.uuid "parent_id"
    t.integer "position", default: 0, null: false
    t.boolean "public", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "variety", default: "subscription", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["config_category_id"]
    t.index ["enabled"]
    t.index ["instance_category_id"]
    t.index ["parent_id"]
    t.index ["position"]
    t.index ["public"]
    t.index ["variety"]
    t.check_constraint "variety::text = ANY (ARRAY['subscription'::character varying::text, 'config'::character varying::text, 'instance'::character varying::text])", name: "system_node_module_categories_variety_check"
  end

  create_table "system_node_module_copy_paths", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "destination_path", null: false
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.boolean "preserve_permissions", default: true, null: false
    t.boolean "recursive", default: false, null: false
    t.string "source_path", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["enabled"]
  end

  create_table "system_node_module_versions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "artifacts", default: {}, null: false
    t.datetime "blessed_at"
    t.text "changelog"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "data_checksum"
    t.string "data_file_name"
    t.integer "data_file_size"
    t.jsonb "file_spec", default: {}, null: false
    t.string "fsverity_root_hash"
    t.datetime "live_at"
    t.jsonb "mask", default: {}, null: false
    t.uuid "node_module_id", null: false
    t.string "oci_digest"
    t.jsonb "package_spec", default: {}, null: false
    t.string "promotion_state", default: "built", null: false
    t.jsonb "protected_spec", default: [], null: false
    t.string "provenance_uri"
    t.datetime "retired_at"
    t.string "sbom_uri"
    t.datetime "staging_baked_at"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.string "vex_uri"
    t.index ["artifacts"], name: "index_system_node_module_versions_on_artifacts", using: :gin
    t.index ["created_by_id"]
    t.index ["data_checksum"]
    t.index ["node_module_id", "version_number"], unique: true
    t.index ["node_module_id"]
    t.index ["oci_digest"]
    t.index ["promotion_state"]
    t.index ["protected_spec"], name: "index_system_node_module_versions_on_protected_spec", using: :gin
    t.index ["version_number"]
    t.check_constraint "promotion_state::text = ANY (ARRAY['built'::character varying::text, 'staging'::character varying::text, 'blessed'::character varying::text, 'live'::character varying::text, 'retired'::character varying::text])", name: "system_node_module_versions_promotion_state_check"
  end

  create_table "system_node_modules", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "auto_generated", default: false, null: false
    t.jsonb "capabilities", default: [], null: false, comment: "Capability tags this module provides (denormalized from manifest.dependencies.provides) — queried by ManifestImportService for capability:foo dependency resolution."
    t.uuid "category_id"
    t.jsonb "config", default: {}, null: false
    t.integer "consent_budget_per_day"
    t.integer "consent_budget_used_count", default: 0, null: false
    t.datetime "consent_budget_window_start_at"
    t.uuid "copy_path_id"
    t.string "cosign_identity_regexp", comment: "Sigstore Fulcio identity regexp the agent will accept (e.g. 'https://gitea.example.com/.+')"
    t.string "cosign_issuer_regexp", comment: "Sigstore Fulcio OIDC issuer regexp (e.g. 'https://gitea.example.com')"
    t.datetime "created_at", null: false
    t.uuid "current_version_id"
    t.integer "current_version_number", default: 0, null: false
    t.string "data_checksum"
    t.string "data_file_name"
    t.integer "data_file_size"
    t.jsonb "dependency_spec", default: [], null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.jsonb "file_spec", default: [], null: false
    t.string "gitea_repo_full_name"
    t.text "init_restart"
    t.text "init_start"
    t.text "init_stop"
    t.boolean "lock_spec", default: false, null: false
    t.text "manifest_yaml"
    t.jsonb "mask", default: [], null: false
    t.string "name", null: false
    t.uuid "node_id"
    t.uuid "node_instance_id"
    t.uuid "node_platform_id"
    t.jsonb "package_spec", default: [], null: false
    t.uuid "parent_module_id"
    t.integer "priority", default: 0, null: false
    t.jsonb "protected_spec", default: [], null: false
    t.boolean "public", default: false, null: false
    t.boolean "reboot_required", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "variety", default: "config", null: false
    t.string "webhook_secret"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["auto_generated"]
    t.index ["capabilities"], name: "idx_system_node_modules_on_capabilities_gin", using: :gin
    t.index ["category_id"]
    t.index ["config"], name: "index_system_node_modules_on_config", using: :gin
    t.index ["copy_path_id"]
    t.index ["current_version_id"]
    t.index ["current_version_number"]
    t.index ["data_checksum"]
    t.index ["enabled"]
    t.index ["file_spec"], name: "index_system_node_modules_on_file_spec", using: :gin
    t.index ["gitea_repo_full_name"], name: "idx_uniq_system_node_modules_gitea_repo", unique: true, where: "(gitea_repo_full_name IS NOT NULL)"
    t.index ["lock_spec"]
    t.index ["mask"], name: "index_system_node_modules_on_mask", using: :gin
    t.index ["node_id"]
    t.index ["node_instance_id"]
    t.index ["node_platform_id"]
    t.index ["package_spec"], name: "index_system_node_modules_on_package_spec", using: :gin
    t.index ["parent_module_id", "node_id", "node_instance_id"]
    t.index ["parent_module_id"]
    t.index ["priority"]
    t.index ["protected_spec"], name: "index_system_node_modules_on_protected_spec", using: :gin
    t.index ["public"]
    t.index ["reboot_required"]
    t.index ["variety"]
    t.check_constraint "variety::text = ANY (ARRAY['config'::character varying::text, 'instance'::character varying::text, 'subscription'::character varying::text])", name: "system_node_modules_variety_check"
  end

  create_table "system_node_mount_points", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "auto_mount", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "mount_path", null: false
    t.string "mount_type", default: "nfs", null: false
    t.string "name", null: false
    t.jsonb "options", default: {}, null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["enabled"]
    t.index ["mount_type"]
    t.index ["options"], name: "index_system_node_mount_points_on_options", using: :gin
    t.check_constraint "mount_type::text = ANY (ARRAY['tmpfs'::character varying::text, 'bind'::character varying::text, 'custom'::character varying::text])", name: "system_node_mount_points_type_check"
  end

  create_table "system_node_platforms", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.text "build_script"
    t.string "cosign_identity_regexp", comment: "Sigstore Fulcio identity regexp the publication processor will accept (e.g. 'https://registry.example.com/powernode/.+')"
    t.string "cosign_issuer_regexp", comment: "Sigstore Fulcio OIDC issuer regexp (e.g. 'https://registry.example.com')"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "disk_image_built_at"
    t.uuid "disk_image_file_object_id"
    t.string "disk_image_git_sha", comment: "Git SHA of the source build that produced the active disk image"
    t.string "disk_image_oci_ref", comment: "Last-published OCI reference (e.g. registry.example.com/powernode/disk-images/ubuntu-24.04-rpi4:abc123)"
    t.text "disk_image_publication_error", comment: "Last error message if disk_image_publication_status='failed'"
    t.string "disk_image_publication_status", default: "none", null: false, comment: "none|verifying|published|failed — operator-facing status"
    t.integer "disk_image_retention_count", default: 3, null: false, comment: "Number of historical publications to retain before reaper purges (per platform)"
    t.string "disk_image_sha256"
    t.bigint "disk_image_size_bytes"
    t.boolean "enabled", default: true, null: false
    t.text "init_script"
    t.string "name", null: false
    t.uuid "node_architecture_id", null: false
    t.boolean "public", default: false, null: false
    t.text "sync_script"
    t.datetime "updated_at", null: false
    t.index ["account_id", "enabled"]
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "public"]
    t.index ["account_id"]
    t.index ["disk_image_file_object_id"]
    t.index ["node_architecture_id"]
  end

  create_table "system_node_scripts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "data"
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.boolean "public", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "variety", default: "custom", null: false
    t.index ["account_id", "enabled"]
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "public"]
    t.index ["account_id", "variety"]
    t.index ["account_id"]
    t.check_constraint "variety::text = ANY (ARRAY['build'::character varying::text, 'init'::character varying::text, 'sync'::character varying::text, 'custom'::character varying::text])", name: "system_node_scripts_variety_check"
  end

  create_table "system_node_templates", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "admin_user"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.uuid "node_platform_id", null: false
    t.boolean "public", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "enabled"]
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "public"]
    t.index ["account_id"]
    t.index ["config"], name: "index_system_node_templates_on_config", using: :gin
    t.index ["node_platform_id"]
  end

  create_table "system_nodes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "allocate_public_ip", default: false, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.uuid "internal_ca_id"
    t.string "lifecycle_class", default: "persistent", null: false
    t.string "name", null: false
    t.uuid "node_template_id", null: false
    t.string "public_address"
    t.integer "runtime_amount", default: 0, comment: "Runtime tracking in minutes"
    t.text "ssh_host_key"
    t.string "ssh_host_key_fingerprint"
    t.text "ssh_key"
    t.string "ssh_key_fingerprint"
    t.string "ssh_key_type", default: "ed25519", null: false
    t.boolean "tmpfs_store", default: false, comment: "Use tmpfs for storage"
    t.datetime "updated_at", null: false
    t.uuid "worker_id"
    t.index ["account_id", "enabled"]
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["config"], name: "index_system_nodes_on_config", using: :gin
    t.index ["internal_ca_id"]
    t.index ["lifecycle_class"]
    t.index ["node_template_id"]
    t.index ["ssh_host_key_fingerprint"]
    t.index ["ssh_key_fingerprint"]
    t.index ["worker_id"]
    t.check_constraint "lifecycle_class::text = ANY (ARRAY['persistent'::character varying::text, 'ephemeral'::character varying::text, 'spot'::character varying::text])", name: "chk_system_nodes_lifecycle_class"
  end

  create_table "system_package_module_links", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "alternatives_chosen", default: {}, null: false
    t.string "architecture", null: false
    t.boolean "auto_generated", default: true, null: false
    t.datetime "created_at", null: false
    t.string "file_spec_source", default: "package_query", null: false
    t.datetime "last_synced_at"
    t.uuid "node_module_id", null: false
    t.string "package_name", null: false
    t.uuid "package_repository_id", null: false
    t.string "package_version", null: false
    t.jsonb "recommends_chosen", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["node_module_id"], unique: true
    t.index ["package_repository_id", "package_name", "architecture"]
    t.index ["package_repository_id"]
    t.check_constraint "file_spec_source::text = ANY (ARRAY['manual'::character varying::text, 'package_query'::character varying::text])", name: "chk_pkgmodlink_file_spec_source"
  end

  create_table "system_package_repositories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.jsonb "apt_config", default: {}, null: false
    t.jsonb "architectures", default: ["amd64"], null: false
    t.string "base_url", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "kind", null: false
    t.text "last_sync_error"
    t.datetime "last_synced_at"
    t.string "name", null: false
    t.integer "package_count", default: 0, null: false
    t.integer "priority", default: 100, null: false
    t.jsonb "rpm_config", default: {}, null: false
    t.text "signing_key_armor"
    t.string "sync_status", default: "idle", null: false
    t.datetime "updated_at", null: false
    t.string "vault_credential_path"
    t.string "visibility", default: "account", null: false
    t.index ["account_id", "name"], name: "idx_pkgrepo_account_name_unique", unique: true, where: "(account_id IS NOT NULL)"
    t.index ["account_id"]
    t.index ["created_by_id"]
    t.index ["enabled"]
    t.index ["name"], name: "idx_pkgrepo_shared_name_unique", unique: true, where: "(account_id IS NULL)"
    t.index ["sync_status"]
    t.index ["visibility"]
    t.check_constraint "kind::text = ANY (ARRAY['apt'::character varying::text, 'rpm'::character varying::text, 'dnf'::character varying::text])", name: "chk_pkgrepo_kind"
    t.check_constraint "sync_status::text = ANY (ARRAY['idle'::character varying::text, 'syncing'::character varying::text, 'failed'::character varying::text])", name: "chk_pkgrepo_sync_status"
    t.check_constraint "visibility::text = 'shared'::text AND account_id IS NULL OR visibility::text = 'account'::text AND account_id IS NOT NULL", name: "chk_pkgrepo_visibility_account_consistency"
    t.check_constraint "visibility::text = ANY (ARRAY['account'::character varying::text, 'shared'::character varying::text])", name: "chk_pkgrepo_visibility"
  end

  create_table "system_package_repository_platforms", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "node_platform_id", null: false
    t.uuid "package_repository_id", null: false
    t.datetime "updated_at", null: false
    t.index ["node_platform_id"]
    t.index ["package_repository_id", "node_platform_id"], unique: true
    t.index ["package_repository_id"]
  end

  create_table "system_packages", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "architecture", null: false
    t.jsonb "breaks", default: [], null: false
    t.jsonb "conflicts", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "depends", default: [], null: false
    t.text "description"
    t.bigint "download_size_bytes"
    t.vector "embedding", limit: 1536
    t.datetime "embedding_generated_at"
    t.datetime "embedding_started_at"
    t.string "filename"
    t.string "homepage"
    t.bigint "installed_size_bytes"
    t.string "license"
    t.string "maintainer"
    t.string "name", null: false
    t.datetime "obsoleted_at"
    t.uuid "package_repository_id", null: false
    t.jsonb "pre_depends", default: [], null: false
    t.jsonb "provides", default: [], null: false
    t.jsonb "raw_metadata", default: {}, null: false
    t.jsonb "recommends", default: [], null: false
    t.string "release_version"
    t.jsonb "replaces", default: [], null: false
    t.string "section_or_group"
    t.string "sha256"
    t.string "sha512"
    t.jsonb "suggests", default: [], null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["depends"], name: "idx_packages_depends_gin", using: :gin
    t.index ["description"], name: "idx_packages_description_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["embedding"], name: "idx_packages_embedding_hnsw", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["license"]
    t.index ["name", "architecture"]
    t.index ["name"], name: "idx_packages_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["obsoleted_at"], name: "index_system_packages_on_obsoleted_at", where: "(obsoleted_at IS NOT NULL)"
    t.index ["package_repository_id", "name", "architecture", "version"], unique: true
    t.index ["package_repository_id"]
    t.index ["provides"], name: "idx_packages_provides_gin", using: :gin
    t.index ["section_or_group"]
  end

  create_table "system_peer_capability_revocations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "jti"
    t.string "reason"
    t.string "sub"
    t.datetime "updated_at", null: false
    t.index ["account_id", "expires_at"]
    t.index ["account_id"]
  end

  create_table "system_peer_capability_signing_keys", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.string "handle", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.string "public_key_b64", null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "rotated_from_id"
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["account_id", "handle"], unique: true
    t.index ["account_id"]
    t.index ["rotated_from_id"]
  end

  create_table "system_platform_deployments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 100, null: false
    t.uuid "node_template_id", null: false
    t.string "public_dns_hostname", limit: 256
    t.string "satellite_extension_slug", limit: 64
    t.string "service_role", limit: 32, null: false
    t.integer "target_replicas", default: 1, null: false
    t.datetime "updated_at", null: false
    t.uuid "virtual_ip_id"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "service_role"]
    t.index ["node_template_id"]
    t.index ["satellite_extension_slug"], name: "index_system_platform_deployments_on_satellite_extension_slug", where: "(satellite_extension_slug IS NOT NULL)"
    t.index ["virtual_ip_id"]
    t.check_constraint "target_replicas >= 0", name: "platform_deployments_target_replicas_non_negative"
  end

  create_table "system_project_metrics", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.string "metric_name", null: false
    t.string "metric_type", null: false
    t.uuid "mission_id", null: false
    t.datetime "sampled_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "value", default: {}, null: false
    t.index ["metric_type"]
    t.index ["mission_id", "metric_name", "sampled_at"], order: { sampled_at: :desc }
    t.index ["mission_id"]
    t.index ["sampled_at"]
  end

  create_table "system_provider_availability_zones", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "capabilities", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.uuid "provider_region_id", null: false
    t.string "status", default: "available", null: false
    t.datetime "updated_at", null: false
    t.string "zone_code", null: false
    t.index "provider_region_id, lower((name)::text)", unique: true
    t.index ["capabilities"], name: "index_system_provider_availability_zones_on_capabilities", using: :gin
    t.index ["provider_region_id", "enabled"]
    t.index ["provider_region_id", "zone_code"], unique: true
    t.index ["provider_region_id"]
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['available'::character varying::text, 'impaired'::character varying::text, 'unavailable'::character varying::text])", name: "system_provider_availability_zones_status_check"
  end

  create_table "system_provider_connections", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.text "access_key"
    t.uuid "account_id", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "endpoint_url"
    t.text "last_test_message"
    t.string "last_test_status"
    t.datetime "last_tested_at"
    t.string "name", null: false
    t.uuid "provider_id", null: false
    t.text "secret_key"
    t.string "status", default: "pending", null: false
    t.string "tenant"
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["config"], name: "index_system_provider_connections_on_config", using: :gin
    t.index ["provider_id", "enabled"]
    t.index ["provider_id"]
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'connected'::character varying::text, 'error'::character varying::text])", name: "system_provider_connections_status_check"
  end

  create_table "system_provider_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "credentials"
    t.boolean "is_active", default: true, null: false
    t.text "last_error"
    t.datetime "last_test_at"
    t.string "last_test_status"
    t.string "name", null: false
    t.uuid "provider_id", null: false
    t.integer "scope", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_id"], name: "idx_system_provider_creds_account_owned", where: "(scope = 0)"
    t.index ["account_id"]
    t.index ["provider_id"]
    t.index ["scope"]
  end

  create_table "system_provider_instance_types", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.integer "gpu_count", default: 0, null: false
    t.integer "gpu_memory_mb"
    t.string "gpu_type"
    t.decimal "hourly_price", precision: 10, scale: 4
    t.string "instance_type_code", null: false
    t.integer "memory_mb"
    t.string "name", null: false
    t.string "network_performance"
    t.string "processor_type"
    t.uuid "provider_id", null: false
    t.boolean "public", default: false, null: false
    t.jsonb "specs", default: {}, null: false
    t.integer "storage_gb"
    t.datetime "updated_at", null: false
    t.integer "vcpus"
    t.index "account_id, provider_id, lower((name)::text)", unique: true
    t.index ["account_id", "enabled"]
    t.index ["account_id"]
    t.index ["gpu_type", "gpu_count"], name: "idx_system_provider_instance_types_gpu", where: "(gpu_count > 0)"
    t.index ["provider_id", "instance_type_code"], unique: true
    t.index ["provider_id"]
    t.index ["specs"], name: "index_system_provider_instance_types_on_specs", using: :gin
  end

  create_table "system_provider_network_subnets", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "availability_zone_id"
    t.integer "available_ip_count"
    t.string "cidr_block", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "external_id"
    t.boolean "is_public", default: false, null: false
    t.boolean "map_public_ip_on_launch", default: false, null: false
    t.string "name", null: false
    t.uuid "network_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["availability_zone_id"]
    t.index ["cidr_block"]
    t.index ["config"], name: "index_system_provider_network_subnets_on_config", using: :gin
    t.index ["external_id"]
    t.index ["is_public"]
    t.index ["network_id", "name"], unique: true
    t.index ["network_id"]
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'available'::character varying::text, 'deleting'::character varying::text, 'deleted'::character varying::text, 'error'::character varying::text])", name: "system_provider_network_subnets_status_check"
  end

  create_table "system_provider_networks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "cidr_block", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enable_dns_hostnames", default: false, null: false
    t.boolean "enable_dns_support", default: true, null: false
    t.string "external_id"
    t.boolean "is_default", default: false, null: false
    t.string "name", null: false
    t.uuid "provider_id", null: false
    t.uuid "provider_region_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["cidr_block"]
    t.index ["config"], name: "index_system_provider_networks_on_config", using: :gin
    t.index ["external_id"]
    t.index ["is_default"]
    t.index ["provider_id"]
    t.index ["provider_region_id"]
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'available'::character varying::text, 'deleting'::character varying::text, 'deleted'::character varying::text, 'error'::character varying::text])", name: "system_provider_networks_status_check"
  end

  create_table "system_provider_regions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "capabilities", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "endpoint_url"
    t.string "kernel_image"
    t.string "machine_image"
    t.string "name", null: false
    t.uuid "provider_id", null: false
    t.string "ramdisk_image"
    t.string "region_code", null: false
    t.datetime "updated_at", null: false
    t.index "account_id, provider_id, lower((name)::text)", unique: true
    t.index ["account_id", "enabled"]
    t.index ["account_id"]
    t.index ["capabilities"], name: "index_system_provider_regions_on_capabilities", using: :gin
    t.index ["provider_id", "region_code"], unique: true
    t.index ["provider_id"]
  end

  create_table "system_provider_volume_members", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "cloud_volume_id", comment: "Cloud provider volume ID for this member"
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.string "device_name", comment: "Device name (e.g., /dev/sdb)"
    t.integer "member_index", default: 0, comment: "Order in RAID array"
    t.uuid "provider_volume_id", null: false
    t.integer "size_gb", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["cloud_volume_id"]
    t.index ["provider_volume_id", "member_index"], unique: true
    t.index ["provider_volume_id"]
  end

  create_table "system_provider_volume_snapshots", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "encrypted", default: false, null: false
    t.string "external_id"
    t.string "name", null: false
    t.integer "progress", default: 0, null: false
    t.integer "size_gb", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.uuid "volume_id"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["config"], name: "index_system_provider_volume_snapshots_on_config", using: :gin
    t.index ["encrypted"]
    t.index ["external_id"]
    t.index ["status"]
    t.index ["volume_id"]
    t.check_constraint "progress >= 0 AND progress <= 100", name: "system_provider_volume_snapshots_progress_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'creating'::character varying::text, 'completed'::character varying::text, 'error'::character varying::text, 'deleting'::character varying::text, 'deleted'::character varying::text])", name: "system_provider_volume_snapshots_status_check"
  end

  create_table "system_provider_volume_types", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.integer "max_iops"
    t.integer "max_size_gb", default: 16384, null: false
    t.integer "max_throughput"
    t.integer "min_iops"
    t.integer "min_size_gb", default: 1, null: false
    t.integer "min_throughput"
    t.string "name", null: false
    t.uuid "provider_id", null: false
    t.jsonb "specs", default: {}, null: false
    t.datetime "updated_at", null: false
    t.string "volume_type", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["enabled"]
    t.index ["provider_id"]
    t.index ["specs"], name: "index_system_provider_volume_types_on_specs", using: :gin
    t.index ["volume_type"]
    t.check_constraint "volume_type::text = ANY (ARRAY['gp2'::character varying::text, 'gp3'::character varying::text, 'io1'::character varying::text, 'io2'::character varying::text, 'st1'::character varying::text, 'sc1'::character varying::text, 'standard'::character varying::text, 'ssd'::character varying::text, 'hdd'::character varying::text, 'nfs'::character varying::text, 'iscsi'::character varying::text, 'smb'::character varying::text, 'custom'::character varying::text])", name: "system_provider_volume_types_type_check"
  end

  create_table "system_provider_volumes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "availability_zone_id"
    t.bigint "capacity_bytes", comment: "Total capacity in bytes"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "delete_on_termination", default: false, null: false
    t.text "description"
    t.string "device_name"
    t.boolean "encrypted", default: false, null: false
    t.string "external_id"
    t.integer "iops"
    t.string "name", null: false
    t.uuid "node_instance_id"
    t.uuid "provider_region_id"
    t.integer "raid_level", comment: "RAID level (0 for striping, 1 for mirroring)"
    t.integer "size_gb", null: false
    t.string "status", default: "creating", null: false
    t.integer "throughput"
    t.datetime "updated_at", null: false
    t.bigint "used_bytes", default: 0, comment: "Used space in bytes"
    t.uuid "volume_type_id"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["availability_zone_id"]
    t.index ["config"], name: "index_system_provider_volumes_on_config", using: :gin
    t.index ["encrypted"]
    t.index ["external_id"]
    t.index ["node_instance_id"]
    t.index ["provider_region_id"]
    t.index ["status"]
    t.index ["volume_type_id"]
    t.check_constraint "status::text = ANY (ARRAY['creating'::character varying::text, 'available'::character varying::text, 'in-use'::character varying::text, 'deleting'::character varying::text, 'deleted'::character varying::text, 'error'::character varying::text])", name: "system_provider_volumes_status_check"
  end

  create_table "system_providers", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "capabilities", default: {}, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "provider_type", null: false
    t.boolean "public", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "enabled"]
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "provider_type"]
    t.index ["account_id"]
    t.index ["capabilities"], name: "index_system_providers_on_capabilities", using: :gin
    t.index ["config"], name: "index_system_providers_on_config", using: :gin
  end

  create_table "system_puppet_modules", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "author"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "dependencies", default: [], null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "forge_name"
    t.string "license"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "project_url"
    t.boolean "public", default: false, null: false
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.string "version"
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["config"], name: "index_system_puppet_modules_on_config", using: :gin
    t.index ["dependencies"], name: "index_system_puppet_modules_on_dependencies", using: :gin
    t.index ["enabled"]
    t.index ["forge_name"]
    t.index ["metadata"], name: "index_system_puppet_modules_on_metadata", using: :gin
    t.index ["public"]
  end

  create_table "system_puppet_resources", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "data"
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.boolean "exported", default: false, null: false
    t.string "name", null: false
    t.jsonb "parameters", default: {}, null: false
    t.string "path"
    t.uuid "puppet_module_id", null: false
    t.string "resource_type", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["config"], name: "index_system_puppet_resources_on_config", using: :gin
    t.index ["enabled"]
    t.index ["exported"]
    t.index ["parameters"], name: "index_system_puppet_resources_on_parameters", using: :gin
    t.index ["puppet_module_id", "name"], unique: true
    t.index ["puppet_module_id"]
    t.index ["resource_type"]
    t.check_constraint "resource_type::text = ANY (ARRAY['file'::character varying::text, 'package'::character varying::text, 'service'::character varying::text, 'exec'::character varying::text, 'user'::character varying::text, 'group'::character varying::text, 'cron'::character varying::text, 'mount'::character varying::text, 'host'::character varying::text, 'notify'::character varying::text, 'class'::character varying::text, 'define'::character varying::text, 'custom'::character varying::text])", name: "system_puppet_resources_type_check"
  end

  create_table "system_region_instance_types", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.boolean "available", default: true, null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.decimal "hourly_price", precision: 10, scale: 4
    t.uuid "provider_instance_type_id", null: false
    t.uuid "provider_region_id", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_instance_type_id"]
    t.index ["provider_region_id", "available"]
    t.index ["provider_region_id", "provider_instance_type_id"], unique: true
    t.index ["provider_region_id"]
  end

  create_table "system_region_volume_types", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "provider_region_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "volume_type_id", null: false
    t.index ["enabled"]
    t.index ["provider_region_id", "volume_type_id"], unique: true
    t.index ["provider_region_id"]
    t.index ["volume_type_id"]
  end

  create_table "system_sdwan_access_grants", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "granted_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "granted_by_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "sdwan_network_id", null: false
    t.string "status", default: "active", null: false
    t.string "tags", default: [], array: true
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["account_id"]
    t.index ["granted_by_id"]
    t.index ["sdwan_network_id", "user_id"], unique: true
    t.index ["sdwan_network_id"]
    t.index ["status"]
    t.index ["user_id"]
  end

  create_table "system_sdwan_account_bgps", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.bigint "as_number", null: false
    t.datetime "created_at", null: false
    t.integer "default_local_pref", default: 100, null: false
    t.uuid "default_route_policy_id"
    t.boolean "enabled", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "router_id_strategy", default: "peer_overlay_ipv6_hash", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], unique: true
    t.index ["as_number"], unique: true
    t.index ["default_route_policy_id"]
    t.check_constraint "as_number >= '4200000000'::bigint AND as_number <= '4294967294'::bigint", name: "sdwan_account_bgps_rfc6996_private"
  end

  create_table "system_sdwan_bgp_sessions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "last_error"
    t.datetime "last_observed_at", null: false
    t.datetime "last_state_change_at"
    t.string "neighbor_address", null: false
    t.uuid "neighbor_peer_id"
    t.integer "prefixes_received", default: 0
    t.integer "prefixes_sent", default: 0
    t.uuid "sdwan_network_id", null: false
    t.uuid "sdwan_peer_id", null: false
    t.string "state", default: "idle", null: false
    t.datetime "updated_at", null: false
    t.integer "uptime_seconds", default: 0
    t.index ["neighbor_peer_id"]
    t.index ["sdwan_network_id"]
    t.index ["sdwan_peer_id", "neighbor_address"], unique: true
    t.index ["sdwan_peer_id"]
    t.index ["state"]
  end

  create_table "system_sdwan_configurations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "account_prefix_48", null: false
    t.datetime "created_at", null: false
    t.string "instance_prefix_40", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], unique: true
    t.index ["account_prefix_48"], unique: true
    t.index ["instance_prefix_40"]
  end

  create_table "system_sdwan_constellation_signing_keys", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.string "handle", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.string "public_key_b64", null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "rotated_from_id"
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["account_id", "handle"], unique: true
    t.index ["account_id"]
    t.index ["rotated_from_id"]
  end

  create_table "system_sdwan_firewall_rules", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "action", default: "accept", null: false
    t.datetime "created_at", null: false
    t.string "direction", default: "both", null: false
    t.int4range "dst_port_range"
    t.jsonb "dst_selector", default: {}, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "last_compiled_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.integer "priority", default: 1000, null: false
    t.string "protocol", default: "any", null: false
    t.uuid "sdwan_network_id", null: false
    t.jsonb "src_selector", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["enabled"]
    t.index ["sdwan_network_id", "name"], unique: true
    t.index ["sdwan_network_id", "priority"]
    t.index ["sdwan_network_id"]
  end

  create_table "system_sdwan_flow_samples", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.inet "dst_ip", null: false
    t.integer "dst_port"
    t.datetime "flow_end_at", null: false
    t.datetime "flow_start_at", null: false
    t.uuid "ipfix_collector_id", null: false
    t.datetime "observed_at", null: false
    t.bigint "octet_count", default: 0, null: false
    t.bigint "packet_count", default: 0, null: false
    t.integer "protocol", null: false
    t.inet "src_ip", null: false
    t.integer "src_port"
    t.datetime "updated_at", null: false
    t.index ["account_id", "observed_at"], order: { observed_at: :desc }
    t.index ["ipfix_collector_id", "observed_at"], order: { observed_at: :desc }
  end

  create_table "system_sdwan_host_bridges", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "applied_at"
    t.string "bridge_name", limit: 15, null: false
    t.datetime "created_at", null: false
    t.datetime "draining_at"
    t.string "ipv4_cidr", limit: 64
    t.string "ipv6_cidr", limit: 64
    t.string "kind", default: "linux", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "node_instance_id", null: false
    t.datetime "removed_at"
    t.integer "short_id", null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["node_instance_id", "bridge_name"], unique: true
    t.index ["node_instance_id", "short_id"], unique: true
    t.index ["node_instance_id"]
    t.index ["state"]
    t.check_constraint "kind::text = ANY (ARRAY['linux'::character varying::text, 'ovs'::character varying::text])", name: "sdwan_host_bridges_kind_check"
    t.check_constraint "short_id >= 1 AND short_id <= 9999", name: "sdwan_host_bridges_short_id_range"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'draining'::character varying::text, 'removed'::character varying::text])", name: "sdwan_host_bridges_state_check"
  end

  create_table "system_sdwan_host_vrf_assignments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.datetime "draining_at"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "node_instance_id", null: false
    t.datetime "removed_at"
    t.uuid "sdwan_network_id", null: false
    t.integer "short_id", null: false
    t.string "state", default: "pending", null: false
    t.integer "table_id", null: false
    t.datetime "updated_at", null: false
    t.string "vrf_name", limit: 15, null: false
    t.index ["account_id"]
    t.index ["node_instance_id", "sdwan_network_id"], unique: true
    t.index ["node_instance_id", "short_id"], unique: true
    t.index ["node_instance_id", "table_id"], unique: true
    t.index ["node_instance_id", "vrf_name"], unique: true
    t.index ["node_instance_id"]
    t.index ["sdwan_network_id"]
    t.index ["state"]
    t.check_constraint "short_id >= 1 AND short_id <= 9999", name: "sdwan_hva_short_id_range"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'draining'::character varying::text, 'removed'::character varying::text])", name: "sdwan_hva_state_check"
    t.check_constraint "table_id >= 100 AND table_id <= 65535 AND (table_id <> ALL (ARRAY[253, 254, 255]))", name: "sdwan_hva_table_id_range"
  end

  create_table "system_sdwan_ipfix_collectors", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "host", null: false
    t.string "name", null: false
    t.integer "port", default: 4739, null: false
    t.integer "sampling_rate", default: 1, null: false
    t.jsonb "settings", default: {}, null: false
    t.string "state", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id"]
    t.index ["state"]
    t.check_constraint "port >= 1 AND port <= 65535", name: "chk_sdwan_ipfix_port_range"
    t.check_constraint "sampling_rate >= 1", name: "chk_sdwan_ipfix_sampling_min"
    t.check_constraint "state::text = ANY (ARRAY['active'::character varying::text, 'disabled'::character varying::text])", name: "chk_sdwan_ipfix_state"
  end

  create_table "system_sdwan_membership_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "constellation_handle", null: false
    t.datetime "created_at", null: false
    t.text "envelope_json", null: false
    t.datetime "issued_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "not_after", null: false
    t.datetime "not_before", null: false
    t.datetime "refresh_after", null: false
    t.bigint "revision", default: 0, null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "sdwan_network_id", null: false
    t.uuid "sdwan_peer_id", null: false
    t.text "signature_b64", null: false
    t.string "signed_with_vault_path"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["not_after"]
    t.index ["sdwan_network_id"]
    t.index ["sdwan_peer_id", "sdwan_network_id", "revision"]
    t.index ["sdwan_peer_id", "sdwan_network_id"], name: "idx_sdwan_mc_one_active_per_peer_network", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["sdwan_peer_id"]
    t.index ["status"]
    t.check_constraint "not_after > not_before", name: "sdwan_mc_window_ordered"
    t.check_constraint "revision >= 0", name: "sdwan_mc_revision_nonneg"
  end

  create_table "system_sdwan_networks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "advertise_overlay_subnet", default: true, null: false
    t.string "cidr_64", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "last_compiled_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "pod_subnet_prefix"
    t.integer "route_reflector_redundancy", default: 1, null: false
    t.string "routing_protocol", default: "static", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "slug", null: false
    t.string "status", default: "registered", null: false
    t.string "tags", default: [], array: true
    t.datetime "updated_at", null: false
    t.string "vrf_name_template", default: "sdwan-{handle}", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "slug"], unique: true
    t.index ["account_id"]
    t.index ["cidr_64"], unique: true
    t.index ["routing_protocol"]
    t.index ["status"]
  end

  create_table "system_sdwan_ovn_acls", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "action", limit: 16, null: false
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.string "direction", limit: 16, null: false
    t.text "match", null: false
    t.string "name", limit: 63, null: false
    t.integer "priority", default: 1000, null: false
    t.datetime "removed_at"
    t.uuid "sdwan_ovn_logical_switch_id", null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["sdwan_ovn_logical_switch_id", "name"], unique: true
    t.index ["sdwan_ovn_logical_switch_id", "state", "priority", "name"]
    t.index ["sdwan_ovn_logical_switch_id"]
  end

  create_table "system_sdwan_ovn_deployments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "activated_at"
    t.datetime "bootstrapped_at"
    t.datetime "created_at", null: false
    t.datetime "degraded_at"
    t.string "nb_db_endpoint"
    t.string "northd_host"
    t.string "sb_db_endpoint"
    t.jsonb "settings", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], unique: true
    t.index ["status"]
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'bootstrapping'::character varying::text, 'active'::character varying::text, 'degraded'::character varying::text])", name: "sdwan_ovn_deployments_status_check"
  end

  create_table "system_sdwan_ovn_logical_switch_ports", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "activated_at"
    t.jsonb "addresses", default: [], null: false
    t.datetime "created_at", null: false
    t.uuid "host_node_instance_id"
    t.string "kind", default: "vm", null: false
    t.string "mac", limit: 17, null: false
    t.string "name", limit: 63, null: false
    t.datetime "removed_at"
    t.uuid "sdwan_ovn_logical_switch_id", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["host_node_instance_id"]
    t.index ["kind"]
    t.index ["sdwan_ovn_logical_switch_id", "name"], unique: true
    t.index ["sdwan_ovn_logical_switch_id"]
    t.index ["state"]
    t.check_constraint "kind::text = ANY (ARRAY['vm'::character varying::text, 'container'::character varying::text, 'external'::character varying::text])", name: "sdwan_ovn_lsps_kind_check"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'removed'::character varying::text])", name: "sdwan_ovn_lsps_state_check"
  end

  create_table "system_sdwan_ovn_logical_switches", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "activated_at"
    t.string "cidr", limit: 64
    t.datetime "created_at", null: false
    t.string "description"
    t.string "name", limit: 63, null: false
    t.datetime "removed_at"
    t.uuid "sdwan_ovn_deployment_id", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["sdwan_ovn_deployment_id", "name"], unique: true
    t.index ["sdwan_ovn_deployment_id"]
    t.index ["state"]
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'removed'::character varying::text])", name: "sdwan_ovn_lswitches_state_check"
  end

  create_table "system_sdwan_peer_keys", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.string "public_key", null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "rotated_from_id"
    t.uuid "sdwan_peer_id", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["public_key"], unique: true
    t.index ["rotated_from_id"]
    t.index ["sdwan_peer_id"], name: "idx_sdwan_peer_keys_one_active_per_peer", unique: true, where: "(revoked_at IS NULL)"
  end

  create_table "system_sdwan_peers", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "assigned_address", null: false
    t.integer "bgp_local_pref_override"
    t.string "bgp_peer_group"
    t.boolean "bgp_route_reflector_client", default: false, null: false
    t.string "bgp_router_id_override"
    t.jsonb "bgp_session_state", default: {}, null: false
    t.jsonb "capabilities", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "endpoint_host"
    t.string "endpoint_host_v4"
    t.string "endpoint_host_v6"
    t.integer "endpoint_port"
    t.string "lan_subnets", default: [], array: true
    t.datetime "last_compiled_at"
    t.datetime "last_handshake_at"
    t.integer "listen_port", default: 51820, null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "node_instance_id", null: false
    t.boolean "publicly_reachable", default: false, null: false
    t.uuid "sdwan_network_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "assigned_address"], unique: true
    t.index ["account_id"]
    t.index ["bgp_peer_group"]
    t.index ["bgp_route_reflector_client"]
    t.index ["endpoint_host_v4"]
    t.index ["endpoint_host_v6"]
    t.index ["lan_subnets"], name: "index_sdwan_peers_on_lan_subnets", using: :gin
    t.index ["node_instance_id"]
    t.index ["publicly_reachable"]
    t.index ["sdwan_network_id", "node_instance_id"], unique: true
    t.index ["sdwan_network_id"]
    t.index ["status"]
  end

  create_table "system_sdwan_port_mappings", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "description", limit: 255
    t.boolean "enabled", default: true, null: false
    t.datetime "last_compiled_at"
    t.integer "listen_port", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 64, null: false
    t.string "protocol", default: "tcp", null: false
    t.uuid "sdwan_network_id", null: false
    t.uuid "sdwan_peer_id", null: false
    t.uuid "target_peer_id"
    t.integer "target_port"
    t.uuid "target_virtual_ip_id"
    t.datetime "updated_at", null: false
    t.index ["account_id", "sdwan_network_id"]
    t.index ["account_id"]
    t.index ["sdwan_network_id"]
    t.index ["sdwan_peer_id", "listen_port", "protocol"], unique: true
    t.index ["sdwan_peer_id"]
    t.index ["target_peer_id"]
    t.index ["target_virtual_ip_id"]
    t.check_constraint "((target_peer_id IS NOT NULL)::integer + (target_virtual_ip_id IS NOT NULL)::integer) = 1", name: "sdwan_port_mappings_exactly_one_target"
    t.check_constraint "listen_port >= 1 AND listen_port <= 65535", name: "sdwan_port_mappings_listen_port_range"
    t.check_constraint "protocol::text = ANY (ARRAY['tcp'::character varying::text, 'udp'::character varying::text])", name: "sdwan_port_mappings_protocol_enum"
  end

  create_table "system_sdwan_route_leaks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "activated_at"
    t.uuid "approved_by_id"
    t.datetime "created_at", null: false
    t.uuid "dest_network_id", null: false
    t.string "direction", default: "one_way", null: false
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "prefix_filter", default: [], null: false
    t.string "reason"
    t.datetime "revoked_at"
    t.uuid "source_network_id", null: false
    t.string "state", default: "proposed", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["approved_by_id"]
    t.index ["dest_network_id"]
    t.index ["source_network_id", "dest_network_id", "direction"], unique: true
    t.index ["source_network_id"]
    t.index ["state"]
    t.check_constraint "direction::text = ANY (ARRAY['one_way'::character varying::text, 'bidirectional'::character varying::text])", name: "sdwan_route_leaks_direction_check"
    t.check_constraint "source_network_id <> dest_network_id", name: "sdwan_route_leaks_distinct_networks"
    t.check_constraint "state::text = ANY (ARRAY['proposed'::character varying::text, 'active'::character varying::text, 'revoked'::character varying::text])", name: "sdwan_route_leaks_state_check"
  end

  create_table "system_sdwan_route_policies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "description", limit: 255
    t.string "direction", null: false
    t.boolean "enabled", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 64, null: false
    t.string "scope", default: "account", null: false
    t.uuid "scope_resource_id"
    t.jsonb "statements", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], unique: true
    t.index ["account_id", "scope"]
    t.index ["account_id"]
    t.index ["scope", "scope_resource_id"]
    t.check_constraint "direction::text = ANY (ARRAY['import'::character varying::text, 'export'::character varying::text])", name: "sdwan_route_policies_direction_enum"
    t.check_constraint "scope::text = ANY (ARRAY['account'::character varying::text, 'network'::character varying::text, 'peer'::character varying::text])", name: "sdwan_route_policies_scope_enum"
  end

  create_table "system_sdwan_services", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "backend_host"
    t.integer "backend_port", null: false
    t.uuid "backend_vip_id"
    t.datetime "created_at", null: false
    t.string "local_auth_mode", default: "authenticated", null: false
    t.uuid "local_certificate_id"
    t.boolean "local_enabled", default: false, null: false
    t.string "local_required_group"
    t.string "local_required_permission"
    t.boolean "local_strip_prefix", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 255, null: false
    t.string "protocol", default: "https", null: false
    t.string "slug", limit: 64, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "slug"], unique: true
    t.index ["account_id"]
    t.index ["backend_vip_id"]
    t.index ["local_certificate_id"]
    t.check_constraint "backend_port >= 1 AND backend_port <= 65535", name: "sdwan_services_backend_port_range"
    t.check_constraint "backend_vip_id IS NOT NULL OR backend_host IS NOT NULL", name: "sdwan_services_backend_present"
    t.check_constraint "local_auth_mode::text = ANY (ARRAY['public'::character varying::text, 'authenticated'::character varying::text, 'scoped'::character varying::text])", name: "sdwan_services_local_auth_mode_enum"
    t.check_constraint "protocol::text = ANY (ARRAY['https'::character varying::text, 'http'::character varying::text, 'tcp'::character varying::text, 'tls'::character varying::text])", name: "sdwan_services_protocol_enum"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'disabled'::character varying::text])", name: "sdwan_services_status_enum"
  end

  create_table "system_sdwan_subnet_advertisements", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.text "as_path"
    t.datetime "created_at", null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.integer "local_pref"
    t.integer "med"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "origin_peer_id"
    t.string "prefix", null: false
    t.uuid "sdwan_network_id", null: false
    t.uuid "sdwan_peer_id", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.uuid "via_peer_id"
    t.datetime "withdrawn_at"
    t.index ["account_id"]
    t.index ["sdwan_network_id", "prefix"]
    t.index ["sdwan_network_id"]
    t.index ["sdwan_peer_id", "source"]
    t.index ["sdwan_peer_id"]
    t.index ["source"]
    t.index ["withdrawn_at"]
  end

  create_table "system_sdwan_user_devices", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "assigned_address", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.string "label", null: false
    t.datetime "last_downloaded_at"
    t.datetime "last_seen_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.string "public_key", null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.uuid "sdwan_access_grant_id", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["assigned_address"], unique: true
    t.index ["public_key"], unique: true
    t.index ["revoked_at"]
    t.index ["sdwan_access_grant_id", "label"], unique: true
    t.index ["sdwan_access_grant_id"]
  end

  create_table "system_sdwan_virtual_ip_assignments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "assumed_at", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "reason", null: false
    t.datetime "released_at"
    t.uuid "sdwan_peer_id", null: false
    t.uuid "sdwan_virtual_ip_id", null: false
    t.string "triggered_by_signal_correlation_id"
    t.uuid "triggered_by_user_id"
    t.datetime "updated_at", null: false
    t.index ["released_at"]
    t.index ["sdwan_peer_id"]
    t.index ["sdwan_virtual_ip_id", "sdwan_peer_id"], name: "idx_sdwan_vip_assignments_one_active_holder_per_vip_peer", unique: true, where: "(released_at IS NULL)"
    t.index ["sdwan_virtual_ip_id"]
  end

  create_table "system_sdwan_virtual_ips", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.integer "advertised_local_pref", default: 100
    t.integer "advertised_med", default: 0
    t.boolean "anycast", default: false, null: false
    t.string "cidr", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "failover_holder_peer_ids", default: [], array: true
    t.uuid "holder_peer_ids", default: [], array: true
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.uuid "sdwan_network_id", null: false
    t.string "state", default: "pending", null: false
    t.string "tags", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["account_id", "cidr"], unique: true
    t.index ["account_id"]
    t.index ["anycast"]
    t.index ["sdwan_network_id", "name"], unique: true
    t.index ["sdwan_network_id"]
    t.index ["state"]
  end

  create_table "system_service_groups", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.datetime "draining_at"
    t.integer "gid", null: false
    t.string "groupname", limit: 32, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "removed_at"
    t.string "state", limit: 32, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["gid"], unique: true
    t.index ["groupname"], name: "index_system_service_groups_on_groupname_live", unique: true, where: "((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('draining'::character varying)::text]))"
    t.check_constraint "gid >= 70000 AND gid <= 99999", name: "system_service_groups_gid_in_range"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'draining'::character varying::text, 'removed'::character varying::text])", name: "system_service_groups_state_enum"
  end

  create_table "system_service_user_group_memberships", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "service_group_id", null: false
    t.uuid "service_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["service_group_id"]
    t.index ["service_user_id", "service_group_id"], unique: true
  end

  create_table "system_service_users", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.datetime "draining_at"
    t.string "gecos", limit: 256, default: "", null: false
    t.string "home", limit: 256, default: "/var/empty", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "primary_group_id", null: false
    t.datetime "removed_at"
    t.string "shell", limit: 128, default: "/usr/sbin/nologin", null: false
    t.string "state", limit: 32, default: "active", null: false
    t.integer "uid", null: false
    t.datetime "updated_at", null: false
    t.string "username", limit: 32, null: false
    t.index ["primary_group_id"]
    t.index ["uid"], unique: true
    t.index ["username"], name: "index_system_service_users_on_username_live", unique: true, where: "((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('draining'::character varying)::text]))"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'draining'::character varying::text, 'removed'::character varying::text])", name: "system_service_users_state_enum"
    t.check_constraint "uid >= 70000 AND uid <= 99999", name: "system_service_users_uid_in_range"
  end

  create_table "system_slo_definitions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enforces_autonomy", default: false, null: false
    t.decimal "error_rate_max_pct", precision: 5, scale: 2
    t.integer "latency_p99_max_ms"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.uuid "node_module_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "uptime_target_pct", precision: 5, scale: 2
    t.string "window", default: "1d", null: false
    t.index ["node_module_id", "name"], unique: true
    t.index ["node_module_id"]
  end

  create_table "system_storage_assignments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "auto_mount", default: true, null: false
    t.datetime "chown_completed_at"
    t.text "chown_last_error"
    t.integer "chown_previous_gid"
    t.integer "chown_previous_uid"
    t.datetime "chown_started_at"
    t.string "chown_state", limit: 32, default: "complete", null: false
    t.uuid "chown_task_id"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "encryption_mode", default: "inherit", null: false
    t.text "error_message"
    t.uuid "file_storage_id", null: false
    t.datetime "last_mounted_at"
    t.datetime "last_status_at"
    t.jsonb "mount_options", default: {}, null: false
    t.string "mount_path", null: false
    t.uuid "node_instance_id", null: false
    t.string "owner_kind", limit: 32, default: "service_user", null: false
    t.boolean "read_only", default: false, null: false
    t.uuid "sdwan_network_id"
    t.uuid "sdwan_virtual_ip_id"
    t.uuid "service_user_id"
    t.uuid "shared_group_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["chown_state"], name: "index_system_storage_assignments_chown_in_flight", where: "((chown_state)::text <> 'complete'::text)"
    t.index ["file_storage_id", "node_instance_id"], unique: true
    t.index ["file_storage_id"]
    t.index ["node_instance_id", "mount_path"], unique: true
    t.index ["node_instance_id"]
    t.index ["sdwan_network_id"]
    t.index ["sdwan_virtual_ip_id"]
    t.index ["service_user_id"]
    t.index ["shared_group_id"]
    t.check_constraint "chown_state::text = ANY (ARRAY['complete'::character varying::text, 'pending'::character varying::text, 'running'::character varying::text, 'failed'::character varying::text, 'manual_required'::character varying::text])", name: "system_storage_assignments_chown_state_enum"
    t.check_constraint "encryption_mode::text = ANY (ARRAY['inherit'::character varying::text, 'none'::character varying::text, 'fscrypt'::character varying::text, 'luks'::character varying::text, 'client_side_aes'::character varying::text])", name: "system_storage_assignments_encryption_mode_check"
    t.check_constraint "owner_kind::text = 'service_user'::text AND service_user_id IS NOT NULL OR owner_kind::text <> 'service_user'::text AND service_user_id IS NULL", name: "system_storage_assignments_owner_kind_consistency"
    t.check_constraint "owner_kind::text = ANY (ARRAY['service_user'::character varying::text, 'operator'::character varying::text, 'nobody'::character varying::text, 'root'::character varying::text])", name: "system_storage_assignments_owner_kind_enum"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'provisioning'::character varying::text, 'mounted'::character varying::text, 'degraded'::character varying::text, 'unmounting'::character varying::text, 'failed'::character varying::text, 'disabled'::character varying::text])", name: "system_storage_assignments_status_check"
  end

  create_table "system_storage_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "encrypted_credentials"
    t.string "encryption_key_id"
    t.datetime "expires_at"
    t.string "kind", null: false
    t.datetime "last_rotated_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "migrated_to_vault_at"
    t.uuid "node_instance_id", null: false
    t.string "status", default: "issued", null: false
    t.uuid "storage_assignment_id", null: false
    t.datetime "updated_at", null: false
    t.string "vault_path"
    t.index ["node_instance_id"]
    t.index ["storage_assignment_id", "status"]
    t.index ["storage_assignment_id"]
    t.check_constraint "kind::text = ANY (ARRAY['peer_ip_acl'::character varying::text, 'cifs_user_pass'::character varying::text, 'sts_token'::character varying::text, 'tls_cert'::character varying::text, 'webdav_basic'::character varying::text])", name: "system_storage_credentials_kind_check"
    t.check_constraint "status::text = ANY (ARRAY['issued'::character varying::text, 'active'::character varying::text, 'rotating'::character varying::text, 'revoked'::character varying::text, 'expired'::character varying::text, 'failed'::character varying::text])", name: "system_storage_credentials_status_check"
  end

  create_table "system_storage_migrations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "approved_at"
    t.jsonb "audit_log", default: [], null: false
    t.bigint "bytes_copied"
    t.bigint "bytes_total"
    t.bigint "bytes_verified"
    t.datetime "cancelled_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "error_message"
    t.datetime "failed_at"
    t.uuid "initiated_by_user_id"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "node_instance_id", null: false
    t.jsonb "plan", default: {}, null: false
    t.string "role", limit: 64, null: false
    t.string "snapshot_subpath", limit: 512
    t.string "source_subpath", limit: 512
    t.uuid "source_volume_id", null: false
    t.datetime "started_at"
    t.string "status", limit: 32, default: "planned", null: false
    t.string "target_subpath", limit: 512
    t.uuid "target_volume_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"]
    t.index ["account_id"]
    t.index ["initiated_by_user_id"]
    t.index ["node_instance_id"]
    t.index ["source_volume_id"]
    t.index ["status"]
    t.index ["target_volume_id"]
    t.check_constraint "source_volume_id <> target_volume_id", name: "storage_migration_source_ne_target"
  end

  create_table "system_sudoers_grants", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "commands", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "flags", default: [], null: false
    t.string "grant_id", limit: 64, null: false
    t.uuid "node_module_id", null: false
    t.string "runas_group", limit: 32
    t.string "runas_user", limit: 32, default: "root", null: false
    t.uuid "service_user_id", null: false
    t.string "state", limit: 32, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["node_module_id", "grant_id"], unique: true
    t.index ["service_user_id"]
    t.check_constraint "state::text = ANY (ARRAY['active'::character varying::text, 'removed'::character varying::text])", name: "system_sudoers_grants_state_enum"
  end

  create_table "system_tasks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "claimed_by_worker_id"
    t.string "command", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.text "error_message"
    t.jsonb "events", default: [], null: false
    t.boolean "exclusive", default: false, null: false
    t.string "idempotency_key"
    t.uuid "initiated_by_id"
    t.uuid "operable_id"
    t.string "operable_type"
    t.jsonb "options", default: {}, null: false
    t.integer "progress", default: 0, null: false
    t.datetime "scheduled_at"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "idx_system_tasks_idempotency", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id"]
    t.index ["claimed_by_worker_id"]
    t.index ["command"]
    t.index ["completed_at"]
    t.index ["events"], name: "index_system_tasks_on_events", using: :gin
    t.index ["exclusive"]
    t.index ["initiated_by_id"]
    t.index ["operable_type", "operable_id"]
    t.index ["options"], name: "index_system_tasks_on_options", using: :gin
    t.index ["scheduled_at"]
    t.index ["started_at"]
    t.index ["status"]
    t.check_constraint "progress >= 0 AND progress <= 100", name: "system_operations_progress_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'scheduled'::character varying::text, 'running'::character varying::text, 'complete'::character varying::text, 'failed'::character varying::text, 'aborted'::character varying::text, 'cancelled'::character varying::text])", name: "system_operations_status_check"
  end

  create_table "system_template_modules", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "node_module_id", null: false
    t.uuid "node_template_id", null: false
    t.integer "priority", default: 0, null: false
    t.jsonb "recommends_override", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["config"], name: "index_system_template_modules_on_config", using: :gin
    t.index ["enabled"]
    t.index ["node_module_id"]
    t.index ["node_template_id", "node_module_id"], unique: true
    t.index ["node_template_id"]
    t.index ["priority"]
  end

  create_table "system_unclaimed_devices", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "agent_version"
    t.string "architecture"
    t.string "claim_code", null: false
    t.datetime "claimed_at"
    t.uuid "claimed_node_instance_id"
    t.datetime "created_at", null: false
    t.string "discovered_dmi_uuid"
    t.string "discovered_hostname"
    t.string "discovered_mac"
    t.datetime "expires_at", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "platform_hint"
    t.datetime "updated_at", null: false
    t.index ["account_id"]
    t.index ["claim_code"], unique: true
    t.index ["claimed_node_instance_id"]
    t.index ["discovered_mac"]
    t.index ["expires_at"]
  end

    add_foreign_key "ai_provisioning_code_deployments", "system_node_instances", column: "node_instance_id"
    add_foreign_key "devops_docker_hosts", "system_node_instances", column: "node_instance_id", on_delete: :cascade
    add_foreign_key "devops_kubernetes_nodes", "system_node_instances", column: "node_instance_id", on_delete: :cascade
    add_foreign_key "system_acme_certificates", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_acme_certificates", "system_acme_dns_credentials", column: "dns_credential_id", on_delete: :nullify
    add_foreign_key "system_acme_dns_credentials", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_bootstrap_tokens", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_bootstrap_tokens", "system_nodes", column: "node_id"
    add_foreign_key "system_cve_exposures", "system_cves", column: "cve_id"
    add_foreign_key "system_cve_exposures", "system_node_module_versions", column: "node_module_version_id"
    add_foreign_key "system_disk_image_publications", "accounts", column: "account_id"
    add_foreign_key "system_disk_image_publications", "file_objects", column: "file_object_id"
    add_foreign_key "system_disk_image_publications", "file_objects", column: "prior_file_object_id"
    add_foreign_key "system_disk_image_publications", "system_disk_image_webhooks", column: "webhook_id"
    add_foreign_key "system_disk_image_publications", "system_node_platforms", column: "node_platform_id"
    add_foreign_key "system_disk_image_publications", "workers", column: "triggered_by_worker_id"
    add_foreign_key "system_disk_image_webhooks", "accounts", column: "account_id"
    add_foreign_key "system_disk_image_webhooks", "users", column: "created_by_id"
    add_foreign_key "system_federation_audit_shipments", "accounts", column: "account_id"
    add_foreign_key "system_federation_audit_shipments", "system_federation_peers", column: "federation_peer_id"
    add_foreign_key "system_federation_capabilities", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_federation_capabilities", "system_federation_peers", column: "federation_peer_id", on_delete: :cascade
    add_foreign_key "system_federation_grants", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_federation_grants", "system_federation_peers", column: "federation_peer_id", on_delete: :cascade
    add_foreign_key "system_federation_grants", "users", column: "grantor_user_id", on_delete: :restrict
    add_foreign_key "system_federation_network_bridges", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_federation_network_bridges", "system_federation_peers", column: "federation_peer_id", on_delete: :cascade
    add_foreign_key "system_federation_network_bridges", "system_sdwan_networks", column: "sdwan_network_id", on_delete: :restrict
    add_foreign_key "system_federation_peers", "accounts", column: "account_id"
    add_foreign_key "system_federation_peers", "system_federation_peers", column: "parent_peer_id", on_delete: :nullify
    add_foreign_key "system_federation_peers", "system_node_certificates", column: "outbound_certificate_id"
    add_foreign_key "system_federation_schema_compatibility", "accounts", column: "account_id"
    add_foreign_key "system_federation_service_offerings", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_federation_service_offerings", "system_sdwan_services", column: "service_id"
    add_foreign_key "system_federation_service_subscriptions", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_federation_service_subscriptions", "system_acme_certificates", column: "acme_certificate_id", on_delete: :nullify
    add_foreign_key "system_federation_service_subscriptions", "system_federation_grants", column: "federation_grant_id", on_delete: :restrict
    add_foreign_key "system_federation_service_subscriptions", "system_federation_peers", column: "federation_peer_id", on_delete: :cascade
    add_foreign_key "system_fleet_events", "accounts", column: "account_id"
    add_foreign_key "system_fleet_remediation_outcomes", "accounts", column: "account_id"
    add_foreign_key "system_gitops_repositories", "accounts", column: "account_id"
    add_foreign_key "system_gitops_sync_runs", "system_gitops_repositories", column: "gitops_repository_id"
    add_foreign_key "system_instance_mount_points", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_instance_mount_points", "system_node_mount_points", column: "mount_point_id"
    add_foreign_key "system_instance_pools", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_instance_pools", "system_node_templates", column: "node_template_id", on_delete: :restrict
    add_foreign_key "system_instance_pools", "system_provider_instance_types", column: "provider_instance_type_id", on_delete: :nullify
    add_foreign_key "system_instance_pools", "system_provider_regions", column: "provider_region_id", on_delete: :nullify
    add_foreign_key "system_migration_chains", "accounts", column: "account_id"
    add_foreign_key "system_migration_chains", "users", column: "initiated_by_user_id"
    add_foreign_key "system_migration_plan_steps", "system_migrations", column: "migration_id", on_delete: :cascade
    add_foreign_key "system_migrations", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_migrations", "system_federation_peers", column: "destination_peer_id", on_delete: :restrict
    add_foreign_key "system_migrations", "system_migration_chains", column: "migration_chain_id"
    add_foreign_key "system_migrations", "users", column: "initiated_by_user_id", on_delete: :nullify
    add_foreign_key "system_module_artifacts", "system_node_module_versions", column: "node_module_version_id"
    add_foreign_key "system_module_dependencies", "system_node_modules", column: "dependency_id"
    add_foreign_key "system_module_dependencies", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_module_puppet_assignments", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_module_puppet_assignments", "system_puppet_modules", column: "puppet_module_id"
    add_foreign_key "system_module_service_dependencies", "system_module_services", column: "depends_on_module_service_id", on_delete: :cascade
    add_foreign_key "system_module_service_dependencies", "system_module_services", column: "module_service_id", on_delete: :cascade
    add_foreign_key "system_module_services", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_module_services", "system_node_modules", column: "node_module_id", on_delete: :cascade
    add_foreign_key "system_module_services", "system_service_users", column: "service_user_id"
    add_foreign_key "system_module_user_declarations", "system_node_modules", column: "node_module_id", on_delete: :cascade
    add_foreign_key "system_module_user_declarations", "system_service_groups", column: "service_group_id", on_delete: :cascade
    add_foreign_key "system_module_user_declarations", "system_service_users", column: "service_user_id", on_delete: :cascade
    add_foreign_key "system_mount_encryption_keys", "system_node_instances", column: "node_instance_id", on_delete: :nullify
    add_foreign_key "system_mount_encryption_keys", "system_storage_assignments", column: "storage_assignment_id", on_delete: :cascade
    add_foreign_key "system_node_architectures", "file_objects", column: "image_file_object_id"
    add_foreign_key "system_node_architectures", "file_objects", column: "kernel_file_object_id"
    add_foreign_key "system_node_architectures", "file_objects", column: "ramdisk_file_object_id"
    add_foreign_key "system_node_certificates", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_node_certificates", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_node_instance_peers", "accounts", column: "account_id"
    add_foreign_key "system_node_instance_peers", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_node_instances", "accounts", column: "account_id"
    add_foreign_key "system_node_instances", "system_bootstrap_tokens", column: "enrollment_token_id"
    add_foreign_key "system_node_instances", "system_instance_pools", column: "instance_pool_id", on_delete: :nullify
    add_foreign_key "system_node_instances", "system_nodes", column: "node_id"
    add_foreign_key "system_node_instances", "system_provider_instance_types", column: "provider_instance_type_id"
    add_foreign_key "system_node_instances", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_node_module_assignments", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_node_module_assignments", "system_nodes", column: "node_id"
    add_foreign_key "system_node_module_assignments", "system_template_modules", column: "source_template_module_id", on_delete: :nullify
    add_foreign_key "system_node_module_categories", "accounts", column: "account_id"
    add_foreign_key "system_node_module_categories", "system_node_module_categories", column: "config_category_id"
    add_foreign_key "system_node_module_categories", "system_node_module_categories", column: "instance_category_id"
    add_foreign_key "system_node_module_categories", "system_node_module_categories", column: "parent_id"
    add_foreign_key "system_node_module_copy_paths", "accounts", column: "account_id"
    add_foreign_key "system_node_module_versions", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_node_module_versions", "users", column: "created_by_id"
    add_foreign_key "system_node_modules", "accounts", column: "account_id"
    add_foreign_key "system_node_modules", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_node_modules", "system_node_module_categories", column: "category_id"
    add_foreign_key "system_node_modules", "system_node_module_copy_paths", column: "copy_path_id"
    add_foreign_key "system_node_modules", "system_node_module_versions", column: "current_version_id"
    add_foreign_key "system_node_modules", "system_node_modules", column: "parent_module_id"
    add_foreign_key "system_node_modules", "system_node_platforms", column: "node_platform_id"
    add_foreign_key "system_node_modules", "system_nodes", column: "node_id"
    add_foreign_key "system_node_mount_points", "accounts", column: "account_id"
    add_foreign_key "system_node_platforms", "accounts", column: "account_id"
    add_foreign_key "system_node_platforms", "system_node_architectures", column: "node_architecture_id"
    add_foreign_key "system_node_scripts", "accounts", column: "account_id"
    add_foreign_key "system_node_templates", "accounts", column: "account_id"
    add_foreign_key "system_node_templates", "system_node_platforms", column: "node_platform_id"
    add_foreign_key "system_nodes", "accounts", column: "account_id"
    add_foreign_key "system_nodes", "system_node_templates", column: "node_template_id"
    add_foreign_key "system_nodes", "workers", column: "worker_id"
    add_foreign_key "system_package_module_links", "system_node_modules", column: "node_module_id", on_delete: :cascade
    add_foreign_key "system_package_module_links", "system_package_repositories", column: "package_repository_id", on_delete: :restrict
    add_foreign_key "system_package_repositories", "accounts", column: "account_id"
    add_foreign_key "system_package_repositories", "users", column: "created_by_id", on_delete: :restrict
    add_foreign_key "system_package_repository_platforms", "system_node_platforms", column: "node_platform_id", on_delete: :cascade
    add_foreign_key "system_package_repository_platforms", "system_package_repositories", column: "package_repository_id", on_delete: :cascade
    add_foreign_key "system_packages", "system_package_repositories", column: "package_repository_id", on_delete: :cascade
    add_foreign_key "system_peer_capability_revocations", "accounts", column: "account_id"
    add_foreign_key "system_peer_capability_signing_keys", "accounts", column: "account_id"
    add_foreign_key "system_peer_capability_signing_keys", "system_peer_capability_signing_keys", column: "rotated_from_id"
    add_foreign_key "system_platform_deployments", "accounts", column: "account_id", on_delete: :cascade
    add_foreign_key "system_platform_deployments", "system_node_templates", column: "node_template_id", on_delete: :restrict
    add_foreign_key "system_platform_deployments", "system_sdwan_virtual_ips", column: "virtual_ip_id", on_delete: :nullify
    add_foreign_key "system_project_metrics", "ai_missions", column: "mission_id"
    add_foreign_key "system_provider_availability_zones", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_provider_connections", "accounts", column: "account_id"
    add_foreign_key "system_provider_connections", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_credentials", "accounts", column: "account_id"
    add_foreign_key "system_provider_credentials", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_instance_types", "accounts", column: "account_id"
    add_foreign_key "system_provider_instance_types", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_network_subnets", "system_provider_availability_zones", column: "availability_zone_id"
    add_foreign_key "system_provider_network_subnets", "system_provider_networks", column: "network_id"
    add_foreign_key "system_provider_networks", "accounts", column: "account_id"
    add_foreign_key "system_provider_networks", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_provider_networks", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_regions", "accounts", column: "account_id"
    add_foreign_key "system_provider_regions", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_volume_members", "system_provider_volumes", column: "provider_volume_id"
    add_foreign_key "system_provider_volume_snapshots", "accounts", column: "account_id"
    add_foreign_key "system_provider_volume_snapshots", "system_provider_volumes", column: "volume_id"
    add_foreign_key "system_provider_volume_types", "accounts", column: "account_id"
    add_foreign_key "system_provider_volume_types", "system_providers", column: "provider_id"
    add_foreign_key "system_provider_volumes", "accounts", column: "account_id"
    add_foreign_key "system_provider_volumes", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_provider_volumes", "system_provider_availability_zones", column: "availability_zone_id"
    add_foreign_key "system_provider_volumes", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_provider_volumes", "system_provider_volume_types", column: "volume_type_id"
    add_foreign_key "system_providers", "accounts", column: "account_id"
    add_foreign_key "system_puppet_modules", "accounts", column: "account_id"
    add_foreign_key "system_puppet_resources", "system_puppet_modules", column: "puppet_module_id"
    add_foreign_key "system_region_instance_types", "system_provider_instance_types", column: "provider_instance_type_id"
    add_foreign_key "system_region_instance_types", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_region_volume_types", "system_provider_regions", column: "provider_region_id"
    add_foreign_key "system_region_volume_types", "system_provider_volume_types", column: "volume_type_id"
    add_foreign_key "system_sdwan_access_grants", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_access_grants", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_access_grants", "users", column: "granted_by_id"
    add_foreign_key "system_sdwan_access_grants", "users", column: "user_id"
    add_foreign_key "system_sdwan_account_bgps", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_bgp_sessions", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_bgp_sessions", "system_sdwan_peers", column: "neighbor_peer_id"
    add_foreign_key "system_sdwan_bgp_sessions", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_configurations", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_constellation_signing_keys", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_constellation_signing_keys", "system_sdwan_constellation_signing_keys", column: "rotated_from_id"
    add_foreign_key "system_sdwan_firewall_rules", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_firewall_rules", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_flow_samples", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_flow_samples", "system_sdwan_ipfix_collectors", column: "ipfix_collector_id", on_delete: :cascade
    add_foreign_key "system_sdwan_host_bridges", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_host_bridges", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_sdwan_host_vrf_assignments", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_host_vrf_assignments", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_sdwan_host_vrf_assignments", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_ipfix_collectors", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_membership_credentials", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_membership_credentials", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_membership_credentials", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_networks", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_ovn_acls", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_ovn_acls", "system_sdwan_ovn_logical_switches", column: "sdwan_ovn_logical_switch_id", on_delete: :cascade
    add_foreign_key "system_sdwan_ovn_deployments", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_ovn_logical_switch_ports", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_ovn_logical_switch_ports", "system_node_instances", column: "host_node_instance_id"
    add_foreign_key "system_sdwan_ovn_logical_switch_ports", "system_sdwan_ovn_logical_switches", column: "sdwan_ovn_logical_switch_id"
    add_foreign_key "system_sdwan_ovn_logical_switches", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_ovn_logical_switches", "system_sdwan_ovn_deployments", column: "sdwan_ovn_deployment_id"
    add_foreign_key "system_sdwan_peer_keys", "system_sdwan_peer_keys", column: "rotated_from_id"
    add_foreign_key "system_sdwan_peer_keys", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_peers", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_peers", "system_node_instances", column: "node_instance_id", on_delete: :cascade
    add_foreign_key "system_sdwan_peers", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_port_mappings", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_port_mappings", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_port_mappings", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_port_mappings", "system_sdwan_peers", column: "target_peer_id"
    add_foreign_key "system_sdwan_port_mappings", "system_sdwan_virtual_ips", column: "target_virtual_ip_id"
    add_foreign_key "system_sdwan_route_leaks", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_route_leaks", "system_sdwan_networks", column: "dest_network_id"
    add_foreign_key "system_sdwan_route_leaks", "system_sdwan_networks", column: "source_network_id"
    add_foreign_key "system_sdwan_route_leaks", "users", column: "approved_by_id"
    add_foreign_key "system_sdwan_route_policies", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_services", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_services", "system_acme_certificates", column: "local_certificate_id"
    add_foreign_key "system_sdwan_services", "system_sdwan_virtual_ips", column: "backend_vip_id"
    add_foreign_key "system_sdwan_subnet_advertisements", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_subnet_advertisements", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_sdwan_subnet_advertisements", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_user_devices", "system_sdwan_access_grants", column: "sdwan_access_grant_id"
    add_foreign_key "system_sdwan_virtual_ip_assignments", "system_sdwan_peers", column: "sdwan_peer_id"
    add_foreign_key "system_sdwan_virtual_ip_assignments", "system_sdwan_virtual_ips", column: "sdwan_virtual_ip_id"
    add_foreign_key "system_sdwan_virtual_ips", "accounts", column: "account_id"
    add_foreign_key "system_sdwan_virtual_ips", "system_sdwan_networks", column: "sdwan_network_id"
    add_foreign_key "system_service_user_group_memberships", "system_service_groups", column: "service_group_id", on_delete: :cascade
    add_foreign_key "system_service_user_group_memberships", "system_service_users", column: "service_user_id", on_delete: :cascade
    add_foreign_key "system_service_users", "system_service_groups", column: "primary_group_id"
    add_foreign_key "system_slo_definitions", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_storage_assignments", "accounts", column: "account_id"
    add_foreign_key "system_storage_assignments", "system_node_instances", column: "node_instance_id", on_delete: :cascade
    add_foreign_key "system_storage_assignments", "system_sdwan_networks", column: "sdwan_network_id", on_delete: :nullify
    add_foreign_key "system_storage_assignments", "system_sdwan_virtual_ips", column: "sdwan_virtual_ip_id", on_delete: :nullify
    add_foreign_key "system_storage_assignments", "system_service_groups", column: "shared_group_id"
    add_foreign_key "system_storage_assignments", "system_service_users", column: "service_user_id"
    add_foreign_key "system_storage_credentials", "system_node_instances", column: "node_instance_id", on_delete: :cascade
    add_foreign_key "system_storage_credentials", "system_storage_assignments", column: "storage_assignment_id", on_delete: :cascade
    add_foreign_key "system_storage_migrations", "accounts", column: "account_id"
    add_foreign_key "system_storage_migrations", "system_node_instances", column: "node_instance_id"
    add_foreign_key "system_storage_migrations", "system_provider_volumes", column: "source_volume_id"
    add_foreign_key "system_storage_migrations", "system_provider_volumes", column: "target_volume_id"
    add_foreign_key "system_storage_migrations", "users", column: "initiated_by_user_id"
    add_foreign_key "system_sudoers_grants", "system_node_modules", column: "node_module_id", on_delete: :cascade
    add_foreign_key "system_sudoers_grants", "system_service_users", column: "service_user_id", on_delete: :cascade
    add_foreign_key "system_tasks", "accounts", column: "account_id"
    add_foreign_key "system_tasks", "users", column: "initiated_by_id"
    add_foreign_key "system_tasks", "workers", column: "claimed_by_worker_id", on_delete: :nullify
    add_foreign_key "system_template_modules", "system_node_modules", column: "node_module_id"
    add_foreign_key "system_template_modules", "system_node_templates", column: "node_template_id"
    add_foreign_key "system_unclaimed_devices", "accounts", column: "account_id"
    add_foreign_key "system_unclaimed_devices", "system_node_instances", column: "claimed_node_instance_id"
  end
end
