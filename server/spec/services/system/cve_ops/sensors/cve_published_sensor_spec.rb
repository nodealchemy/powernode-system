# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CveOps::Sensors::CvePublishedSensor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let(:node_module_version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1)
  end
  let(:sensor) { described_class.new(account: account) }

  def make_cve(cve_id:, severity:)
    ::System::Cve.create!(
      cve_id: cve_id,
      severity: severity,
      affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
      summary: "Test CVE #{cve_id}",
      feed_source: "TEST",
      published_at: Time.current
    )
  end

  def make_exposure(cve:, version: node_module_version, state: "open", detected_at: Time.current, package_name: "openssl")
    ::System::CveExposure.create!(
      cve: cve,
      node_module_version: version,
      package_name: package_name,
      package_version: "3.1.3",
      state: state,
      detected_at: detected_at
    )
  end

  describe "#sense" do
    it "returns no signals when no exposures exist" do
      expect(sensor.sense).to eq([])
    end

    it "emits a critical signal for a fresh critical CVE" do
      cve = make_cve(cve_id: "CVE-2026-90001", severity: "critical")
      make_exposure(cve: cve)

      sigs = sensor.sense
      expect(sigs.size).to eq(1)
      sig = sigs.first
      expect(sig.kind).to eq("system.cve_critical_published")
      expect(sig.severity).to eq(:critical)
      expect(sig.payload["cve_id"]).to eq("CVE-2026-90001")
      expect(sig.payload["affected_module_ids"]).to include(node_module.id)
      expect(sig.payload["exposure_count"]).to eq(1)
    end

    it "emits a high signal for a high-severity CVE" do
      cve = make_cve(cve_id: "CVE-2026-90002", severity: "high")
      make_exposure(cve: cve)
      sig = sensor.sense.first
      expect(sig.severity).to eq(:high)
    end

    it "skips low/medium severity CVEs" do
      [ "low", "medium" ].each_with_index do |sev, i|
        cve = make_cve(cve_id: "CVE-2026-9001#{i}", severity: sev)
        make_exposure(cve: cve)
      end
      expect(sensor.sense).to eq([])
    end

    it "skips resolved or remediating exposures" do
      cve = make_cve(cve_id: "CVE-2026-90004", severity: "critical")
      make_exposure(cve: cve, state: "resolved")
      make_exposure(cve: cve, state: "remediating", package_name: "openssl-libs")
      expect(sensor.sense).to eq([])
    end

    it "skips exposures detected before the lookback window" do
      cve = make_cve(cve_id: "CVE-2026-90005", severity: "critical")
      make_exposure(cve: cve, detected_at: 48.hours.ago)
      expect(sensor.sense).to eq([])
    end

    it "uses a stable fingerprint per cve_id" do
      cve = make_cve(cve_id: "CVE-2026-90006", severity: "critical")
      make_exposure(cve: cve)
      sig = sensor.sense.first
      expect(sig.fingerprint).to eq("cve_pub:CVE-2026-90006")
    end

    it "groups multiple exposures of the same CVE into one signal" do
      cve = make_cve(cve_id: "CVE-2026-90007", severity: "critical")
      make_exposure(cve: cve, package_name: "openssl")
      make_exposure(cve: cve, package_name: "openssl-dev")

      sigs = sensor.sense
      expect(sigs.size).to eq(1)
      expect(sigs.first.payload["exposure_count"]).to eq(2)
      expect(sigs.first.payload["affected_packages"]).to match_array(%w[openssl openssl-dev])
    end

    it "scopes to the current account" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_cat = create(:system_node_module_category, account: other_account)
      other_mod = create(:system_node_module, account: other_account, node_platform: other_platform,
                         category: other_cat, variety: "subscription", name: "other-mod")
      other_ver = create(:system_node_module_version, node_module: other_mod)
      cve = make_cve(cve_id: "CVE-2026-90008", severity: "critical")
      make_exposure(cve: cve, version: other_ver)

      expect(sensor.sense).to eq([])
    end
  end
end
