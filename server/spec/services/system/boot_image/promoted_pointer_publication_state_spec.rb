# frozen_string_literal: true

require "rails_helper"

# IMP-80bd70c04afe — the promoted-pointer lookup must refuse a row that was
# NEVER PUBLISHED, on BOTH paths that resolve it.
#
# Two lookups resolve "the promoted publication" from the platform's git_sha
# pointer, byte-identically:
#
#   UpgradeDispatcher.preflight                    (which pins a task carries)
#   BootImageController#resolve_publication        (which bytes get served)
#     — the UNPARAMETERIZED fallback only; the ?digest= path is already
#       guarded by .retainable.where.not(published_at: nil).
#
# Neither checked publication STATE, so a pointer aimed at a row that never
# reached :published dispatched and served normally. That row is not empty:
# uki_oci_ref / uki_sha256 / uki_cosign_bundle are written at WEBHOOK RECEIVE
# time (webhooks/disk_image_built_controller.rb:89-91), before any cosign or
# sha256 verification runs — so the existing :no_uki_artifact and
# :no_cosign_bundle guards sail straight past an unverified build. Their
# presence is exactly what makes an unpublished row look dispatchable.
#
# published_at is the discriminator, not status: only mark_published and
# reactivate ever set it (disk_image_publication.rb:85, :121), it is never
# cleared, and every writer of disk_image_git_sha sets it in the SAME
# transaction as the pointer flip. So no legitimately promoted row can have a
# nil published_at, and this filter can only ever reject a corrupt pointer.
# This is the same discriminator the ?digest= path already documents.
#
# Deliberately NOT a status filter: `retainable` is load-bearing on the digest
# path for a reason that does not exist here (an in-flight task re-downloading
# a row a promote just retired), and `published_state` would newly refuse a
# retired-but-published row — which is dispatchable, since the UKI is served
# from the OCI registry by digest and never from the soft-deleted file_object.
#
# The two paths are asserted TOGETHER in one file on purpose: scoping either
# alone recreates the plan-vs-dispatch divergence campaign 019f505f exists to
# eliminate — dispatch pinning a row the download then refuses.
RSpec.describe "promoted-pointer publication state guard" do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }

  let(:unpublished_sha) { "never-published-sha" }
  let(:uki_digest)      { "f" * 64 }

  # The broken-writer state: the platform's boot pointer names a row that never
  # reached :published. The row carries a COMPLETE UKI triple because the
  # webhook receiver writes those three fields at creation, so every existing
  # dispatch guard passes.
  def build_unpublished_promoted_row(status: "failed")
    pub = System::DiskImagePublication.create!(
      account: account, node_platform: platform,
      git_sha: unpublished_sha, arch: "amd64",
      oci_ref: "registry.example.com/disk:never-published",
      sha256: "9" * 64, size_bytes: 4096,
      uki_oci_ref: "registry.example.com/uki:never-published",
      uki_sha256: uki_digest,
      uki_cosign_bundle: "UNVERIFIED-BUNDLE-B64"
    )
    # retired_at mirrors what the `retire` before-hook stamps, so the "retired"
    # case is a faithful LAUNDERED row (failed → retired via retire_stuck!):
    # terminal status indistinguishable from a healthy retired row, published_at
    # still nil. That is the one status where a status-based guard and this
    # published_at guard disagree, so it must be exercised end-to-end and not
    # only at scope level.
    pub.update_columns(
      { status: status }.merge(status == "retired" ? { retired_at: Time.current } : {})
    )
    platform.update!(
      disk_image_git_sha: unpublished_sha,
      disk_image_oci_ref: pub.oci_ref
    )
    pub.reload
  end

  # WHY published_at and not a status scope — the load-bearing half of the fix.
  #
  # `retire` transitions from failed/verifying as well as published, so the
  # stuck-build cleanup (DiskImageRetentionService#retire_stuck!) launders a
  # build that FAILED verification into the same terminal status as a healthy
  # retired one. `retainable` (published + retired) therefore cannot tell them
  # apart, and would readmit exactly the unverified row this guard exists to
  # refuse. published_at survives that laundering untouched.
  it "reaches :retired with a nil published_at through the failed-build cleanup path" do
    pub = System::DiskImagePublication.create!(
      account: account, node_platform: platform,
      git_sha: "laundered-sha", arch: "amd64", oci_ref: "registry.example.com/disk:laundered",
      sha256: "7" * 64, size_bytes: 1024
    )

    pub.start_verifying!
    expect(pub.published_at).to be_nil

    pub.mark_failed!("cosign verify failed")
    expect(pub.published_at).to be_nil

    pub.retire!

    expect(pub.reload).to have_attributes(status: "retired", published_at: nil)
    # The scope the digest path uses would let this row straight through on its
    # status alone; published_at is what actually discriminates.
    expect(System::DiskImagePublication.retainable).to include(pub)
    expect(System::DiskImagePublication.where.not(published_at: nil)).not_to include(pub)
  end

  describe "UpgradeDispatcher.preflight" do
    let(:instance) { create(:system_node_instance, :running, node: node) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----")
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
      instance.update!(booted_image_git_sha: nil)
    end

    it "refuses to dispatch from a never-published promoted row" do
      build_unpublished_promoted_row

      result = System::BootImage::UpgradeDispatcher.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be false
      expect(result.reason).to match(/never (completed publication|published)|not published/i)
      expect(result.task).to be_nil
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
    end

    it "blocks the PLAN too, so plan and dispatch cannot diverge" do
      build_unpublished_promoted_row

      # A dispatch-only refusal is the divergence this campaign exists to
      # eliminate: the rollout plans GREEN, the operator approves, and every
      # node silently dispatches nothing.
      expect(System::BootImage::UpgradeDispatcher.platform_blocker(platform)).to be_present
    end

    # "retired" is the load-bearing member of this list, not filler: it is the
    # ONLY status a laundered row shares with a healthy one, so it is the only
    # case that can tell a published_at guard apart from a status guard. Without
    # it, weakening the guard to `%w[published retired].include?(pub.status)`
    # passes this whole file.
    %w[queued awaiting_upload verifying failed retired].each do |state|
      it "refuses a promoted row still in #{state}" do
        build_unpublished_promoted_row(status: state)

        result = System::BootImage::UpgradeDispatcher.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.task).to be_nil
      end
    end

    it "still dispatches from a legitimately promoted row" do
      pub = System::DiskImagePublication.create!(
        account: account, node_platform: platform,
        git_sha: "good-sha", arch: "amd64", oci_ref: "registry.example.com/disk:good",
        sha256: "a" * 64, size_bytes: 1024,
        uki_oci_ref: "registry.example.com/uki:good", uki_sha256: "c" * 64,
        uki_cosign_bundle: "GOOD-BUNDLE"
      )
      pub.update_columns(status: "published", published_at: Time.current)
      platform.update!(disk_image_git_sha: "good-sha", disk_image_oci_ref: pub.oci_ref)

      result = System::BootImage::UpgradeDispatcher.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be true
      expect(result.task.options["uki_sha256"]).to eq("c" * 64)
    end

    it "still dispatches from a RETIRED row that was once published" do
      # A retention sweep or a promote race can leave the pointer on a retired
      # row. It is fully dispatchable — the UKI comes from the OCI registry by
      # digest, never from the soft-deleted file_object — so a status-based
      # filter here would newly break a working upgrade. published_at does not.
      pub = System::DiskImagePublication.create!(
        account: account, node_platform: platform,
        git_sha: "retired-sha", arch: "amd64", oci_ref: "registry.example.com/disk:retired",
        sha256: "b" * 64, size_bytes: 1024,
        uki_oci_ref: "registry.example.com/uki:retired", uki_sha256: "d" * 64,
        uki_cosign_bundle: "RETIRED-BUNDLE"
      )
      pub.update_columns(status: "retired", published_at: 1.week.ago, retired_at: Time.current)
      platform.update!(disk_image_git_sha: "retired-sha", disk_image_oci_ref: pub.oci_ref)

      result = System::BootImage::UpgradeDispatcher.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be true
      expect(result.task.options["uki_sha256"]).to eq("d" * 64)
    end
  end

  # The broken-writer state is not hypothetical: in-tree code reaches it. The
  # rollback controller gates on purged? and file_object_id.present? — its own
  # error text asks "was it ever published?" but it never checks. A
  # direct-upload publication carries file_object_id from /initiate, BEFORE
  # verification, so a build that FAILED cosign/sha verification passes both
  # gates, and RollbackPublication only reactivates a row that is `retired` —
  # a `failed` row falls straight through to the pointer flip.
  describe "reachability of the broken-writer state" do
    it "lands the pointer on a never-published row via RollbackPublication" do
      file_object = create(:file_object, account: account, filename: "x.img",
                                         file_size: 4096, content_type: "application/octet-stream",
                                         checksum_sha256: "9" * 64)
      failed = System::DiskImagePublication.create!(
        account: account, node_platform: platform,
        git_sha: "failed-direct-upload-sha", arch: "amd64",
        sha256: "9" * 64, size_bytes: 4096, file_object: file_object,
        uki_oci_ref: "registry.example.com/uki:failed", uki_sha256: "e" * 64,
        uki_cosign_bundle: "FAILED-BUNDLE"
      )
      failed.update_columns(status: "failed", error_message: "cosign verify failed")

      System::Executors::DiskImage::RollbackPublication.execute(
        { "target_publication_id" => failed.id, "platform_id" => platform.id },
        deferred_operation: nil
      )

      expect(platform.reload.disk_image_git_sha).to eq("failed-direct-upload-sha")
      expect(failed.reload.published_at).to be_nil
    end
  end

  describe "BootImageController#download unparameterized fallback", type: :request do
    let(:instance) { create(:system_node_instance, node: node, status: "pending") }

    let!(:active_cert) do
      System::NodeCertificate.create!(
        node_instance: instance,
        serial:         SecureRandom.hex(16),
        subject:        "CN=#{instance.id}",
        not_before:     1.hour.ago,
        not_after:      90.days.from_now,
        issuer_subject: "CN=Powernode Internal CA"
      )
    end

    let(:headers) do
      { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
    end

    it "refuses to serve bytes from a never-published promoted row" do
      build_unpublished_promoted_row

      # No ?digest= — the legacy/unpinned path, the only one that reaches the
      # git_sha fallback at boot_image_controller.rb:135.
      get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("UNVERIFIED")
    end

    it "refuses to serve bytes from a LAUNDERED retired row (failed → retired)" do
      # The status-indistinguishable case, and the reason this branch filters on
      # published_at rather than `.retainable`: retire_stuck! moves a build that
      # FAILED verification into :retired, so `.retainable` would serve its
      # unverified bytes. Pinned here end-to-end, not only as a scope assertion.
      build_unpublished_promoted_row(status: "retired")

      get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("UNVERIFIED")
    end

    it "still serves a RETIRED row that was once published" do
      # The other half of that choice: `published_state` would 404 here. A
      # retired-but-published row is servable because the UKI is proxied from
      # the OCI registry by digest and never touches the soft-deleted
      # file_object. Mirrors the dispatcher-side example above so the two paths
      # are pinned symmetrically in BOTH directions.
      pub = System::DiskImagePublication.create!(
        account: account, node_platform: platform,
        git_sha: "retired-sha", arch: "amd64", oci_ref: "registry.example.com/disk:retired",
        sha256: "b" * 64, size_bytes: 1024,
        uki_oci_ref: "registry.example.com/uki:retired", uki_sha256: "d" * 64
      )
      pub.update_columns(status: "retired", published_at: 1.week.ago, retired_at: Time.current)
      platform.update!(disk_image_git_sha: "retired-sha", disk_image_oci_ref: pub.oci_ref)

      temp_file = Tempfile.new("uki-blob")
      temp_file.write("RETIRED-UKI-BYTES")
      temp_file.rewind
      allow(::System::OciBlobProxyService).to receive(:new)
        .and_return(double("OciBlobProxyService", fetch_blob!: temp_file.path))

      get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Boot-Image-Digest"]).to eq("d" * 64)
      temp_file.close!
    end

    it "still serves a legitimately promoted row unpinned" do
      pub = System::DiskImagePublication.create!(
        account: account, node_platform: platform,
        git_sha: "good-sha", arch: "amd64", oci_ref: "registry.example.com/disk:good",
        sha256: "a" * 64, size_bytes: 1024,
        uki_oci_ref: "registry.example.com/uki:good", uki_sha256: "c" * 64
      )
      pub.update_columns(status: "published", published_at: Time.current)
      platform.update!(disk_image_git_sha: "good-sha", disk_image_oci_ref: pub.oci_ref)

      temp_file = Tempfile.new("uki-blob")
      temp_file.write("UKI-BYTES")
      temp_file.rewind
      allow(::System::OciBlobProxyService).to receive(:new)
        .and_return(double("OciBlobProxyService", fetch_blob!: temp_file.path))

      get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Boot-Image-Digest"]).to eq("c" * 64)
      temp_file.close!
    end
  end
end
