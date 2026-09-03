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
      affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ]
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
      # openssl-base has no SBOM, so this is a keyword-only hit with no
      # version evidence: suspected, never open (IMP-7bba0413c36a).
      expect(exp.state).to eq("suspected")
      expect(exp.match_method).to eq("keyword")
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

  # IMP-7bba0413c36a — the keyword fallback matched module NAMES only and minted
  # `open` critical exposures with no version evidence: every open critical
  # exposure on the 2026-09-03 control plane was a 2009 CVE (CVE-2009-3616 on
  # qemu-guest-agent modules, CVE-2009-3555 on nginx) whose NVD entry carries
  # version "*". A name-only hit is a SUSPICION, and a suspicion about a CVE
  # fixed upstream years before the module existed is not even that.
  describe "keyword fallback evidence (IMP-7bba0413c36a)" do
    def sbom_artifact_for(version, packages)
      System::ModuleArtifact.create!(
        node_module_version: version,
        oci_ref: "registry.example/#{version.node_module.name}:#{version.version_number}",
        oci_digest: "sha256:#{SecureRandom.hex(32)}",
        media_type: "application/vnd.powernode.module.v1",
        architecture: "amd64", size_bytes: 1024, built_at: Time.current,
        sbom_packages_data: packages, sbom_packages_count: packages.size,
        sbom_packages_synced_at: Time.current
      )
    end

    it "mints a versionless keyword hit as `suspected` with match_method keyword, never as an open exposure" do
      cve.update!(published_at: 1.day.ago, severity: "critical")

      result = described_class.calculate!(cve: cve, account: account)
      expect(result.ok?).to be true
      expect(result.keyword_fallback_count).to eq(1)

      exp = System::CveExposure.find_by(cve: cve, node_module_version: openssl_version)
      expect(exp.state).to eq("suspected")
      expect(exp.match_method).to eq("keyword")
      expect(exp.package_version).to be_blank
      expect(System::CveExposure.open.where(cve: cve)).to be_empty
      expect(System::CveExposure.unresolved.where(cve: cve)).to be_empty
    end

    it "does not mint a keyword hit at all when the CVE predates the module's first version by more than the window" do
      old_cve = System::Cve.create!(
        cve_id: "CVE-2009-3616", severity: "critical",
        affected_packages: [ { "name" => "openssl", "version" => "*" } ],
        published_at: Time.utc(2009, 10, 9)
      )

      result = nil
      expect {
        result = described_class.calculate!(cve: old_cve, account: account)
      }.not_to change(System::CveExposure, :count)
      expect(result.ok?).to be true
      expect(result.keyword_fallback_count).to eq(0)
      expect(result.keyword_age_skipped_count).to eq(1)
    end

    it "resolves the window through the SiteSetting with the constant as fallback" do
      expect(described_class::DEFAULT_KEYWORD_MATCH_MAX_AGE_DAYS).to be_positive
      ::SiteSetting.set(described_class::KEYWORD_MATCH_MAX_AGE_SETTING_KEY, 365 * 30, setting_type: "integer")
      old_cve = System::Cve.create!(
        cve_id: "CVE-2009-3555", severity: "critical",
        affected_packages: [ { "name" => "openssl", "version" => "*" } ],
        published_at: Time.utc(2009, 11, 9)
      )

      result = described_class.calculate!(cve: old_cve, account: account)
      expect(result.keyword_age_skipped_count).to eq(0)
      exp = System::CveExposure.find_by(cve: old_cve, node_module_version: openssl_version)
      expect(exp).to be_present
      expect(exp.state).to eq("suspected")
    end

    it "still mints (as suspected) when the CVE carries no published_at — age cannot be judged" do
      expect(cve.published_at).to be_nil
      result = described_class.calculate!(cve: cve, account: account)
      expect(result.keyword_age_skipped_count).to eq(0)
      expect(System::CveExposure.find_by(cve: cve, node_module_version: openssl_version).state).to eq("suspected")
    end

    it "flips a suspected row to open with match_method sbom once an SBOM match confirms it" do
      described_class.calculate!(cve: cve, account: account)
      row = System::CveExposure.find_by(cve: cve, node_module_version: openssl_version)
      expect(row.state).to eq("suspected")

      sbom_artifact_for(openssl_version, [ { "name" => "openssl", "version" => "3.1.3", "ecosystem" => "generic" } ])
      openssl_version.reload

      result = described_class.calculate!(cve: cve, account: account)
      expect(result.sbom_match_count).to eq(1)
      expect(result.exposures_updated).to eq(1)

      row.reload
      expect(row.state).to eq("open")
      expect(row.match_method).to eq("sbom")
      expect(row.package_version).to eq("3.1.3")
      expect(System::CveExposure.open.where(cve: cve)).to contain_exactly(row)
    end

    it "leaves a row resolved as a false positive resolved when the keyword re-matches" do
      described_class.calculate!(cve: cve, account: account)
      row = System::CveExposure.find_by(cve: cve, node_module_version: openssl_version)
      row.resolve!(note: "keyword-fallback false positive (no version evidence)")

      result = described_class.calculate!(cve: cve, account: account)
      expect(result.exposures_updated).to eq(0)
      expect(row.reload.state).to eq("resolved")
    end
  end
end
