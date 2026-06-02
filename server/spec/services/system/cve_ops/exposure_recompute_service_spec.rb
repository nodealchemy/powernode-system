# frozen_string_literal: true

require "rails_helper"

# Optimized exposure recompute extracted from WorkerApi::CveController. The
# prior controller loop swept ALL accounts × recent CVEs (re-querying the CVE
# set per account); this verifies the early-exits + the skip-empty-accounts
# optimization. The module-bearing account set is stubbed so the test stays
# deterministic (the node_module factory pulls in associated records).
RSpec.describe System::CveOps::ExposureRecomputeService do
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  def ok_result(created: 0, updated: 0)
    double("ExposureCalculator::Result", ok?: true, exposures_created: created, exposures_updated: updated)
  end

  def stub_module_accounts(ids)
    allow(System::NodeModule).to receive_message_chain(:distinct, :pluck).and_return(ids)
  end

  it "returns 0 and never calls the calculator when there are no recent CVEs" do
    expect(System::CveOps::ExposureCalculator).not_to receive(:calculate!)
    expect(described_class.recompute_recent!).to eq(0)
  end

  context "with a recent CVE" do
    let!(:cve) { create(:system_cve, ingested_at: 1.minute.ago) }

    it "returns 0 (no calculator calls) when no account has a NodeModule" do
      stub_module_accounts([])
      expect(System::CveOps::ExposureCalculator).not_to receive(:calculate!)
      expect(described_class.recompute_recent!).to eq(0)
    end

    it "computes exposures only for module-bearing accounts, skipping the rest" do
      stub_module_accounts([ account_a.id ])
      allow(System::CveOps::ExposureCalculator).to receive(:calculate!).and_return(ok_result(created: 2, updated: 3))

      expect(described_class.recompute_recent!).to eq(5)
      expect(System::CveOps::ExposureCalculator).to have_received(:calculate!).with(cve: cve, account: account_a).once
      expect(System::CveOps::ExposureCalculator).not_to have_received(:calculate!).with(hash_including(account: account_b))
    end

    it "sums created + updated across all (module-account × recent-cve) pairs" do
      cve2 = create(:system_cve, ingested_at: 2.minutes.ago)
      stub_module_accounts([ account_a.id, account_b.id ])
      allow(System::CveOps::ExposureCalculator).to receive(:calculate!).and_return(ok_result(created: 1, updated: 0))

      # 2 module-accounts × 2 recent CVEs × 1 each = 4
      expect(described_class.recompute_recent!).to eq(4)
      expect(cve2).to be_present
    end

    it "ignores calculator results that are not ok" do
      stub_module_accounts([ account_a.id ])
      allow(System::CveOps::ExposureCalculator).to receive(:calculate!)
        .and_return(double("Result", ok?: false, exposures_created: 0, exposures_updated: 0))
      expect(described_class.recompute_recent!).to eq(0)
    end

    it "excludes CVEs ingested before the window" do
      old_cve = create(:system_cve, ingested_at: 2.hours.ago)
      stub_module_accounts([ account_a.id ])
      seen = []
      allow(System::CveOps::ExposureCalculator).to receive(:calculate!) do |cve:, account:|
        seen << cve
        ok_result
      end

      described_class.recompute_recent!
      expect(seen).to include(cve)
      expect(seen).not_to include(old_cve)
    end
  end
end
