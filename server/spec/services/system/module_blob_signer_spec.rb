# frozen_string_literal: true

require "rails_helper"

# The PRODUCER of the module blob signature — the artefact the agent's
# Verifier can actually check. Attaches the platform's `cosign sign-blob`
# bundle over the erofs bytes to NodeModuleVersion.artifacts.erofs, the store
# the node-facing serializer reads (the same hop the fs-verity root takes).
RSpec.describe System::ModuleBlobSigner do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "blob-mod")
  end
  let(:digest) { "sha256:#{'a' * 64}" }
  let(:erofs) do
    { "oci_ref" => "git.example/powernode/blob-mod:v1", "oci_digest" => digest,
      "fsverity_root" => "sha256:#{'b' * 64}", "size" => 40_000, "media_type" => "application/vnd.powernode.erofs" }
  end
  let(:version) do
    create(:system_node_module_version, node_module: mod, version_number: 1).tap do |v|
      v.update_columns(artifacts: { "erofs" => erofs })
    end
  end
  let(:bundle_b64) { Base64.strict_encode64('{"pretend":"bundle"}') }

  before { ::SiteSetting.set(described_class::ENABLED_SETTING, true, setting_type: "boolean") }

  def ok_result
    System::ModuleSigningService::BlobResult.new(ok?: true, digest: digest, bundle_b64: bundle_b64)
  end

  describe ".attach!" do
    it "signs the erofs blob by ref+digest and persists the bundle beside the fs-verity root" do
      expect(System::ModuleSigningService).to receive(:sign_blob!)
        .with(hash_including(oci_ref: erofs["oci_ref"], digest: digest, size: 40_000, account: account, node_module: mod))
        .and_return(ok_result)

      result = described_class.attach!(version, node_module: mod)

      expect(result.ok?).to be true
      erofs_after = version.reload.artifacts["erofs"]
      expect(erofs_after[described_class::BUNDLE_KEY]).to eq(bundle_b64)
      expect(erofs_after["fsverity_root"]).to eq(erofs["fsverity_root"]), "must MERGE, never replace the erofs hash"
    end

    it "is non-blocking on a signing failure: artifacts untouched, failure event emitted" do
      allow(System::ModuleSigningService).to receive(:sign_blob!)
        .and_return(System::ModuleSigningService::BlobResult.new(ok?: false, error: "vault sealed"))
      expect(System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(hash_including(kind: "system.module_blob_signing_failed", severity: :medium,
                             payload: hash_including(error: "vault sealed")))

      result = described_class.attach!(version, node_module: mod)

      expect(result.ok?).to be false
      expect(version.reload.artifacts["erofs"]).not_to have_key(described_class::BUNDLE_KEY)
    end

    it "skips (does not call the signer) when the version has no oci_digest yet" do
      version.update_columns(artifacts: { "erofs" => erofs.except("oci_digest") })
      expect(System::ModuleSigningService).not_to receive(:sign_blob!)

      result = described_class.attach!(version, node_module: mod)
      expect(result.skipped).to be true
      expect(result.error).to match(/oci_digest/)
    end

    it "skips when blob signing is disabled by setting" do
      ::SiteSetting.set(described_class::ENABLED_SETTING, false, setting_type: "boolean")
      expect(System::ModuleSigningService).not_to receive(:sign_blob!)
      expect(described_class.attach!(version, node_module: mod).skipped).to be true
    end

    it "never raises out of a signer crash" do
      allow(System::ModuleSigningService).to receive(:sign_blob!).and_raise(RuntimeError, "boom")
      expect { described_class.attach!(version, node_module: mod) }.not_to raise_error
      expect(described_class.attach!(version, node_module: mod).ok?).to be false
    end
  end

  describe ".signed?" do
    it "reads the bundle off the version's erofs artifact" do
      expect(described_class.signed?(version)).to be false
      version.update_columns(artifacts: { "erofs" => erofs.merge(described_class::BUNDLE_KEY => bundle_b64) })
      expect(described_class.signed?(version.reload)).to be true
    end
  end

  describe ".backfill!" do
    let!(:current_unsigned) { version.tap { |v| mod.update_columns(current_version_id: v.id) } }
    let!(:older_unsigned) do
      create(:system_node_module_version, node_module: mod, version_number: 2).tap do |v|
        v.update_columns(artifacts: { "erofs" => erofs })
      end
    end

    it "dry-run counts only CURRENT versions lacking a bundle and signs nothing" do
      expect(System::ModuleSigningService).not_to receive(:sign_blob!)
      report = described_class.backfill!(account: account, dry_run: true)
      expect(report[:candidates].map(&:id)).to eq([ current_unsigned.id ])
      expect(report[:signed]).to eq(0)
    end

    it "signs each candidate when applied and reports counts" do
      allow(System::ModuleSigningService).to receive(:sign_blob!).and_return(ok_result)
      report = described_class.backfill!(account: account, dry_run: false)
      expect(report[:signed]).to eq(1)
      expect(current_unsigned.reload.artifacts.dig("erofs", described_class::BUNDLE_KEY)).to eq(bundle_b64)
      expect(older_unsigned.reload.artifacts["erofs"]).not_to have_key(described_class::BUNDLE_KEY)
    end

    it "is idempotent: a signed current version is no longer a candidate" do
      allow(System::ModuleSigningService).to receive(:sign_blob!).and_return(ok_result)
      described_class.backfill!(account: account, dry_run: false)
      expect(described_class.backfill!(account: account, dry_run: true)[:candidates]).to be_empty
    end
  end
end
