# frozen_string_literal: true

# IMP-c7e9b31f7498 (D14) - images are generic per platform and are published
# through System::DiskImagePublication / the NodePlatform pointer. The only
# writer of NodeArchitecture's kernel / ramdisk / image FileObject pointers
# (ImageCreationService) is gone and the dev census found 0 populated rows, so
# the three FK columns, their indexes and their foreign keys are dropped.
#
# Reversible: down restores the columns, indexes and NO ACTION foreign keys
# exactly as the baseline defined them (data is not restorable; it was empty).
# Guarded by *_exists? because server/db/schema.rb carries the system tables.
class RemoveBootFileObjectFksFromSystemNodeArchitectures < ActiveRecord::Migration[8.1]
  COLUMNS = %i[kernel_file_object_id ramdisk_file_object_id image_file_object_id].freeze

  def up
    COLUMNS.each do |col|
      if foreign_key_exists?(:system_node_architectures, :file_objects, column: col)
        remove_foreign_key :system_node_architectures, :file_objects, column: col
      end
      remove_index :system_node_architectures, col if index_exists?(:system_node_architectures, col)
      remove_column :system_node_architectures, col if column_exists?(:system_node_architectures, col)
    end
  end

  def down
    COLUMNS.each do |col|
      add_column :system_node_architectures, col, :uuid unless column_exists?(:system_node_architectures, col)
      add_index :system_node_architectures, col unless index_exists?(:system_node_architectures, col)
      unless foreign_key_exists?(:system_node_architectures, :file_objects, column: col)
        add_foreign_key :system_node_architectures, :file_objects, column: col
      end
    end
  end
end
