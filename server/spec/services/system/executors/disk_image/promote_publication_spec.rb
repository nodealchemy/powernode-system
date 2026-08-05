# frozen_string_literal: true

require "rails_helper"

# Boot-critical: this executor writes NodePlatform#disk_image_file_object_id,
# the pointer every fleet node resolves at next boot. A wrong write here
# doesn't fail loudly — it strands nodes, and on a self-hosted hub the
# platform that would roll it back is the thing that stops booting.
RSpec.describe System::Executors::DiskImage::PromotePublication do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  # purge! shells out to FileStorageService for the hard-delete; stub it the
  # same way spec/models/system/disk_image_publication_spec.rb does.
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
    it "refuses a purged publication (published_at stale, file_object_id nil) and leaves the pointer unchanged" do
      # Establish a real active pointer first, via the executor's own happy
      # path, so "unchanged" below is a meaningful assertion and not just
      # nil == nil.
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      described_class.execute({ "publication_id" => active.id }, deferred_operation: nil)
      active_file_object_id = platform.reload.disk_image_file_object_id
      expect(active_file_object_id).to eq(active.file_object_id)

      pub = purged_publication
      expect(pub).to be_purged
      expect(pub.file_object_id).to be_nil
      # The trap: purge! does NOT clear published_at, so a published_at-only
      # guard would wave this row through.
      expect(pub.published_at).to be_present

      expect {
        described_class.execute({ "publication_id" => pub.id }, deferred_operation: nil)
      }.to raise_error(described_class::UnpromotablePublicationError, /status=purged/)

      expect(platform.reload.disk_image_file_object_id).to eq(active_file_object_id)
    end

    it "still promotes a legitimately published row with its artifact present" do
      pub = create(:system_disk_image_publication, :published, account: account, node_platform: platform)

      result = described_class.execute({ "publication_id" => pub.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(platform.reload.disk_image_file_object_id).to eq(pub.file_object_id)
      expect(platform.disk_image_publication_status).to eq("published")
    end

    it "still promotes (reactivates) a retired row whose artifact is intact — INCLUDING the " \
       "real soft-deleted shape retire! actually produces" do
      # NOTE: the bare :retired factory trait does NOT attach a file_object
      # (only :published does, via its after(:build) hook) — a retired row
      # with no file_object at all would correctly be refused by the new
      # guard too, so this test must attach one explicitly to exercise the
      # "retired but artifact still present" path the reactivate branch is
      # for. Critically, it must ALSO be soft-deleted (deleted_at present) —
      # that's what DiskImagePublication#retire! actually does to the
      # file_object in production (via FileStorageService#delete_file
      # permanent: false), and it's the shape the reactivate branch's
      # `pub.file_object.restore! if pub.file_object&.deleted_at?` exists to
      # handle. A fresh, never-soft-deleted file_object skips that branch
      # entirely and would pass even if `restore!` were replaced by broken
      # code that never runs.
      fo = create(:file_object, account: account)
      fo.soft_delete!(create(:user, account: account))
      retired = create(:system_disk_image_publication, :retired,
                        account: account, node_platform: platform, file_object: fo)
      expect(retired.file_object.deleted_at).to be_present

      result = described_class.execute({ "publication_id" => retired.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(retired.reload).to be_published
      expect(retired.file_object.reload.deleted_at).to be_nil
      expect(platform.reload.disk_image_file_object_id).to eq(fo.id)
    end

    # Isolates the ARTIFACT half of promotable? from the STATUS half. Both of
    # these are reachable production states where ONE half would pass and
    # the OTHER must be the thing that refuses — the purged-row test above
    # fails BOTH halves at once, so it can't tell you which check is doing
    # the work (a mutant dropping either individually still passes it).
    describe "isolating each half of the guard" do
      it "refuses a retired publication with no artifact (retire_stuck! shape: a :failed CI " \
         "run that never got a file_object, retired by the stuck-publication cleanup rake) " \
         "— status passes, artifact fails" do
        stuck = create(:system_disk_image_publication, :failed, account: account, node_platform: platform,
                                                                  created_at: 30.days.ago)
        stuck.retire!
        expect(stuck.reload.status).to eq("retired")
        expect(stuck.file_object_id).to be_nil

        active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
        described_class.execute({ "publication_id" => active.id }, deferred_operation: nil)
        active_file_object_id = platform.reload.disk_image_file_object_id

        expect {
          described_class.execute({ "publication_id" => stuck.id }, deferred_operation: nil)
        }.to raise_error(described_class::UnpromotablePublicationError, /status=retired/)
        expect(platform.reload.disk_image_file_object_id).to eq(active_file_object_id)
      end

      it "refuses a :verifying direct-upload publication with an artifact already uploaded but " \
         "NOT yet cosign/sha verified — artifact passes, status fails" do
        fo = create(:file_object, account: account)
        unverified = create(:system_disk_image_publication, :verifying, account: account,
                             node_platform: platform, oci_ref: nil, file_object: fo)
        expect(unverified.status).to eq("verifying")
        expect(unverified.file_object_id).to be_present

        active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
        described_class.execute({ "publication_id" => active.id }, deferred_operation: nil)
        active_file_object_id = platform.reload.disk_image_file_object_id

        expect {
          described_class.execute({ "publication_id" => unverified.id }, deferred_operation: nil)
        }.to raise_error(described_class::UnpromotablePublicationError, /status=verifying/)
        expect(platform.reload.disk_image_file_object_id).to eq(active_file_object_id)
      end
    end
  end
end
