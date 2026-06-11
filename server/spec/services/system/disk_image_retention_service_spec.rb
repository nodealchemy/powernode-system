# frozen_string_literal: true

require "rails_helper"

# Audit F5-11 — retention deletes published boot artifacts; an untested
# regression here destroys disk images fleet-wide. Pins the two-stage
# lifecycle (retire newest-N overflow → purge past grace window) and the
# active-publication guard.
RSpec.describe System::DiskImageRetentionService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account, disk_image_retention_count: 2) }
  let(:storage)  { instance_double(FileStorageService, delete_file: true) }

  before do
    allow(FileStorageService).to receive(:new).and_return(storage)
  end

  def publish!(age_days:)
    create(:system_disk_image_publication, :published,
           account: account, node_platform: platform,
           published_at: age_days.days.ago)
  end

  describe ".sweep! retire stage" do
    it "keeps the newest N published publications and retires the overflow (soft delete)" do
      newest = publish!(age_days: 1)
      middle = publish!(age_days: 2)
      old    = publish!(age_days: 3)
      oldest = publish!(age_days: 4)

      result = described_class.sweep!(platform: platform)

      expect(result.retired_count).to eq(2)
      expect(newest.reload.status).to eq("published")
      expect(middle.reload.status).to eq("published")
      expect(old.reload.status).to eq("retired")
      expect(oldest.reload.status).to eq("retired")
      expect(old.retired_at).to be_present
      expect(storage).to have_received(:delete_file)
        .with(anything, hash_including(permanent: false)).twice
    end

    it "NEVER retires the publication whose image is active on the platform" do
      publish!(age_days: 1)
      publish!(age_days: 2)
      active_old = publish!(age_days: 5)
      platform.update!(disk_image_file_object_id: active_old.file_object_id)

      result = described_class.sweep!(platform: platform)

      expect(result.retired_count).to eq(0)
      expect(active_old.reload.status).to eq("published")
      expect(storage).not_to have_received(:delete_file)
    end

    it "clamps the keep count to at least 1" do
      platform.update_column(:disk_image_retention_count, 0)
      newest = publish!(age_days: 1)
      old    = publish!(age_days: 2)

      described_class.sweep!(platform: platform)

      expect(newest.reload.status).to eq("published")
      expect(old.reload.status).to eq("retired")
    end

    it "records a per-publication error and keeps sweeping the rest" do
      publish!(age_days: 1)
      publish!(age_days: 2)
      bad  = publish!(age_days: 3)
      good = publish!(age_days: 4)
      allow(storage).to receive(:delete_file) do |file_object, **_kw|
        raise "backend gone" if file_object.id == bad.file_object_id
        true
      end

      result = described_class.sweep!(platform: platform)

      expect(result.errors).to contain_exactly(a_string_matching(/retire failed for #{bad.id}/))
      expect(good.reload.status).to eq("retired")
      expect(bad.reload.status).to eq("published")
    end
  end

  describe ".sweep! purge stage" do
    def retired!(retired_days_ago:)
      pub = create(:system_disk_image_publication, :published,
                   account: account, node_platform: platform,
                   published_at: 30.days.ago)
      pub.update!(status: "retired", retired_at: retired_days_ago.days.ago)
      pub
    end

    it "hard-deletes retired publications past the grace window, keeps ones within it" do
      expired = retired!(retired_days_ago: 8)
      fresh   = retired!(retired_days_ago: 2)

      result = described_class.sweep!(platform: platform, grace_days: 7)

      expect(result.purged_count).to eq(1)
      expect(expired.reload.status).to eq("purged")
      expect(expired.purged_at).to be_present
      expect(fresh.reload.status).to eq("retired")
      expect(storage).to have_received(:delete_file)
        .with(anything, hash_including(permanent: true)).once
    end
  end

  describe ".sweep_account!" do
    it "sweeps every platform in the account and returns per-platform results" do
      platform # realize the lazy let BEFORE the sweep enumerates platforms
      other_platform = create(:system_node_platform, account: account,
                              disk_image_retention_count: 1)

      results = described_class.sweep_account!(account: account)

      expect(results.keys).to include(platform.id, other_platform.id)
      expect(results.values).to all(be_a(described_class::Result))
    end
  end
end
