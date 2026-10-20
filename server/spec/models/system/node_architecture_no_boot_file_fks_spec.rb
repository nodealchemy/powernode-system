# frozen_string_literal: true

require 'rails_helper'

# IMP-c7e9b31f7498 (D14): images are generic per platform and live on
# DiskImagePublication / NodePlatform. NodeArchitecture no longer carries
# kernel / ramdisk / image FileObject pointers; census of columns and readers.
RSpec.describe 'NodeArchitecture boot-file FK removal (census)', type: :model do
  let(:removed) { %w[kernel_file_object_id ramdisk_file_object_id image_file_object_id] }
  let(:root) { Rails.root.join('..', 'extensions', 'system', 'server') }

  it 'has none of the three file_object columns' do
    expect(System::NodeArchitecture.column_names & removed).to be_empty
  end

  it 'has no file_objects foreign keys on system_node_architectures' do
    fk_cols = ActiveRecord::Base.connection.foreign_keys('system_node_architectures').map(&:column)
    expect(fk_cols & removed).to be_empty
  end

  it 'has no boot-image file associations or predicates' do
    %i[kernel_file_object ramdisk_file_object image_file_object].each do |assoc|
      expect(System::NodeArchitecture.reflect_on_association(assoc)).to be_nil
    end
    %i[has_kernel? has_ramdisk? has_image? boot_ready?].each do |m|
      expect(System::NodeArchitecture.method_defined?(m)).to be(false), "still defines #{m}"
    end
  end

  it 'serializer does not expose the fields' do
    json = System::NodeArchitectureSerializer.new(create(:system_node_architecture)).as_json
    expect(json.keys.map(&:to_s) & removed).to be_empty
  end

  it 'no app code reads the removed columns' do
    files = Dir[root.join('app', '**', '*.rb')] + Dir[root.join('lib', '**', '*.rb')]
    offenders = files.select { |f| File.read(f).match?(/(kernel|ramdisk)_file_object|(?<!disk_)image_file_object/) }
    expect(offenders).to be_empty
  end

  it 'FileErasureReferents no longer consults node architectures' do
    expect(System::FileErasureReferents::HOLDERS.map(&:first)).not_to include('held_by_system_node_architecture')
  end
end
