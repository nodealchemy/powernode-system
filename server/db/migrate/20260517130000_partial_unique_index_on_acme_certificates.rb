# frozen_string_literal: true

# Replaces the broad (account_id, common_name) unique index with a
# partial index that only enforces uniqueness on non-terminal rows.
#
# Without this, the model's uniqueness validation (which already scopes
# on `where.not(status: TERMINAL_STATUSES)`) passes, but the DB index
# still rejects the insert with PG::UniqueViolation. The model and the
# DB constraint must agree, or the controller's create path raises a
# 500 instead of a 422 — which is what surfaced during P2.5.7.
#
# AcmeCertificate::TERMINAL_STATUSES is currently %w[revoked]; if it
# grows to include 'expired' or others, regenerate this index to
# match.
class PartialUniqueIndexOnAcmeCertificates < ActiveRecord::Migration[8.1]
  def up
    remove_index :system_acme_certificates,
                 name: "idx_acme_certs_acct_cn_unique",
                 if_exists: true
    add_index :system_acme_certificates, [ :account_id, :common_name ],
              unique: true,
              where: "status <> 'revoked'",
              name: "idx_acme_certs_acct_cn_unique_active"
  end

  def down
    remove_index :system_acme_certificates,
                 name: "idx_acme_certs_acct_cn_unique_active",
                 if_exists: true
    add_index :system_acme_certificates, [ :account_id, :common_name ],
              unique: true,
              name: "idx_acme_certs_acct_cn_unique"
  end
end
