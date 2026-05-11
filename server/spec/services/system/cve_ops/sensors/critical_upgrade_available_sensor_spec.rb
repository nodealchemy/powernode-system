# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CveOps::Sensors::CriticalUpgradeAvailableSensor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-mod")
  end
  let(:node_module_version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1)
  end
  let(:repo) do
    create(:system_package_repository, account: account)
  end
  let(:link) do
    create(:system_package_module_link,
           node_module: node_module,
           package_repository: repo,
           package_name: "openssl",
           package_version: "3.1.3",
           architecture: "amd64",
           last_synced_at: 48.hours.ago)
  end
  let(:sensor) { described_class.new(account: account) }

  def make_package(version:, status: "live")
    pkg = create(:system_package,
                 package_repository: repo,
                 name: "openssl",
                 architecture: "amd64",
                 version: version)
    pkg.update!(obsoleted_at: nil) if status == "live"
    pkg
  end

  def make_cve_exposure(cve_id: "CVE-2026-95001", severity: "critical")
    cve = ::System::Cve.create!(
      cve_id: cve_id,
      severity: severity,
      affected_packages: [ { "name" => "openssl" } ],
      summary: "Test",
      feed_source: "TEST"
    )
    ::System::CveExposure.create!(
      cve: cve,
      node_module_version: node_module_version,
      package_name: "openssl",
      package_version: "3.1.3",
      state: "open",
      detected_at: Time.current
    )
    cve
  end

  describe "#sense" do
    it "returns no signals when no PackageModuleLink rows exist" do
      expect(sensor.sense).to eq([])
    end

    it "skips when link has no CVE exposure even if drift is present" do
      link
      make_package(version: "3.1.4")
      expect(sensor.sense).to eq([])
    end

    it "emits a critical signal when both drift AND critical CVE are present" do
      link
      make_package(version: "3.1.4")
      make_cve_exposure(cve_id: "CVE-2026-95001", severity: "critical")

      sigs = sensor.sense
      expect(sigs.size).to eq(1)
      sig = sigs.first
      expect(sig.kind).to eq("system.module_critical_upgrade_ready")
      expect(sig.severity).to eq(:critical)
      expect(sig.payload["node_module_id"]).to eq(node_module.id)
      expect(sig.payload["upstream_version"]).to eq("3.1.4")
      expect(sig.payload["current_version"]).to eq("3.1.3")
      expect(sig.payload["cve_ids"]).to include("CVE-2026-95001")
    end

    it "uses high severity when only high (not critical) CVEs exist" do
      link
      make_package(version: "3.1.4")
      make_cve_exposure(cve_id: "CVE-2026-95002", severity: "high")

      sig = sensor.sense.first
      expect(sig.severity).to eq(:high)
    end

    it "skips when upstream version is not newer than local" do
      link
      make_package(version: "3.1.3")
      make_cve_exposure
      expect(sensor.sense).to eq([])
    end

    it "uses a stable fingerprint per (link_id, upstream_version)" do
      link
      make_package(version: "3.1.4")
      make_cve_exposure

      sig = sensor.sense.first
      expect(sig.fingerprint).to eq("crit_upgrade:#{link.id}:3.1.4")
    end
  end
end
