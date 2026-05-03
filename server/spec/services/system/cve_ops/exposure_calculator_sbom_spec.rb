# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P4 — verifies the SBOM-aware code
# path of ExposureCalculator (the legacy keyword path is exercised
# elsewhere). Covers ecosystem-aware version-range matching via the
# integration of System::CveOps::VersionMatcher.
RSpec.describe System::CveOps::ExposureCalculator do
  let(:account) { create(:account) }
  let(:node_module) { create(:system_node_module, account: account, name: "web-server") }
  let(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }

  let!(:artifact) do
    System::ModuleArtifact.create!(
      node_module_version: version,
      oci_ref: "registry.example/web-server:1",
      oci_digest: "sha256:#{SecureRandom.hex(32)}",
      media_type: "application/vnd.powernode.module.v1",
      architecture: "amd64",
      size_bytes: 1024,
      built_at: Time.current,
      sbom_packages_data: [
        { "name" => "openssl", "version" => "3.0.5",   "ecosystem" => "generic" },
        { "name" => "libxml2", "version" => "2.9.14",  "ecosystem" => "generic" },
        { "name" => "express", "version" => "4.17.1",  "ecosystem" => "npm" }
      ],
      sbom_packages_count: 3,
      sbom_packages_synced_at: 1.day.ago
    )
  end

  describe ".calculate!" do
    context "matching SBOM packages with vulnerable version ranges" do
      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0001",
          severity: "high",
          affected_packages: [
            { "name" => "openssl", "version" => ">=3.0.0,<3.1.0", "ecosystem" => "generic" }
          ]
        )
      end

      it "creates a CveExposure when SBOM version is in the range" do
        result = described_class.calculate!(cve: cve, account: account)

        expect(result.ok?).to be true
        expect(result.sbom_match_count).to be > 0

        exposure = System::CveExposure.find_by(cve: cve, package_name: "openssl")
        expect(exposure).to be_present
        expect(exposure.package_version).to eq("3.0.5")
        expect(exposure.state).to eq("open")
      end
    end

    context "non-matching version (outside range)" do
      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0002",
          severity: "high",
          affected_packages: [
            { "name" => "openssl", "version" => "<3.0.0", "ecosystem" => "generic" }
          ]
        )
      end

      it "creates no exposure for openssl 3.0.5 against <3.0.0 range" do
        described_class.calculate!(cve: cve, account: account)

        expect(System::CveExposure.where(cve: cve, package_name: "openssl")).to be_empty
      end
    end

    context "ecosystem mismatch" do
      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0003",
          severity: "medium",
          # CVE targets npm version of express, not the generic one
          affected_packages: [
            { "name" => "express", "version" => ">=4.0.0,<5.0.0", "ecosystem" => "npm" }
          ]
        )
      end

      it "matches when ecosystem aligns" do
        described_class.calculate!(cve: cve, account: account)

        exposure = System::CveExposure.find_by(cve: cve, package_name: "express")
        expect(exposure).to be_present
        expect(exposure.package_version).to eq("4.17.1")
      end
    end

    context "wildcard / no constraint (NVD unknown range)" do
      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0004",
          severity: "critical",
          affected_packages: [
            { "name" => "libxml2", "version" => "*", "ecosystem" => "generic" }
          ]
        )
      end

      it "matches any version when constraint is *" do
        described_class.calculate!(cve: cve, account: account)

        expect(System::CveExposure.find_by(cve: cve, package_name: "libxml2")).to be_present
      end
    end

    context "fallback to keyword matching when no SBOM" do
      let!(:legacy_module) { create(:system_node_module, account: account, name: "legacy-openssl") }
      let!(:legacy_version) { create(:system_node_module_version, node_module: legacy_module) }
      # No artifact => no SBOM cached => keyword fallback path

      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0005",
          severity: "high",
          affected_packages: [
            { "name" => "openssl", "version" => "3.0.5", "ecosystem" => "generic" }
          ]
        )
      end

      it "still finds the legacy module via keyword fallback (false-positive-prone but safety net)" do
        result = described_class.calculate!(cve: cve, account: account)

        expect(result.ok?).to be true
        expect(result.keyword_fallback_count).to be > 0
        # The legacy module's name contains "openssl" — keyword match.
        legacy_exposure = System::CveExposure.find_by(node_module_version: legacy_version)
        expect(legacy_exposure).to be_present
      end
    end

    context "result struct fields" do
      let(:cve) do
        create_cve(
          cve_id: "CVE-2024-0006",
          severity: "low",
          affected_packages: [ { "name" => "openssl", "version" => ">=3.0.0", "ecosystem" => "generic" } ]
        )
      end

      it "tracks both sbom_match_count and keyword_fallback_count" do
        result = described_class.calculate!(cve: cve, account: account)

        expect(result).to respond_to(:sbom_match_count)
        expect(result).to respond_to(:keyword_fallback_count)
        expect(result.exposures_created).to be >= 1
      end
    end
  end

  def create_cve(cve_id:, severity:, affected_packages:)
    System::Cve.create!(
      cve_id: cve_id,
      severity: severity,
      affected_packages: affected_packages,
      published_at: Time.current,
      feed_source: "test"
    )
  end
end
