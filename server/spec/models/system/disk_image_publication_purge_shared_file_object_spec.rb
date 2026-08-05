# frozen_string_literal: true

require "rails_helper"

# IMP-f0aad29b3344 — scratchpad only, edits no tracked file.
#
# purge!'s active-image guard consults ONLY this row's own node_platform, but
# the sweep that follows is `self.class.where(file_object_id: fo.id)
# .update_all(file_object_id: nil)` — unscoped by account, platform and status
# — and is then followed by a PERMANENT byte delete. A narrow guard
# authorising a wide, irreversible destruction.
#
# NOT REACHABLE TODAY: nothing dedupes FileObjects by digest, every writer of
# DiskImagePublication#file_object_id takes a freshly minted upload, and there
# is no copy/clone path. The shared-FileObject state below is therefore built
# with update_columns — there is no production path that creates it, which is
# itself the reachability evidence.
RSpec.describe "System::DiskImagePublication#purge! with a shared FileObject", type: :model do
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  let(:platform_a) { create(:system_node_platform, account: account_a) }
  let(:platform_b) { create(:system_node_platform, account: account_b) }

  let(:shared_fo) do
    create(:file_object, account: account_a, filename: "shared.img",
           content_type: "application/octet-stream")
  end

  # Platform A's row: RETIRED, and A's platform pointer is NOT this object —
  # so the existing guard passes and purge proceeds.
  let(:pub_a) do
    p = create(:system_disk_image_publication, :retired,
               account: account_a, node_platform: platform_a)
    p.update_columns(file_object_id: shared_fo.id)
    p.reload
  end

  # Platform B's row: PUBLISHED, and B's platform pointer IS this object —
  # i.e. these are B's live boot-image bytes.
  let!(:pub_b) do
    p = create(:system_disk_image_publication, :published,
               account: account_b, node_platform: platform_b)
    p.update_columns(file_object_id: shared_fo.id)
    platform_b.update_columns(disk_image_file_object_id: shared_fo.id)
    p.reload
  end

  # Never let a spec actually hard-delete bytes; also lets us assert on it.
  #
  # Stub the CONSTRUCTOR, not just #delete_file: FileStorageService.new raises
  # StorageNotFoundError with no storage config, which aborts purge! before the
  # delete is reached — and that produced a FALSE PASS on "never permanently
  # deletes the bytes" (it wasn't reached for the wrong reason). The sweep
  # commits in its own transaction BEFORE that raise, so the corruption still
  # lands; only the assertion was lying.
  let(:deleted) { [] }
  let(:storage_double) do
    d = double("FileStorageService")
    allow(d).to receive(:delete_file) do |fo, **kw|
      deleted << { id: fo.id, permanent: kw[:permanent] }
      true
    end
    d
  end

  before { allow(::FileStorageService).to receive(:new).and_return(storage_double) }

  describe "the fixture itself" do
    it "constructs a genuinely shared FileObject across two platforms" do
      expect(pub_a.file_object_id).to eq(shared_fo.id)
      expect(pub_b.file_object_id).to eq(shared_fo.id)
      expect(platform_a.reload.disk_image_file_object_id).not_to eq(shared_fo.id)
      expect(platform_b.reload.disk_image_file_object_id).to eq(shared_fo.id)
      expect(pub_a.status).to eq("retired")
      expect(pub_b.status).to eq("published")
    end
  end

  describe "purging platform A's retired row" do
    it "REFUSES, because the bytes are platform B's active disk image" do
      expect { pub_a.purge! }.to raise_error(/active disk image/i)
    end

    it "leaves platform B's publication pointer intact" do
      begin
        pub_a.purge!
      rescue StandardError
        nil
      end

      expect(pub_b.reload.file_object_id).to eq(shared_fo.id)
    end

    it "leaves platform B's platform pointer intact" do
      begin
        pub_a.purge!
      rescue StandardError
        nil
      end

      expect(platform_b.reload.disk_image_file_object_id).to eq(shared_fo.id)
    end

    it "never permanently deletes the bytes" do
      begin
        pub_a.purge!
      rescue StandardError
        nil
      end

      expect(deleted).to be_empty
    end
  end

  # Same account, two platforms, one FileObject. Separated from the
  # cross-account case on purpose: an account-SCOPED guard would pass this one
  # and still lose the cross-account bytes, so keeping them apart is what makes
  # the two failure modes distinguishable under mutation.
  describe "two platforms in the SAME account sharing a FileObject" do
    let(:platform_a2) { create(:system_node_platform, account: account_a) }
    let(:same_acct_fo) do
      create(:file_object, account: account_a, filename: "same.img",
             content_type: "application/octet-stream")
    end
    let(:pub_retired) do
      p = create(:system_disk_image_publication, :retired,
                 account: account_a, node_platform: platform_a)
      p.update_columns(file_object_id: same_acct_fo.id)
      p.reload
    end
    let!(:pub_live) do
      p = create(:system_disk_image_publication, :published,
                 account: account_a, node_platform: platform_a2)
      p.update_columns(file_object_id: same_acct_fo.id)
      platform_a2.update_columns(disk_image_file_object_id: same_acct_fo.id)
      p.reload
    end

    it "REFUSES, because a sibling platform in this account is serving them" do
      expect { pub_retired.purge! }.to raise_error(/active disk image/i)
    end

    it "never permanently deletes the bytes" do
      begin
        pub_retired.purge!
      rescue StandardError
        nil
      end

      expect(deleted).to be_empty
    end
  end

  # ── THE REGRESSION THAT MATTERS ─────────────────────────────────────────
  #
  # A guard that over-refuses would pass every example above while breaking
  # ordinary retention. An unshared FileObject must still purge completely.
  describe "ordinary purge (FileObject referenced by one row, no platform pointing at it)" do
    let(:lone_fo) do
      create(:file_object, account: account_a, filename: "lone.img",
             content_type: "application/octet-stream")
    end

    let(:pub_lone) do
      p = create(:system_disk_image_publication, :retired,
                 account: account_a, node_platform: platform_a)
      p.update_columns(file_object_id: lone_fo.id)
      p.reload
    end

    it "purges: status purged, pointer nil'd, bytes permanently deleted" do
      pub_lone.purge!

      expect(pub_lone.reload.status).to eq("purged")
      expect(pub_lone.file_object_id).to be_nil
      expect(deleted.map { |d| d[:id] }).to eq([ lone_fo.id ])
      expect(deleted.first[:permanent]).to be true
    end

    it "still nils prior_file_object_id references on other rows" do
      other = create(:system_disk_image_publication, :retired,
                     account: account_a, node_platform: platform_a)
      other.update_columns(prior_file_object_id: lone_fo.id)

      pub_lone.purge!

      expect(other.reload.prior_file_object_id).to be_nil
    end

    # THE OVER-WIDTH REGRESSION. Widening a guard can only make purge refuse
    # MORE often, so the case it must still ALLOW needs its own example: a
    # FileObject shared by another PUBLICATION but pointed at by NO
    # NodePlatform. Nothing is serving these bytes, so ordinary retention
    # cleanup must still reclaim them — and the sweep must still nil the
    # sibling's pointer, because the bytes are going permanently.
    #
    # This is also what fails if anyone later adds the deliberately-declined
    # second guard (refusing on a merely-published sibling): that variant
    # would refuse here and quietly break retention in the field.
    it "still purges when another publication shares the bytes but no platform serves them" do
      sibling = create(:system_disk_image_publication, :published,
                       account: account_a, node_platform: platform_a)
      sibling.update_columns(file_object_id: lone_fo.id)
      expect(platform_a.reload.disk_image_file_object_id).not_to eq(lone_fo.id)

      pub_lone.purge!

      expect(pub_lone.reload.status).to eq("purged")
      expect(deleted.map { |d| d[:id] }).to eq([ lone_fo.id ])
      # The sibling's pointer is nil'd by the unscoped sweep — correct, since
      # the bytes no longer exist. A dangling pointer would be worse.
      expect(sibling.reload.file_object_id).to be_nil
    end

    # The existing narrow guard must keep working: a row whose OWN platform
    # points at its FileObject still refuses.
    it "still refuses when this row's own platform points at the bytes" do
      platform_a.update_columns(disk_image_file_object_id: lone_fo.id)

      expect { pub_lone.purge! }.to raise_error(/active disk image/i)
    end
  end
end
