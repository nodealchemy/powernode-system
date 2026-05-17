# frozen_string_literal: true

# Widens the DB-level CHECK constraint on
# system_provider_volume_types.volume_type to include network-filesystem
# transport types (nfs, iscsi, smb). The model's VOLUME_TYPES constant
# was already widened; this brings the DB layer in sync so writes don't
# fail with PG::CheckViolation.
#
# Reference: VOL.4 — add NFS as a first-class volume type alongside the
# existing AWS-EBS-derived block types.
class ExpandProviderVolumeTypesCheck < ActiveRecord::Migration[8.1]
  TABLE = :system_provider_volume_types
  OLD_CONSTRAINT = "system_provider_volume_types_type_check"

  def up
    execute "ALTER TABLE #{TABLE} DROP CONSTRAINT IF EXISTS #{OLD_CONSTRAINT}"
    execute <<~SQL
      ALTER TABLE #{TABLE}
      ADD CONSTRAINT #{OLD_CONSTRAINT}
      CHECK (volume_type IN (
        'gp2','gp3','io1','io2','st1','sc1',
        'standard','ssd','hdd',
        'nfs','iscsi','smb',
        'custom'
      ))
    SQL
  end

  def down
    execute "ALTER TABLE #{TABLE} DROP CONSTRAINT IF EXISTS #{OLD_CONSTRAINT}"
    execute <<~SQL
      ALTER TABLE #{TABLE}
      ADD CONSTRAINT #{OLD_CONSTRAINT}
      CHECK (volume_type IN (
        'gp2','gp3','io1','io2','st1','sc1',
        'standard','ssd','hdd','custom'
      ))
    SQL
  end
end
