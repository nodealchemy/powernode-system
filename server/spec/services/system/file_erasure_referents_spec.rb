# frozen_string_literal: true

require "rails_helper"

# IMP-d97f6e3bbc2b — the system extension's side of core's
# FileManagement::ErasureReferentRegistry seam. Six columns in this
# extension point at file_objects: five through NO ACTION foreign keys with
# no inverse association (system_disk_image_publications.file_object_id /
# prior_file_object_id, system_node_architectures.kernel_file_object_id /
# ramdisk_file_object_id / image_file_object_id) and one unconstrained
# pointer (system_node_platforms.disk_image_file_object_id). Every one of
# them binds a platform boot/rollback artifact, so the posture is HOLD: a
# GDPR erasure refuses the file with a reason naming the holder, instead of
# nullifying a boot-image pointer underneath a running fleet. Core's
# category policy already keeps `disk_image` / `system` files out of an
# erasure's scope; this is the guard for a personal-category upload an
# operator promoted into one of these roles.
RSpec.describe System::FileErasureReferents do
  let(:account) { create(:account) }
  let(:storage) { create(:file_storage, account: account) }
  let(:provider) { instance_double(StorageProviders::LocalStorage, delete_file: true, initialize_storage: true) }

  before do
    allow(Audit::LogIntegrityService).to receive(:apply_integrity).and_return(true)
    allow(StorageProviderFactory).to receive(:create).and_return(provider)
  end

  def upload(**attrs)
    create(:file_object, account: account, storage: storage, **attrs)
  end

  describe ".call(:holds, ids)" do
    it "names every file an architecture, a publication or a platform points at, and nothing else" do
      kernel = upload
      ramdisk = upload
      image = upload
      published = upload
      prior = upload
      platform_image = upload
      free = upload

      arch = create(:system_node_architecture)
      arch.update_columns(kernel_file_object_id: kernel.id, ramdisk_file_object_id: ramdisk.id,
                          image_file_object_id: image.id)
      pub = create(:system_disk_image_publication, account: account)
      pub.update_columns(file_object_id: published.id, prior_file_object_id: prior.id)
      pub.node_platform.update_columns(disk_image_file_object_id: platform_image.id)

      ids = [ kernel, ramdisk, image, published, prior, platform_image, free ].map(&:id)
      held = described_class.call(:holds, ids)

      expect(held).to eq(
        kernel.id => "held_by_system_node_architecture",
        ramdisk.id => "held_by_system_node_architecture",
        image.id => "held_by_system_node_architecture",
        published.id => "held_by_system_disk_image_publication",
        prior.id => "held_by_system_disk_image_publication",
        platform_image.id => "held_by_system_node_platform"
      )
    end

    it "holds nothing for an empty batch without querying" do
      expect(System::NodeArchitecture).not_to receive(:where)

      expect(described_class.call(:holds, [])).to eq({})
    end
  end

  describe ".call(:release, file_object)" do
    it "releases nothing — a boot-image pointer is never nullified by an erasure" do
      kernel = upload
      arch = create(:system_node_architecture)
      arch.update_columns(kernel_file_object_id: kernel.id)

      expect(described_class.call(:release, kernel)).to be_nil
      expect(arch.reload.kernel_file_object_id).to eq(kernel.id)
    end
  end

  describe "through core's erasure (integration)" do
    it "refuses a personal upload promoted to a kernel image, with the reason, and never touches it" do
      user = create(:user, account: account)
      kernel = upload(uploaded_by: user, category: "user_upload")
      plain = upload(uploaded_by: user, category: "user_upload")
      arch = create(:system_node_architecture)
      arch.update_columns(kernel_file_object_id: kernel.id)

      result = FileManagement::Erasure.call(
        scope: FileManagement::Object.where(account_id: account.id, uploaded_by_id: user.id)
      )

      expect(result.erased_count).to eq(1)
      expect(result.failures).to contain_exactly(
        hash_including(id: kernel.id, kind: "held", reason: "held_by_system_node_architecture")
      )
      expect(FileManagement::Object.exists?(kernel.id)).to be true
      expect(FileManagement::Object.exists?(plain.id)).to be false
      expect(arch.reload.kernel_file_object_id).to eq(kernel.id)
    end

    it "is the registered handler, so the hold does not depend on the FK backstop" do
      expect(FileManagement::ErasureReferentRegistry.registered?(:system_boot_images)).to be true
      handler = FileManagement::ErasureReferentRegistry.handlers[:system_boot_images]
      file = upload

      expect(described_class).to receive(:call).with(:holds, [ file.id ]).and_call_original

      handler.call(:holds, [ file.id ])
    end
  end
end
