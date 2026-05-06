# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.L — ModuleArtifact
RSpec.describe System::ModuleArtifact, type: :model do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:category)       { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(
      :system_node_module,
      account: account, node_platform: platform, category: category,
      variety: "subscription", name: "nginx-mod", priority: 0
    )
  end
  let(:version) do
    System::NodeModuleVersion.create!(
      node_module: node_module,
      version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {}
    )
  end

  let(:default_attrs) do
    {
      node_module_version: version,
      oci_ref: "registry.example.com/account/nginx-mod:v1.0.0",
      oci_digest: "sha256:#{'a' * 64}",
      media_type: described_class::DEFAULT_MEDIA_TYPE,
      architecture: "amd64",
      size_bytes: 12_345_678,
      built_at: Time.current
    }
  end

  describe "validations" do
    it "is valid with full provenance" do
      expect(described_class.new(default_attrs)).to be_valid
    end

    it "rejects malformed oci_digest" do
      bad = described_class.new(default_attrs.merge(oci_digest: "not-a-digest"))
      expect(bad).not_to be_valid
      expect(bad.errors[:oci_digest]).to be_present
    end

    it "rejects unsupported architecture" do
      bad = described_class.new(default_attrs.merge(architecture: "powerpc"))
      expect(bad).not_to be_valid
      expect(bad.errors[:architecture]).to be_present
    end

    it "enforces uniqueness on (version, architecture)" do
      described_class.create!(default_attrs)
      dup = described_class.new(default_attrs.merge(oci_digest: "sha256:#{'b' * 64}"))
      expect(dup).not_to be_valid
      expect(dup.errors[:node_module_version_id]).to be_present
    end

    it "permits two artifacts on same version with different architectures" do
      described_class.create!(default_attrs)
      arm = described_class.create!(default_attrs.merge(
        architecture: "arm64",
        oci_digest: "sha256:#{'b' * 64}"
      ))
      expect(arm).to be_persisted
    end
  end

  describe "predicates" do
    it "#fully_attested? requires cosign_bundle + sbom_uri + provenance_uri" do
      bare = described_class.create!(default_attrs)
      expect(bare).not_to be_fully_attested

      bare.update!(
        cosign_bundle: "stub",
        sbom_uri: "oci://x/sbom",
        provenance_uri: "oci://x/prov"
      )
      expect(bare).to be_fully_attested
    end

    it "#has_fsverity? mirrors presence of fsverity_root_hash" do
      a = described_class.create!(default_attrs)
      expect(a).not_to have_fsverity
      a.update!(fsverity_root_hash: "abc123")
      expect(a).to have_fsverity
    end
  end

  describe "scopes" do
    let!(:amd) { described_class.create!(default_attrs) }
    let!(:arm) do
      described_class.create!(default_attrs.merge(
        architecture: "arm64",
        oci_digest: "sha256:#{'b' * 64}"
      ))
    end

    it "filters by architecture" do
      expect(described_class.amd64).to include(amd)
      expect(described_class.amd64).not_to include(arm)
      expect(described_class.arm64).to include(arm)
      expect(described_class.arm64).not_to include(amd)
    end

    it "for_arch is parameterized" do
      expect(described_class.for_arch("arm64")).to include(arm)
    end
  end
end
