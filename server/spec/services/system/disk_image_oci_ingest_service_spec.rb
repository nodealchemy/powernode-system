# frozen_string_literal: true

require "rails_helper"

# Audit F5-11 — OCI ingest is the verify gate between CI-published
# artifacts and fleet boot images. Note the architecture: this service
# verifies and pulls ONLY — it never creates or mutates publication
# rows. Failures return an error Result and the CALLER
# (DiskImagePublicationProcessor, separately specced) marks the
# publication failed; there is no partial row to roll back here.
RSpec.describe System::DiskImageOciIngestService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  after { described_class.reset! }

  describe ".verify_and_pull! argument gates" do
    it "fails without a publication" do
      result = described_class.verify_and_pull!(publication: nil)

      expect(result.ok?).to be false
      expect(result.error).to match(/publication required/)
    end

    it "fails when the publication has no oci_ref" do
      pub = create(:system_disk_image_publication, account: account,
                   node_platform: platform, oci_ref: nil)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/oci_ref required/)
    end

    it "refuses the production adapter when the platform has no cosign trust policy" do
      described_class.adapter = described_class::OrasDiskImageAdapter.new
      pub = create(:system_disk_image_publication, account: account, node_platform: platform)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/no cosign trust policy configured/)
    end
  end

  describe "digest verification (local adapter, real files)" do
    let(:image_bytes) { "powernode-disk-image-#{SecureRandom.hex(8)}" }
    let(:image_file) do
      f = Tempfile.new([ "disk-image-", ".img" ])
      f.binmode
      f.write(image_bytes)
      f.close
      f
    end

    after { image_file.unlink }

    def publication_for(sha256)
      create(:system_disk_image_publication, account: account, node_platform: platform,
             oci_ref: "local://#{image_file.path}", sha256: sha256,
             size_bytes: image_bytes.bytesize)
    end

    it "rejects a sha256 digest mismatch" do
      pub = publication_for("f" * 64)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/sha256 mismatch/)
      # No row mutation from this layer — the publication stays queued for
      # the processor to mark failed.
      expect(pub.reload.status).to eq("queued")
    end

    it "accepts a matching digest and returns the local path" do
      pub = publication_for(Digest::SHA256.hexdigest(image_bytes))

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be true
      expect(result.error).to be_nil
      expect(File.read(result.local_path)).to eq(image_bytes)
    end
  end
end
