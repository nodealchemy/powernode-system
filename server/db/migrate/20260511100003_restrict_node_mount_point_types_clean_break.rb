# frozen_string_literal: true

class RestrictNodeMountPointTypesCleanBreak < ActiveRecord::Migration[8.0]
  # Phase S2, Decision 2 (clean break): storage-backed mount types (nfs|cifs|efs|ebs|s3fs)
  # are subsumed by System::StorageAssignment. NodeMountPoint keeps responsibility
  # only for synthetic mounts (tmpfs|bind|custom). Operators with existing rows of
  # the dropped types must reassign through the new StorageAssignment UI before
  # this migration applies — the up step raises otherwise.
  def up
    blocked = ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM system_node_mount_points WHERE mount_type IN ('nfs','cifs','efs','ebs','s3fs')"
    ).to_i

    if blocked.positive?
      raise <<~MSG
        Cannot apply: #{blocked} system_node_mount_points row(s) still use mount_type IN (nfs|cifs|efs|ebs|s3fs).
        These types are now owned by System::StorageAssignment. Reassign these mounts through the new
        Storage Provider assignment UI, then re-run the migration.

        Helper: rake system:storage:show_pending_migrations
      MSG
    end

    # Find and drop whatever name the existing CHECK constraint has — schema-init
    # migration registered it inline, so the name follows postgres's autogen pattern.
    execute <<~SQL
      DO $$
      DECLARE
        constraint_record RECORD;
      BEGIN
        FOR constraint_record IN
          SELECT conname FROM pg_constraint
          WHERE conrelid = 'system_node_mount_points'::regclass
            AND contype = 'c'
            AND pg_get_constraintdef(oid) ILIKE '%mount_type%'
        LOOP
          EXECUTE 'ALTER TABLE system_node_mount_points DROP CONSTRAINT ' || quote_ident(constraint_record.conname);
        END LOOP;
      END $$;
    SQL

    add_check_constraint :system_node_mount_points,
      "mount_type IN ('tmpfs', 'bind', 'custom')",
      name: "system_node_mount_points_type_check"
  end

  def down
    remove_check_constraint :system_node_mount_points,
      name: "system_node_mount_points_type_check"

    add_check_constraint :system_node_mount_points,
      "mount_type IN ('nfs', 'cifs', 'tmpfs', 'bind', 'efs', 'ebs', 'custom')",
      name: "system_node_mount_points_type_check"
  end
end
