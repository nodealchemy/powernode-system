# frozen_string_literal: true

# Adds unique indexes that match the model-level uniqueness validations
# added in the same sweep (audit S5). The validations alone allow racing
# inserts; only a database-level unique index makes the constraint
# enforceable under concurrent provider sync jobs.
#
# Scopes:
#   - system_provider_regions:        unique on (account_id, provider_id, lower(name))
#   - system_provider_instance_types: unique on (account_id, provider_id, lower(name))
#   - system_provider_availability_zones: unique on (provider_region_id, lower(name))
#
# Existing data: catalog rows are populated by Providers::CatalogSyncService
# (idempotent upserts), so duplicates should not exist. If a duplicate
# does exist (manual seeding gone wrong), the migration will fail with a
# clear PG error pointing at the offending rows — operator can dedup
# manually before re-running.
class AddUniqueIndexesToProviderCatalog < ActiveRecord::Migration[8.0]
  def up
    add_index :system_provider_regions,
              "account_id, provider_id, LOWER(name)",
              unique: true,
              name: "idx_uniq_system_provider_regions_account_provider_name"

    add_index :system_provider_instance_types,
              "account_id, provider_id, LOWER(name)",
              unique: true,
              name: "idx_uniq_system_provider_instance_types_account_provider_name"

    add_index :system_provider_availability_zones,
              "provider_region_id, LOWER(name)",
              unique: true,
              name: "idx_uniq_system_provider_availability_zones_region_name"
  end

  def down
    remove_index :system_provider_regions,
                 name: "idx_uniq_system_provider_regions_account_provider_name"
    remove_index :system_provider_instance_types,
                 name: "idx_uniq_system_provider_instance_types_account_provider_name"
    remove_index :system_provider_availability_zones,
                 name: "idx_uniq_system_provider_availability_zones_region_name"
  end
end
