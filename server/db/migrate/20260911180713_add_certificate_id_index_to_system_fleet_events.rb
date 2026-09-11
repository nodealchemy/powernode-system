# frozen_string_literal: true

# The component drawer's per-component signals view filters fleet events by
# the typed certificate_id column, one certificate at a time. node_instance_id
# and node_module_id already have indexes; certificate_id had none, so each
# acme_certificate drawer read scanned the account's whole event window.
#
# PARTIAL (certificate_id IS NOT NULL): almost no fleet event names a
# certificate, and a NULL column means "not recorded", which the filter never
# matches, so NULL rows only cost index space.
#
# Built CONCURRENTLY because system_fleet_events is the ledger every sensor,
# step and decision writes to, and live installs auto-apply migrations: a plain
# CREATE INDEX would block every emission for the whole build. Through
# Powernode::MigrationHelpers::ConcurrentIndex rather than `if_not_exists:`,
# which would silently stamp over an invalid leftover from a failed concurrent
# build. `up`/`down` because the helper reads the catalog and cannot be
# recorded for automatic reversal.
class AddCertificateIdIndexToSystemFleetEvents < ActiveRecord::Migration[8.1]
  include Powernode::MigrationHelpers::ConcurrentIndex

  disable_ddl_transaction!

  INDEX_NAME = "index_system_fleet_events_on_certificate_id"

  def up
    add_index_concurrently :system_fleet_events, :certificate_id,
                           name: INDEX_NAME,
                           where: "certificate_id IS NOT NULL"
  end

  def down
    remove_index :system_fleet_events,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
