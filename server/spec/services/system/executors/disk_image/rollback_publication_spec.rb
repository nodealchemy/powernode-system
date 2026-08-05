# frozen_string_literal: true

require "rails_helper"

# Boot-critical: this executor writes NodePlatform#disk_image_file_object_id,
# the pointer every fleet node resolves at next boot. A wrong write here
# doesn't fail loudly — it strands nodes, and on a self-hosted hub the
# platform that would roll it back is the thing that stops booting.
RSpec.describe System::Executors::DiskImage::RollbackPublication do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  def stub_file_storage!
    fake = instance_double(::FileStorageService, delete_file: true)
    allow(::FileStorageService).to receive(:new).and_return(fake)
  end

  def purged_publication
    stub_file_storage!
    retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
    retired.purge!
    retired
  end

  describe "artifact-presence guard" do
    it "refuses to roll back to a purged publication (published_at stale, file_object_id nil) and leaves the pointer unchanged" do
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      active_file_object_id = platform.disk_image_file_object_id

      target = purged_publication
      expect(target).to be_purged
      expect(target.file_object_id).to be_nil
      expect(target.published_at).to be_present

      expect {
        described_class.execute(
          { target_publication_id: target.id, platform_id: platform.id },
          deferred_operation: nil
        )
      }.to raise_error(described_class::UnpromotablePublicationError, /status=purged/)

      expect(platform.reload.disk_image_file_object_id).to eq(active_file_object_id)
    end

    it "still rolls back to a legitimately published row with its artifact present" do
      first  = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      second = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: second.file_object_id)

      result = described_class.execute(
        { target_publication_id: first.id, platform_id: platform.id },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(platform.reload.disk_image_file_object_id).to eq(first.file_object_id)
    end

    it "still rolls back to a retired row whose artifact is intact (reactivates it) — INCLUDING " \
       "the real soft-deleted shape retire! actually produces" do
      # NOTE: the bare :retired factory trait does NOT attach a file_object
      # (only :published does, via its after(:build) hook) — attach one
      # explicitly to exercise "retired but artifact still present", not
      # "retired with nothing to restore" (which the guard correctly refuses).
      # It must ALSO be soft-deleted (deleted_at present) — that's the real
      # shape DiskImagePublication#retire! leaves behind, and what
      # `target.file_object.restore! if target.file_object&.deleted_at?`
      # exists to undo. A fresh, never-soft-deleted file_object would pass
      # even if restore! were broken.
      active  = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      fo = create(:file_object, account: account)
      fo.soft_delete!(create(:user, account: account))
      retired = create(:system_disk_image_publication, :retired,
                        account: account, node_platform: platform, file_object: fo)
      expect(retired.file_object.deleted_at).to be_present

      result = described_class.execute(
        { target_publication_id: retired.id, platform_id: platform.id },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(retired.reload).to be_published
      expect(retired.file_object.reload.deleted_at).to be_nil
      expect(platform.reload.disk_image_file_object_id).to eq(fo.id)
    end

    # Isolates the ARTIFACT half of promotable? from the STATUS half — see
    # promote_publication_spec.rb for the full rationale (the purged-row test
    # above fails both halves at once, so it can't prove which check refuses).
    describe "isolating each half of the guard" do
      it "refuses a retired publication with no artifact (retire_stuck! shape) — status passes, " \
         "artifact fails. Also the row SystemFleetTool#previous_disk_image_publication " \
         "auto-selects (\"newest retired\") when system_revert_disk_image runs with no " \
         "publication_id." do
        stuck = create(:system_disk_image_publication, :failed, account: account, node_platform: platform,
                                                                  created_at: 30.days.ago)
        stuck.retire!
        expect(stuck.reload.status).to eq("retired")
        expect(stuck.file_object_id).to be_nil

        active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
        platform.update!(disk_image_file_object_id: active.file_object_id)

        expect {
          described_class.execute(
            { target_publication_id: stuck.id, platform_id: platform.id }, deferred_operation: nil
          )
        }.to raise_error(described_class::UnpromotablePublicationError, /status=retired/)
        expect(platform.reload.disk_image_file_object_id).to eq(active.file_object_id)
      end

      it "refuses a :verifying direct-upload publication with an artifact already uploaded but " \
         "NOT yet cosign/sha verified — artifact passes, status fails. Reachable because " \
         "DiskImagePublicationsController#rollback only rejects :purged + missing file_object, " \
         "never checks status." do
        fo = create(:file_object, account: account)
        unverified = create(:system_disk_image_publication, :verifying, account: account,
                             node_platform: platform, oci_ref: nil, file_object: fo)
        expect(unverified.status).to eq("verifying")
        expect(unverified.file_object_id).to be_present

        active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
        platform.update!(disk_image_file_object_id: active.file_object_id)

        expect {
          described_class.execute(
            { target_publication_id: unverified.id, platform_id: platform.id }, deferred_operation: nil
          )
        }.to raise_error(described_class::UnpromotablePublicationError, /status=verifying/)
        expect(platform.reload.disk_image_file_object_id).to eq(active.file_object_id)
      end
    end
  end
end
