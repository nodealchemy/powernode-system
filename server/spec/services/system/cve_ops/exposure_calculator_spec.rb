# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block C — ExposureCalculator persists exposures.
RSpec.describe System::CveOps::ExposureCalculator do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let!(:openssl_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let!(:openssl_version) do
    System::NodeModuleVersion.create!(
      node_module: openssl_mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
  end

  let!(:cve) do
    System::Cve.create!(
      cve_id: "CVE-2026-12345",
      severity: "high",
      affected_packages: [{ "name" => "openssl", "version" => "<3.1.4" }]
    )
  end

  describe ".calculate!" do
    it "creates a CveExposure row when a module matches" do
      expect {
        result = described_class.calculate!(cve: cve, account: account)
        expect(result.ok?).to be true
        expect(result.exposures_created).to eq(1)
      }.to change(System::CveExposure, :count).by(1)

      exp = System::CveExposure.last
      expect(exp.cve_id).to eq(cve.id)
      expect(exp.node_module_version_id).to eq(openssl_version.id)
      expect(exp.package_name).to eq("openssl")
      expect(exp.state).to eq("open")
    end

    it "is idempotent on re-run" do
      described_class.calculate!(cve: cve, account: account)
      expect {
        described_class.calculate!(cve: cve, account: account)
      }.not_to change(System::CveExposure, :count)
    end

    it "ignores unrelated modules" do
      unrelated = create(:system_node_module, account: account, node_platform: platform,
                         category: category, variety: "subscription", name: "frobnicator")
      System::NodeModuleVersion.create!(
        node_module: unrelated, version_number: 1,
        mask: [], file_spec: [], package_spec: [], config: {},
        oci_digest: "sha256:#{'b' * 64}"
      )
      described_class.calculate!(cve: cve, account: account)
      mod_ids = System::CveExposure.where(cve: cve)
                  .joins(:node_module_version)
                  .pluck("system_node_module_versions.node_module_id")
      expect(mod_ids).not_to include(unrelated.id)
    end
  end
end
