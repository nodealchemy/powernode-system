# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block F — ModuleDiffService.
RSpec.describe System::ModuleDiffService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "diff-mod")
  end

  let!(:version_a) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [ "L2V0Yy9zZWNyZXQ=" ],          # base64("/etc/secret")
      file_spec: [ "L2V0Yy9hcHA=" ],          # base64("/etc/app")
      package_spec: [ "bnNzcg==" ],           # base64("nssr")
      config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
  end

  let!(:version_b) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 2,
      mask: [ "L2V0Yy9zZWNyZXQ=" ],
      file_spec: [ "L2V0Yy9hcHA=", "L2V0Yy9uZXc=" ],   # adds /etc/new
      package_spec: [ "bnNzcg==", "Y3VybA==" ],         # adds curl
      config: {},
      oci_digest: "sha256:#{'b' * 64}"
    )
  end

  describe ".compare" do
    it "returns unchanged=true for the same effective composition" do
      result = described_class.compare(version_a: version_a, version_b: version_a)
      expect(result.ok?).to be true
      expect(result.unchanged).to be true
      expect(result.fingerprint_a).to eq(result.fingerprint_b)
      expect(result.file_changes[:added]).to eq([])
      expect(result.file_changes[:removed]).to eq([])
    end

    it "returns added/removed file paths between versions" do
      result = described_class.compare(version_a: version_a, version_b: version_b)
      expect(result.ok?).to be true
      expect(result.unchanged).to be false
      expect(result.fingerprint_a).not_to eq(result.fingerprint_b)
      expect(result.file_changes[:added]).to include("/etc/new")
      expect(result.file_changes[:removed]).to be_empty
    end

    it "returns added/removed packages" do
      result = described_class.compare(version_a: version_a, version_b: version_b)
      expect(result.package_changes[:added]).to include("curl")
      expect(result.package_changes[:removed]).to be_empty
      expect(result.package_changes[:unchanged]).to eq(1)
    end

    it "fails fast on non-NodeModuleVersion inputs" do
      result = described_class.compare(version_a: "x", version_b: version_b)
      expect(result.ok?).to be false
    end
  end
end
