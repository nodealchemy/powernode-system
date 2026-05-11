# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::CveRemediationOrchestrationExecutor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:template)  { create(:system_node_template, account: account, node_platform: platform) }

  let!(:openssl_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let!(:openssl_v1) do
    create(:system_node_module_version, node_module: openssl_mod, version_number: 1)
  end
  let(:repo) { create(:system_package_repository, account: account) }
  let!(:link) do
    create(:system_package_module_link,
           node_module: openssl_mod,
           package_repository: repo,
           package_name: "openssl",
           package_version: "3.1.3",
           architecture: "amd64")
  end
  let!(:cve) do
    ::System::Cve.create!(
      cve_id: "CVE-2026-50001",
      severity: "critical",
      affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
      summary: "Test",
      feed_source: "TEST"
    )
  end
  let!(:exposure) do
    ::System::CveExposure.create!(
      cve: cve, node_module_version: openssl_v1, package_name: "openssl",
      package_version: "3.1.3", state: "open", detected_at: Time.current
    )
  end

  let(:executor) { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises a security skill with cve_id input" do
      d = described_class.descriptor
      expect(d[:name]).to eq("cve_remediation_orchestration")
      expect(d[:category]).to eq("security")
      expect(d.dig(:inputs, :cve_id, :required)).to be true
    end
  end

  describe "#execute" do
    it "fails fast when the CVE doesn't exist" do
      r = executor.execute(cve_id: "CVE-2099-00001")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/cve not found/)
    end

    it "triages the CVE and dispatches a package refresh for the linked module" do
      r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ openssl_mod.id ])
      expect(r[:success]).to be true

      data = r[:data]
      expect(data[:cve_id]).to eq("CVE-2026-50001")
      expect(data[:refresh_dispatches]).not_to be_empty
      expect(data[:refresh_dispatches].first[:package_module_link_id]).to eq(link.id)
      expect(data[:refresh_dispatches].first[:ok]).to be true
    end

    it "transitions named exposures to remediating state" do
      executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])
      expect(exposure.reload.state).to eq("remediating")
    end

    it "produces a rolling upgrade plan when a newer blessed version exists" do
      blessed = create(:system_node_module_version, node_module: openssl_mod,
                       version_number: 2, promotion_state: "blessed")
      openssl_mod.update!(current_version: openssl_v1)
      node = create(:system_node, account: account, node_template: template, name: "n1")
      System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)

      r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ openssl_mod.id ])

      plans = r[:data][:rolling_upgrade_plans]
      expect(plans).not_to be_empty
      expect(plans.first[:node_module_id]).to eq(openssl_mod.id)
      expect(plans.first[:target_version_id]).to eq(blessed.id)
    end

    it "is idempotent for already-remediating exposures" do
      exposure.update!(state: "remediating")
      r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])
      expect(r[:success]).to be true
      expect(r[:data][:exposures_remediating]).to eq(0)
    end
  end
end
