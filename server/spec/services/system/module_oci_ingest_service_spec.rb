# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M1.A — ModuleOciIngestService (LocalOciAdapter happy path).
RSpec.describe System::ModuleOciIngestService do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "ingest-mod")
  end
  let(:version) do
    System::NodeModuleVersion.create!(
      node_module: node_module, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {}
    )
  end

  let(:oci_ref) { "registry.example.com/account/ingest-mod:v1.0.0" }

  describe ".ingest!" do
    it "creates one ModuleArtifact per architecture and denormalizes onto version" do
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)

      expect(result.ok?).to be true
      expect(result.module_artifacts.size).to eq(2)
      arches = result.module_artifacts.map(&:architecture).sort
      expect(arches).to eq(%w[amd64 arm64])

      version.reload
      expect(version.oci_digest).to be_present
      expect(version.fsverity_root_hash).to be_present
      expect(version.sbom_uri).to eq("#{oci_ref}.sbom")
      expect(version.provenance_uri).to eq("#{oci_ref}.prov")
      expect(version.vex_uri).to eq("#{oci_ref}.vex")
    end

    it "is idempotent — running twice updates instead of duplicating" do
      described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(2)
    end

    it "fails clearly when oci_ref is blank" do
      result = described_class.ingest!(node_module_version: version, oci_ref: "")
      expect(result.ok?).to be false
      expect(result.error).to match(/oci_ref required/)
    end

    it "fails clearly when version is missing" do
      result = described_class.ingest!(node_module_version: nil, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/node_module_version required/)
    end

    it "fails when manifest fetch errors" do
      adapter = described_class.adapter
      adapter.stub_manifest = { error: "no such tag" }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/manifest fetch failed/)
    end

    it "fails when signature verification errors" do
      adapter = described_class.adapter
      adapter.stub_verification = { error: "signature does not match expected identity" }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/cosign verify failed/)
    end

    it "rolls back on artifact validation failure (mid-loop error)" do
      adapter = described_class.adapter
      adapter.stub_manifest = {
        per_arch_descriptors: [
          { architecture: "amd64", oci_digest: "sha256:#{'a' * 64}", size_bytes: 1, built_at: Time.current },
          { architecture: "powerpc", oci_digest: "sha256:#{'b' * 64}", size_bytes: 1, built_at: Time.current }
        ]
      }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/unsupported architecture|powerpc/)
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(0)
    end
  end

  describe "adapter selection" do
    it "uses LocalOciAdapter in test by default" do
      expect(described_class.adapter).to be_a(described_class::LocalOciAdapter)
    end

    it "honors POWERNODE_OCI_MODE=oras" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_OCI_MODE" => "oras"))
      described_class.reset!
      expect(described_class.adapter).to be_a(described_class::OrasOciAdapter)
    end
  end
end
