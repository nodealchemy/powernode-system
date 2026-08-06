# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Worker API: disk_image_publications", type: :request do
  let(:account) { create(:account) }
  # See disk_image_built_spec for the rationale: Account bootstrap pre-creates
  # this NodePlatform, so we reference the bootstrapped row via the
  # System extension's AccountDecorator-provided association.
  let(:platform) { account.system_node_platforms.find_by!(name: "ubuntu-24.04-rpi4") }
  let!(:worker) { create(:worker, account: account, status: "active") }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }

  before do
    # Mirror the existing worker_api spec pattern: stub has_permission?
    # rather than seeding Permission rows (avoids coupling to schema
    # details that aren't this controller's concern).
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.platforms.publish_disk_image").and_return(true)

    platform.update!(
      cosign_identity_regexp: "https://registry.example.com/.+",
      cosign_issuer_regexp:   "https://registry.example.com"
    )
  end

  describe "POST /process" do
    let!(:publication) do
      create(:system_disk_image_publication, account: account, node_platform: platform, status: "queued")
    end

    it "401 when the mTLS client-cert header is missing" do
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "404 when publication doesn't exist" do
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: SecureRandom.uuid }.to_json, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "403 when worker.account_id != publication.account_id (cross-tenant)" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_pub = create(:system_disk_image_publication, account: other_account, node_platform: other_platform)
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: other_pub.id }.to_json, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "200 + invokes processor on happy path" do
      fake_result = ::System::DiskImagePublicationProcessor::Result.new(
        ok?: true, publication: publication, file_object: nil
      )
      allow(::System::DiskImagePublicationProcessor).to receive(:process!).and_return(fake_result)

      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["data"]["publication_id"]).to eq(publication.id)
    end

    it "422 on processor failure (don't retry on validation-class)" do
      fake_result = ::System::DiskImagePublicationProcessor::Result.new(
        ok?: false, error: "cosign verify failed", publication: publication
      )
      allow(::System::DiskImagePublicationProcessor).to receive(:process!).and_return(fake_result)

      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("cosign verify failed")
    end
  end

  # IMP-c3f186e56d5b (source fix). Found while proving that
  # DiskImagePublication#promotable?'s published_at clause does not close
  # the retire_stuck! laundering hole it was filed against: initiate
  # reuses an EXISTING row via find_or_initialize_by(node_platform, git_sha)
  # whenever the same git_sha is re-submitted for direct upload —
  # legitimately how a retried/rebuilt CI run re-enters the pipeline. If
  # that row was PREVIOUSLY published (then retired — a rollback, or the
  # reaper), assign_attributes resets status BACKWARD to "awaiting_upload",
  # off the normal AASM graph (no transition reaches :awaiting_upload FROM
  # :retired), but published_at — and every other column describing the
  # OLD artifact's lifecycle — is not in that assignment list, so it
  # survives onto a row now pointing at BRAND NEW, unverified bytes.
  #
  # Production sequence, nothing exotic: publish git_sha S -> rollback or
  # reaper retires it -> CI re-runs the SAME git_sha through direct upload
  # -> that upload fails verification -> stuck-cleanup retires it again ->
  # it now reads as promotable (published_at present, status retired,
  # file_object_id pointing at bytes that never passed verification).
  #
  # published_at records that this ROW was published once. It does not
  # record that its CURRENT artifact was ever verified. Four consumers
  # read these stale columns as if it did: boot_image_controller.rb (both
  # lookup branches), upgrade_dispatcher.rb's preflight, and promotable?.
  # The fix belongs at the source: initiate must reset every column that
  # describes the ARTIFACT or its lifecycle state when it hands the row a
  # new, unverified file_object_id. Columns describing the ROW's identity
  # (account, node_platform, git_sha, created_at, attempt_count) must NOT
  # be touched — this is still the same publication history entry.
  describe "POST /initiate" do
    let(:storage) { instance_double(::FileStorageService) }

    before do
      allow(::FileStorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:storage_supports_direct_upload?).and_return(true)
      # direct_upload_filename was undefined when this block was written
      # (every #initiate 500'd; a class_eval stub stood in here). It is now
      # implemented for real (IMP-c3007fd19bf3 — delegates to
      # DiskImagePublication.storage_filename_for), so these examples run
      # through the genuine helper. The old class_eval stub also leaked
      # process-wide and would have overridden the real method for every
      # later-running example in the file.
    end

    def stub_signed_upload_url!(file_object_id:)
      allow(storage).to receive(:signed_upload_url).and_return(
        file_object_id:    file_object_id,
        upload_url:        "https://storage.example.com/presigned",
        upload_expires_at: 1.hour.from_now
      )
    end

    it "202-equivalent happy path: creates a new publication + returns a signed upload URL" do
      new_file_object = create(:file_object, account: account, checksum_sha256: "1" * 64)
      stub_signed_upload_url!(file_object_id: new_file_object.id)

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: { platform_name: platform.name, sha256: "1" * 64, size_bytes: 4096,
                      git_sha: "fresh-sha", arch: "arm64" }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      pub = System::DiskImagePublication.find_by(git_sha: "fresh-sha")
      expect(pub).to be_present
      expect(pub.status).to eq("awaiting_upload")
      expect(pub.file_object_id).to eq(new_file_object.id)
    end

    it "resets stale artifact provenance when a previously-published git_sha is " \
       "re-initiated for direct upload" do
      # A prior_file_object_id column is FK-constrained to file_objects, so
      # giving it a non-nil prior value (to prove the reset actually clears
      # it, not just that it started nil) needs a real row.
      superseded_file_object = create(:file_object, account: account, checksum_sha256: "5" * 64)
      published_pub = create(:system_disk_image_publication, :published, account: account,
                              node_platform: platform, git_sha: "reused-sha",
                              oci_ref: "registry.example.com/disk:reused",
                              attestation_bundle: "OLD-ATTESTATION", cosign_bundle: "OLD-COSIGN",
                              uki_oci_ref: "registry.example.com/uki:reused", uki_sha256: "2" * 64,
                              uki_cosign_bundle: "OLD-UKI-BUNDLE",
                              prior_file_object_id: superseded_file_object.id)
      # purged_at and error_message also need non-nil seeding here: a bare
      # :published row never has either set, so a reset that silently
      # skipped clearing them would pass this test by coincidence (already
      # nil, "cleared" to nil) rather than by actually clearing anything.
      # Confirmed empirically -- both mutants read 0 failures before this
      # was added, despite the assertions below already existing.
      published_pub.update!(status: "retired", retired_at: Time.current,
                             purged_at: 3.days.ago, error_message: "stale error from a prior attempt")
      old_file_object_id = published_pub.file_object_id
      expect(published_pub.published_at).to be_present
      expect(published_pub.verified_at).to be_present

      new_file_object = create(:file_object, account: account, filename: "reupload.img",
                                file_size: 4096, content_type: "application/octet-stream",
                                checksum_sha256: "3" * 64)
      stub_signed_upload_url!(file_object_id: new_file_object.id)

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: { platform_name: platform.name, sha256: "3" * 64, size_bytes: 4096,
                      git_sha: "reused-sha", arch: "arm64" }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      published_pub.reload
      expect(published_pub.status).to eq("awaiting_upload")
      expect(published_pub.file_object_id).to eq(new_file_object.id)
      expect(published_pub.file_object_id).not_to eq(old_file_object_id)

      # THE DEFECT (pre-fix): every one of these survives from the OLD
      # publish, describing an artifact that is no longer this row's
      # file_object_id.
      expect(published_pub.published_at).to be_nil
      expect(published_pub.verified_at).to be_nil
      expect(published_pub.retired_at).to be_nil
      expect(published_pub.purged_at).to be_nil
      expect(published_pub.error_message).to be_nil
      expect(published_pub.uki_oci_ref).to be_nil
      expect(published_pub.uki_sha256).to be_nil
      expect(published_pub.uki_cosign_bundle).to be_nil
      expect(published_pub.attestation_bundle).to be_nil
      expect(published_pub.cosign_bundle).to be_nil
      expect(published_pub.prior_file_object_id).to be_nil
      # direct_upload_mode? (DiskImagePublicationProcessor) requires
      # oci_ref.blank? — a stale oci_ref from the OLD OCI-pull-mode publish
      # would misroute this row's verification through the wrong ingest
      # adapter entirely, a functional bug on top of the trust one.
      expect(published_pub.oci_ref).to be_blank

      # Row identity must NOT be touched.
      expect(published_pub.account_id).to eq(account.id)
      expect(published_pub.node_platform_id).to eq(platform.id)
      expect(published_pub.git_sha).to eq("reused-sha")
    end

    it "leaves an unpublished row's provenance alone (nothing to clear)" do
      queued = create(:system_disk_image_publication, account: account, node_platform: platform,
                       git_sha: "never-published-sha")
      expect(queued.published_at).to be_nil

      new_file_object = create(:file_object, account: account, checksum_sha256: "4" * 64)
      stub_signed_upload_url!(file_object_id: new_file_object.id)

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: { platform_name: platform.name, sha256: "4" * 64, size_bytes: 4096,
                      git_sha: "never-published-sha", arch: "arm64" }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(queued.reload.status).to eq("awaiting_upload")
      expect(queued.published_at).to be_nil
    end
  end

  describe "POST /sweep_retention" do
    it "200 + dispatches per-platform sweep when platform_id given" do
      allow(::System::DiskImageRetentionService).to receive(:sweep!).and_return(
        ::System::DiskImageRetentionService::Result.new(retired_count: 2, purged_count: 1, errors: [])
      )

      post "/api/v1/system/worker_api/disk_image_publications/sweep_retention",
           params: { platform_id: platform.id, grace_days: 7 }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["retired"]).to eq(2)
      expect(data["purged"]).to eq(1)
    end

    it "200 + dispatches account-wide sweep when platform_id absent" do
      allow(::System::DiskImageRetentionService).to receive(:sweep_account!).and_return({
        platform.id => ::System::DiskImageRetentionService::Result.new(retired_count: 0, purged_count: 0, errors: [])
      })

      post "/api/v1/system/worker_api/disk_image_publications/sweep_retention",
           params: {}.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["account_id"]).to eq(account.id)
      expect(data["per_platform"]).to be_present
    end

    # DK3: this is the only path the daily System::ExpireOldDiskImageFileObjectsJob
    # exercises (it POSTs with no platform_id). Before the fix, sweep_retention
    # only called sweep_account! (published→retired→purged GC) — a publication
    # stranded in :verifying (e.g. by the Bug 2 quota-exceeded case) was never
    # reaped by anything on the daily cron.
    it "also retires stale :verifying publications past grace when platform_id absent (daily reaper)" do
      stuck = create(:system_disk_image_publication, account: account, node_platform: platform, status: "verifying")
      stuck.update_columns(created_at: 10.days.ago)

      post "/api/v1/system/worker_api/disk_image_publications/sweep_retention",
           params: { grace_days: 7 }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(stuck.reload.status).to eq("retired")
      data = JSON.parse(response.body)["data"]
      expect(data["stuck_retired"]).to eq(1)
    end
  end

  # IMP-c3007fd19bf3 — #initiate had ZERO coverage, which is how
  # direct_upload_filename shipped as a call to a method that was never
  # defined anywhere: every POST 500'd with NameError before validation.
  describe "POST /initiate" do
    let(:git_sha) { "cafebabe12345678deadbeef00112233" }
    let(:initiate_params) do
      {
        platform_name: platform.name,
        sha256: "a" * 64,
        size_bytes: 4096,
        git_sha: git_sha,
        arch: "arm64"
      }
    end

    let(:storage) { instance_double(::FileStorageService, storage_supports_direct_upload?: true) }

    before do
      # FileStorageService#initialize raises StorageNotFoundError for an
      # account with no storage configuration, so the constructor itself must
      # be stubbed — any_instance stubs never get the chance.
      allow(::FileStorageService).to receive(:new).and_return(storage)
    end

    it "creates an awaiting_upload publication and returns the signed URL, naming the artifact identically to the OCI path" do
      # A real row: publications carry an FK to file_objects, so a made-up
      # UUID fails the save with a foreign-key violation (rendered as 422).
      file_object_id = create(:file_object, account: account).id
      expect(storage).to receive(:signed_upload_url) do |**kw|
        # Both publication modes MUST store under the same canonical object
        # name — the model class method is the single authority.
        expect(kw[:filename]).to eq(
          ::System::DiskImagePublication.storage_filename_for(
            platform_name: platform.name, git_sha: git_sha, arch: "arm64"
          )
        )
        expect(kw[:expected_sha256]).to eq("a" * 64)
        { file_object_id: file_object_id,
          upload_url: "https://storage.example/presigned",
          upload_expires_at: 1.hour.from_now }
      end

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: initiate_params.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["signed_upload_url"]).to eq("https://storage.example/presigned")
      pub = ::System::DiskImagePublication.find(data["publication_id"])
      expect(pub.status).to eq("awaiting_upload")
      expect(pub.file_object_id).to eq(file_object_id)
      expect(pub.triggered_by_worker_id).to eq(worker.id)
    end

    it "422 (not 500) when the account has no storage configuration at all" do
      allow(::FileStorageService).to receive(:new)
        .and_raise(::FileStorageService::StorageNotFoundError, "No storage configuration found")

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: initiate_params.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "422 when the platform has no cosign trust policy (direct upload requires publisher pinning)" do
      platform.update!(cosign_identity_regexp: nil, cosign_issuer_regexp: nil)

      post "/api/v1/system/worker_api/disk_image_publications/initiate",
           params: initiate_params.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("cosign trust policy")
    end
  end
end
