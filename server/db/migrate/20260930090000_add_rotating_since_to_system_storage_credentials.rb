# frozen_string_literal: true

# IMP-a366d6fb6b80 - when a storage credential entered "rotating".
#
# Since IMP-e48612a32273 a scheme-crossing SMB rotation leaves the OUTGOING
# credential "rotating" (its samba user still live) until the consumer node
# confirms a remount. Nothing recorded WHEN that began, so nothing could bound
# it: an offline, wedged, deleted-without-teardown or deliberately silent node
# kept the old samba user and password valid forever.
# System::Storage::RotatingCredentialSweeper reads this column to retire a
# credential that has been rotating longer than the operator's window.
#
# Nullable, and stays NULL for every status other than "rotating" until a row
# passes through it (StorageCredential#mark_rotating! stamps it). The value is
# kept after the credential is revoked: it records when the rotation began.
#
# BACKFILL: every row already "rotating" is stamped with the migration's own
# time, NOT its updated_at. updated_at is when the row was last touched, which
# for a credential that has been stuck for weeks is weeks ago; stamping it
# would make the very first sweep after deploy retire every legacy credential
# at once, cutting off consumers that were only waiting on a slow remount.
# The migration time gives each legacy row one full window of grace and then
# bounds it, which is the property the finding asks for. The sweeper also
# stamps any "rotating" row it finds still NULL (a row written by a path that
# predates this column's deploy), so no row can be left un-timed either way.
#
# Guarded by column_exists? because server/db/schema.rb already carries the
# column: a fresh schema:load followed by migrate must not fail on it.
class AddRotatingSinceToSystemStorageCredentials < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:system_storage_credentials, :rotating_since)
      add_column :system_storage_credentials, :rotating_since, :datetime
    end

    execute(<<~SQL.squish)
      UPDATE system_storage_credentials
      SET rotating_since = NOW()
      WHERE status = 'rotating' AND rotating_since IS NULL
    SQL

    # The sweep filters status = 'rotating' AND rotating_since <= cutoff; the
    # existing (storage_assignment_id, status) index serves the per-assignment
    # lookup, and the sensor's account-wide scan is over a set that is empty in
    # steady state, so no extra index is warranted.
  end

  def down
    remove_column :system_storage_credentials, :rotating_since if column_exists?(:system_storage_credentials, :rotating_since)
  end
end
