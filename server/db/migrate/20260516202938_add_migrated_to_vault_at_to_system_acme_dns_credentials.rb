# frozen_string_literal: true

# P2.5.8 follow-up — adds `migrated_to_vault_at` to system_acme_dns_credentials.
#
# The Security::VaultCredentialProvider concern (and provider service) sets
# this timestamp on every successful Vault write so operators can tell, at a
# glance, when a credential last landed in Vault. The original P2.5.1
# migration only added `vault_path_credentials` (table-specific path field)
# and missed the generic timestamp — making `store_credential` blow up with
# UnknownAttributeError on its `update!(migrated_to_vault_at: ...)` call.
#
# Also aliases the generic `vault_path` ↔ `vault_path_credentials` so the
# concern's reader/writer dispatch hits the right column. The alias lives
# in the model (see System::AcmeDnsCredential#vault_path); this migration
# just adds the timestamp column.
class AddMigratedToVaultAtToSystemAcmeDnsCredentials < ActiveRecord::Migration[8.0]
  def change
    add_column :system_acme_dns_credentials, :migrated_to_vault_at, :datetime
    add_index  :system_acme_dns_credentials, :migrated_to_vault_at,
               where: "migrated_to_vault_at IS NOT NULL",
               name: "index_acme_dns_credentials_on_migrated_to_vault_at"
  end
end
