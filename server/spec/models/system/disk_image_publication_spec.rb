# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::DiskImagePublication, type: :model do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  describe "validations" do
    it "rejects malformed sha256" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, sha256: "tooshort")
      expect(pub).not_to be_valid
      expect(pub.errors[:sha256]).to include("must be 64 hex chars")
    end

    it "requires a valid arch" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, arch: "x86")
      expect(pub).not_to be_valid
    end

    it "rejects negative size_bytes" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, size_bytes: -1)
      expect(pub).not_to be_valid
    end

    it "enforces unique git_sha within a platform" do
      first = create(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-a")
      dup = build(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-a")
      expect(dup).not_to be_valid
      expect(first).to be_persisted
    end

    it "allows the same git_sha across different platforms" do
      other_platform = create(:system_node_platform, account: account)
      create(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-x")
      cross = build(:system_disk_image_publication, account: account, node_platform: other_platform, git_sha: "sha-x")
      expect(cross).to be_valid
    end
  end

  describe "state machine (AASM)" do
    let(:pub) { create(:system_disk_image_publication, account: account, node_platform: platform) }

    it "starts in :queued" do
      expect(pub).to be_queued
    end

    it "queued → verifying via start_verifying" do
      pub.start_verifying!
      expect(pub).to be_verifying
    end

    it "queued → awaiting_upload via await_upload" do
      pub.await_upload!
      expect(pub).to be_awaiting_upload
    end

    it "verifying → published guarded on file_object_id present" do
      pub.start_verifying!
      pub.mark_published # no file_object yet
      expect(pub).to be_verifying # transition refused
      expect(pub.aasm.from_state).to eq(:verifying)
    end

    it "verifying → published succeeds when file_object_id is set" do
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      expect(published).to be_published
      expect(published.published_at).to be_present
      expect(published.verified_at).to be_present
    end

    it "verifying → failed with error message" do
      pub.start_verifying!
      pub.mark_failed!("cosign verify failed")
      expect(pub).to be_failed
      expect(pub.error_message).to eq("cosign verify failed")
    end

    it "published → retired stamps retired_at" do
      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      published.retire!
      expect(published).to be_retired
      expect(published.retired_at).to be_present
    end

    it "retired → purged stamps purged_at" do
      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      retired.purge!
      expect(retired).to be_purged
      expect(retired.purged_at).to be_present
    end

    # Regression for fk_rails_416646d33d: purge! used to hard-delete the
    # file_object BEFORE clearing the back-reference a successor publication
    # keeps in prior_file_object_id, raising ActiveRecord::InvalidForeignKey
    # and leaving retention purge permanently unable to reclaim quota.
    it "retired → purged hard-deletes the file_object even when a successor references it as prior_file_object_id" do
      fo = create(:file_object, account: account, filename: "old.img", checksum_sha256: "b" * 64)
      retired = create(:system_disk_image_publication, :retired,
                        account: account, node_platform: platform, file_object: fo)
      successor = create(:system_disk_image_publication, :published,
                          account: account, node_platform: platform, prior_file_object_id: fo.id)

      fake_storage_service = instance_double(::FileStorageService)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      allow(fake_storage_service).to receive(:delete_file) do |file_object, **kw|
        file_object.destroy! if kw[:permanent]
        true
      end

      expect { retired.purge! }.not_to raise_error

      expect(retired.reload).to be_purged
      expect(retired.purged_at).to be_present
      expect(retired.file_object_id).to be_nil
      expect(successor.reload.prior_file_object_id).to be_nil
      expect(::FileManagement::Object.exists?(fo.id)).to be false
    end

    it "purge! refuses to delete the file_object that is the platform's active disk image" do
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      active.update!(status: "retired", retired_at: Time.current)

      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)

      expect { active.purge! }.to raise_error(/active disk image/)
      expect(fake_storage_service).not_to have_received(:delete_file)
      expect(active.reload).to be_retired
    end

    it "failed → retired stamps retired_at (DK3 stuck-cleanup path)" do
      failed = create(:system_disk_image_publication, :failed, account: account, node_platform: platform)
      failed.retire!
      expect(failed).to be_retired
      expect(failed.retired_at).to be_present
    end

    it "verifying → retired stamps retired_at (DK3 stuck-cleanup path)" do
      pub.start_verifying!
      pub.retire!
      expect(pub).to be_retired
      expect(pub.retired_at).to be_present
    end

    it "rejects invalid transitions silently (whiny_transitions: false)" do
      # queued → published is invalid; should not raise, status stays queued.
      pub.mark_published
      expect(pub).to be_queued
    end
  end

  describe "scopes" do
    let!(:queued) { create(:system_disk_image_publication, account: account, node_platform: platform) }
    let!(:published) { create(:system_disk_image_publication, :published, account: account, node_platform: platform) }
    let!(:retired) { create(:system_disk_image_publication, :retired, account: account, node_platform: platform) }
    let!(:retired_old) do
      create(:system_disk_image_publication, :retired, account: account, node_platform: platform).tap do |r|
        r.update_columns(retired_at: 30.days.ago)
      end
    end

    it ".published_state returns only published rows" do
      expect(described_class.published_state).to contain_exactly(published)
    end

    it ".retainable returns published + retired" do
      expect(described_class.retainable).to contain_exactly(published, retired, retired_old)
    end

    it ".purgeable returns retired rows past grace period" do
      expect(described_class.purgeable(grace_days: 7)).to contain_exactly(retired_old)
    end

    it ".recent_for orders by created_at desc and limits" do
      list = described_class.recent_for(platform, 2)
      expect(list.length).to eq(2)
      expect(list.first.created_at).to be >= list.last.created_at
    end
  end

  describe "#cosign_attestation_predicate" do
    it "decodes the base64 + JSON when present" do
      predicate = { "platform_name" => "test", "sha256" => "abc" }
      bundle = Base64.strict_encode64(predicate.to_json)
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: bundle)
      expect(pub.cosign_attestation_predicate).to eq(predicate)
    end

    it "returns nil when attestation_bundle is blank" do
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: nil)
      expect(pub.cosign_attestation_predicate).to be_nil
    end

    it "returns nil on malformed bundle (no exception)" do
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: "not-base64")
      expect(pub.cosign_attestation_predicate).to be_nil
    end
  end

  describe "#active?" do
    it "true when published AND platform.disk_image_file_object_id matches" do
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: published.file_object_id)
      expect(published.active?).to be true
    end

    it "false when retired even if file_object matches" do
      retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: retired.file_object_id)
      expect(retired.active?).to be false
    end
  end
end
