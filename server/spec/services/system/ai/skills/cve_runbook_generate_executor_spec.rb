# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::CveRunbookGenerateExecutor do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:executor) { described_class.new(account: account) }

  let!(:cve) do
    ::System::Cve.create!(
      cve_id: "CVE-2026-12345",
      severity: "high",
      summary: "Buffer overflow in libfoo allows remote code execution",
      affected_packages: [ { "name" => "libfoo", "version" => "<1.2.3", "ecosystem" => "deb" } ],
      feed_source: "manual"
    )
  end

  describe ".descriptor" do
    it "exposes the standard skill descriptor shape" do
      d = described_class.descriptor
      expect(d[:name]).to eq("cve_runbook_generate")
      expect(d[:category]).to eq("security")
      expect(d[:inputs].keys).to include(:cve_id, :persist_as_page)
    end
  end

  describe "#execute" do
    context "when the CVE is not found" do
      it "returns failure with a hint to ingest first" do
        result = executor.execute(cve_id: "CVE-2099-99999")
        expect(result[:success]).to be false
        expect(result[:error]).to include("not found")
      end
    end

    context "when no exposures exist for the account" do
      it "returns success with zero counts and a 'No active exposures' note" do
        result = executor.execute(cve_id: cve.cve_id)

        expect(result[:success]).to be true
        expect(result[:data][:exposed_module_count]).to eq(0)
        expect(result[:data][:exposed_instance_count]).to eq(0)
        expect(result[:data][:risk_score]).to eq(0)
        expect(result[:data][:runbook_markdown]).to include("No active exposures detected")
      end
    end

    context "when exposures exist" do
      let(:node_module) { create(:system_node_module, account: account, name: "web-server") }
      let(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
      let!(:exposure) do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: version,
          package_name: "libfoo", package_version: "1.0.0",
          state: "open", detected_at: Time.current
        )
      end

      it "returns the count of exposed modules and renders them in the runbook" do
        result = executor.execute(cve_id: cve.cve_id)

        expect(result[:success]).to be true
        expect(result[:data][:exposed_module_count]).to eq(1)
        expect(result[:data][:risk_score]).to be > 0

        md = result[:data][:runbook_markdown]
        expect(md).to include("# Remediation Runbook: CVE-2026-12345")
        expect(md).to include("Severity: **high**")
        expect(md).to include("web-server")
        expect(md).to include("libfoo")
      end

      it "marks high-severity remediation as requires_approval" do
        result = executor.execute(cve_id: cve.cve_id)
        expect(result[:data][:requires_approval]).to be true
        expect(result[:data][:runbook_markdown]).to include("requires operator approval")
      end

      it "uses batch_pct=10 for non-critical severity" do
        result = executor.execute(cve_id: cve.cve_id)
        expect(result[:data][:runbook_markdown]).to include("batch_pct=10")
      end

      context "with critical severity" do
        before { cve.update!(severity: "critical") }

        it "uses batch_pct=25 in the rolling upgrade step" do
          result = executor.execute(cve_id: cve.cve_id)
          expect(result[:data][:runbook_markdown]).to include("batch_pct=25")
        end
      end
    end

    context "cross-account isolation" do
      let(:other_node_module) { create(:system_node_module, account: other_account, name: "foreign-mod") }
      let(:other_version) { create(:system_node_module_version, node_module: other_node_module, version_number: 1) }

      before do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: other_version,
          package_name: "libfoo", package_version: "1.0.0",
          state: "open", detected_at: Time.current
        )
      end

      it "does not surface exposures from other accounts" do
        result = executor.execute(cve_id: cve.cve_id)
        expect(result[:data][:exposed_module_count]).to eq(0)
        expect(result[:data][:runbook_markdown]).not_to include("foreign-mod")
      end
    end

    context "with persist_as_page: true" do
      let(:user) { create(:user, account: account) }
      let(:executor) { described_class.new(account: account, user: user) }
      let(:node_module) { create(:system_node_module, account: account) }
      let(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }

      before do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: version,
          package_name: "libfoo", package_version: "1.0.0",
          state: "open", detected_at: Time.current
        )
      end

      it "creates a Page record when defined and returns its id" do
        skip "Page model not loaded in this env" unless defined?(::Page)

        result = executor.execute(cve_id: cve.cve_id, persist_as_page: true)

        expect(result[:data][:persisted_page_id]).to be_present
        page = ::Page.find(result[:data][:persisted_page_id])
        expect(page.title).to include("CVE-2026-12345")
        expect(page.metadata["tags"]).to include("cve:CVE-2026-12345")
      end

      it "skips persistence when no user is in context" do
        no_user_executor = described_class.new(account: account)
        result = no_user_executor.execute(cve_id: cve.cve_id, persist_as_page: true)

        expect(result[:data][:persisted_page_id]).to be_nil
      end
    end
  end
end
