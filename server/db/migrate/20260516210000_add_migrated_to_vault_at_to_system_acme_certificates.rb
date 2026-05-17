# frozen_string_literal: true

# P2.5.7 follow-up — mirrors the AcmeDnsCredentials version. Adds the
# generic `migrated_to_vault_at` timestamp that
# Security::VaultCredentialProvider writes on every successful Vault
# put. The original P2.5.1 migration omitted this; without it,
# store_credential's `record.update!(migrated_to_vault_at: ...)` call
# raises UnknownAttributeError, breaking cert issuance.
class AddMigratedToVaultAtToSystemAcmeCertificates < ActiveRecord::Migration[8.0]
  def change
    add_column :system_acme_certificates, :migrated_to_vault_at, :datetime
    add_index  :system_acme_certificates, :migrated_to_vault_at,
               where: "migrated_to_vault_at IS NOT NULL",
               name: "index_acme_certificates_on_migrated_to_vault_at"
  end
end
