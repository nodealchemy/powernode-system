# frozen_string_literal: true

require "rails_helper"

# Regression spec for the `.success?` vs `.ok?` bug surfaced by
# smoke_test_disk_image_build_to_publication.rb on 2026-05-18:
# DiskImageOciIngestService::Result is a Struct with `:ok?` as its first
# member (lines 29–30 of disk_image_oci_ingest_service.rb), but the
# processor was calling `.success?` — NoMethodError on every inline ingest
# attempt. Same pattern exists in ModulePublicationProcessor at line 47.
RSpec.describe System::DiskImagePublicationProcessor do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:webhook) do
    System::DiskImageWebhook.create_with_secret!(account: account, label: "spec-fixture").first
  end
  let(:publication) do
    System::DiskImagePublication.create!(
      account: account, node_platform: platform, webhook: webhook,
      git_sha: SecureRandom.hex(20), sha256: SecureRandom.hex(32),
      size_bytes: 1024, oci_ref: "registry.test/foo:bar",
      arch: "arm64", status: "queued", payload: {}
    )
  end

  describe ".process!" do
    context "when the OCI ingest fails" do
      it "marks the publication failed instead of raising NoMethodError (regression for 2026-05-18 .success?/.ok? bug)" do
        failed = System::DiskImageOciIngestService::Result.new(
          ok?: false, error: "synthetic ingest failure", local_path: nil,
          cosign_bundle_b64: nil, attestation_bundle_b64: nil
        )
        # The processor's run_ingest! calls the class method .verify_and_pull!
        # (see disk_image_publication_processor.rb:86); stub at the class level.
        allow(System::DiskImageOciIngestService).to receive(:verify_and_pull!).and_return(failed)

        expect {
          described_class.process!(publication: publication)
        }.not_to raise_error

        expect(publication.reload.status).to eq("failed")
        expect(publication.error_message.to_s).to include("synthetic ingest failure")
      end
    end

    context "Result struct contract" do
      it "exposes `.ok?` as the first member (the method the processor calls)" do
        result = System::DiskImageOciIngestService::Result.new(
          ok?: true, error: nil, local_path: "/tmp/x",
          cosign_bundle_b64: nil, attestation_bundle_b64: nil
        )
        expect(result).to respond_to(:ok?)
        expect(result.ok?).to be true
        # Guard: if anyone refactors the Result struct to use `success?`, this
        # spec WILL fail loudly so the processor call sites get updated in
        # lockstep. Currently the struct does NOT define `.success?`.
        expect(result).not_to respond_to(:success?)
      end
    end

    # Live evidence: 10 publications stranded in :verifying because process!
    # only rescued ActiveRecord::RecordInvalid/RecordNotSaved. A
    # FileStorageService::QuotaExceededError (a plain StandardError raised
    # mid-upload, after start_verifying! already ran) bubbled past
    # mark_failed! and the row was never marked failed.
    context "when upload_to_storage! raises a non-AR StandardError" do
      it "marks the publication failed instead of stranding it in :verifying" do
        tempfile = Tempfile.new("disk-image-spec")
        tempfile.write("bytes")
        tempfile.flush
        local_path = tempfile.path
        ok_ingest = System::DiskImageOciIngestService::Result.new(
          ok?: true, error: nil, local_path: local_path,
          cosign_bundle_b64: nil, attestation_bundle_b64: nil
        )
        allow(System::DiskImageOciIngestService).to receive(:verify_and_pull!).and_return(ok_ingest)

        fake_storage = instance_double(FileStorageService)
        allow(FileStorageService).to receive(:new).and_return(fake_storage)
        allow(fake_storage).to receive(:upload_file)
          .and_raise(FileStorageService::QuotaExceededError, "Storage quota exceeded")

        expect {
          described_class.process!(publication: publication)
        }.not_to raise_error

        expect(publication.reload.status).to eq("failed")
        expect(publication.error_message.to_s).to include("QuotaExceededError")
        expect(
          System::FleetEvent.where(account: account, kind: "system.disk_image_publish_failed")
                             .where("payload ->> 'publication_id' = ?", publication.id)
                             .exists?
        ).to be true
      ensure
        tempfile&.close!
      end
    end

    # Regression for IMP-ff288e4d8cb0: a Gitea "redeliver webhook" (routine
    # while debugging CI) for a git_sha whose publication has since been
    # retired/purged upserts the existing row with status preserved (see
    # DiskImageBuiltController#upsert_publication!). start_verifying! and
    # mark_published! are BOTH silent no-ops for retired/purged rows
    # (whiny_transitions:false, retired/purged aren't in either event's
    # from-state list) — but before this fix, ingest + upload_to_storage! +
    # node_platform.update! ran unconditionally anyway, pointing the
    # platform at a brand-new orphaned FileObject that no publication row
    # references.
    context "when a webhook is redelivered for a publication that has moved past ingest" do
      let(:prior_pointer) { create(:file_object, account: account) }

      before { platform.update!(disk_image_file_object_id: prior_pointer.id) }

      shared_examples "a strict no-op re-entry" do
        it "does not touch ingest, storage, or the platform's FileObject pointer" do
          expect(System::DiskImageOciIngestService).not_to receive(:verify_and_pull!)

          result = nil
          expect {
            result = described_class.process!(publication: stale_publication)
          }.not_to change { FileManagement::Object.count }

          expect(result.ok?).to be false
          expect(stale_publication.reload.status).to eq(stale_publication_status)
          expect(platform.reload.disk_image_file_object_id).to eq(prior_pointer.id)
        end
      end

      context "retired" do
        let(:stale_publication_status) { "retired" }
        let(:stale_publication) do
          create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
        end

        include_examples "a strict no-op re-entry"
      end

      context "purged" do
        let(:stale_publication_status) { "purged" }
        let(:stale_publication) do
          create(:system_disk_image_publication, account: account, node_platform: platform,
                 status: "purged", purged_at: Time.current)
        end

        include_examples "a strict no-op re-entry"
      end
    end
  end
end
