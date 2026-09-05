# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the Disk Image Manager's rollback skill. Thin over
# System::Executors::DiskImage::RollbackPublication with the same target
# selection the system_revert_disk_image MCP verb performs (explicit
# publication_id, else the newest retired publication, else the newest
# published one that is not current), gated on the agent's own
# `system.disk_image_publication_rollback` row.
RSpec.describe System::Ai::Skills::DiskImageRollbackExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:exec)     { described_class.new(account: account) }

  def stub_file_storage!
    fake = instance_double(::FileStorageService, delete_file: true)
    allow(::FileStorageService).to receive(:new).and_return(fake)
  end

  def retired_with_artifact
    retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
    retired.update!(file_object: create(:file_object, account: account, filename: "old.img",
                                                      file_size: retired.size_bytes,
                                                      content_type: "application/octet-stream",
                                                      checksum_sha256: retired.sha256))
    retired
  end

  describe ".descriptor" do
    it "gates on the Disk Image Manager's declared rollback category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("disk_image_rollback")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to contain_exactly(:platform_id, :publication_id)
      expect(d[:inputs][:platform_id][:required]).to be true
      expect(d[:inputs][:publication_id][:required]).to be false

      expect(described_class.action_category).to eq("system.disk_image_publication_rollback")
      expect(System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg[:agents]).to eq([ "disk-image-manager" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "rolls back to an explicit publication and retires the active one" do
      first  = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      second = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: second.file_object_id)

      r = exec.execute(platform_id: platform.id, publication_id: first.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :reverted)).to be true
      expect(r.dig(:data, :activated_publication_id)).to eq(first.id)
      expect(r.dig(:data, :previous_publication_id)).to eq(second.id)
      expect(platform.reload.disk_image_file_object_id).to eq(first.file_object_id)
      expect(second.reload.status).to eq("retired")
    end

    it "auto-selects the newest retired publication and reactivates it" do
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      target = retired_with_artifact

      r = exec.execute(platform_id: platform.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :activated_publication_id)).to eq(target.id)
      expect(platform.reload.disk_image_file_object_id).to eq(target.file_object_id)
      expect(target.reload.status).to eq("published")
      expect(active.reload.status).to eq("retired")
    end

    it "falls back to the newest published publication that is not current" do
      older  = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)

      r = exec.execute(platform_id: platform.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :activated_publication_id)).to eq(older.id)
      expect(platform.reload.disk_image_file_object_id).to eq(older.file_object_id)
    end

    it "refuses when the platform has nothing to revert to" do
      r = exec.execute(platform_id: platform.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/no prior publication/i)
    end

    it "refuses a purged target, leaving the pointer untouched" do
      stub_file_storage!
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      purged = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      purged.purge!

      r = exec.execute(platform_id: platform.id, publication_id: purged.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/purged/)
      expect(platform.reload.disk_image_file_object_id).to eq(active.file_object_id)
    end

    it "refuses a platform that belongs to another account" do
      foreign = create(:system_node_platform)

      r = exec.execute(platform_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
    end
  end

  describe "the approval gate" do
    it "parks the rollback (no write) when no policy auto-executes it" do
      first  = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      second = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: second.file_object_id)

      r = exec.execute(platform_id: platform.id, publication_id: first.id)

      expect(r[:pending]).to be true
      expect(platform.reload.disk_image_file_object_id).to eq(second.file_object_id)
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate (see
  # BaseSkillExecutor#execute: validation first, so a doomed call never parks an
  # approval). No auto-execute policy here: a check left in #perform would park.
  describe "admission before the approval gate" do
    it "refuses a foreign platform without parking an approval" do
      foreign = create(:system_node_platform)

      r = exec.execute(platform_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:pending]).to be_falsey
      expect(r[:error]).to match(/not found/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "refuses a platform with nothing to revert to without parking an approval" do
      r = exec.execute(platform_id: platform.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/no prior publication/i)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "refuses a purged target without parking an approval" do
      stub_file_storage!
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      purged = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      purged.purge!

      r = exec.execute(platform_id: platform.id, publication_id: purged.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/purged/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
      expect(platform.reload.disk_image_file_object_id).to eq(active.file_object_id)
    end
  end

end
