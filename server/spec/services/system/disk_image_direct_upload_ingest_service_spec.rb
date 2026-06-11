# frozen_string_literal: true

require "rails_helper"

# Audit F5-11 — direct-upload mode: CI PUTs the image straight to the
# storage backend via presigned URL, then this service re-verifies the
# stored bytes. Like the OCI path it never mutates publication rows —
# a checksum failure returns an error Result and the processor marks the
# row failed, so no publication ever reaches published with bad bytes.
RSpec.describe System::DiskImageDirectUploadIngestService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:bytes)    { "uploaded-image-#{SecureRandom.hex(8)}" }
  let(:storage)  { instance_double(FileStorageService) }

  before do
    allow(FileStorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:stream_file) do |_file_object, &block|
      bytes.chars.each_slice(8) { |chunk| block.call(chunk.join) }
    end
  end

  def publication_for(sha256)
    create(:system_disk_image_publication, :published,
           account: account, node_platform: platform, sha256: sha256,
           cosign_bundle: "Y29zaWdu", attestation_bundle: "YXR0ZXN0")
  end

  it "fails without a file_object (upload never landed)" do
    pub = create(:system_disk_image_publication, account: account, node_platform: platform)

    result = described_class.verify!(publication: pub)

    expect(result.ok?).to be false
    expect(result.error).to match(/file_object required/)
  end

  it "rejects a checksum mismatch and leaves the publication row unmutated" do
    pub = publication_for("f" * 64)

    result = described_class.verify!(publication: pub)

    expect(result.ok?).to be false
    expect(result.error).to match(/sha256 mismatch on uploaded file/)
    expect(pub.reload.status).to eq("published")
  end

  it "verifies matching bytes, stages a local copy, and passes the cosign bundles through" do
    pub = publication_for(Digest::SHA256.hexdigest(bytes))

    result = described_class.verify!(publication: pub)

    expect(result.ok?).to be true
    expect(File.read(result.local_path)).to eq(bytes)
    expect(result.cosign_bundle_b64).to eq("Y29zaWdu")
    expect(result.attestation_bundle_b64).to eq("YXR0ZXN0")
  end

  it "converts a storage streaming error into a failure Result" do
    allow(storage).to receive(:stream_file).and_raise(StandardError, "backend unreachable")
    pub = publication_for("a" * 64)

    result = described_class.verify!(publication: pub)

    expect(result.ok?).to be false
    expect(result.error).to match(/direct-upload verify error.*backend unreachable/)
  end
end
