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
  end
end
