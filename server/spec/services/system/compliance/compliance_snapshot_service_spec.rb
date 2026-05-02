# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M-D2-1 — ComplianceSnapshotService.
RSpec.describe System::Compliance::ComplianceSnapshotService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:instance) { create(:system_node_instance, :running, node: node) }

  describe ".snapshot!" do
    it "returns a complete structured snapshot with metadata" do
      result = described_class.snapshot!(account: account)
      expect(result.ok?).to be true
      snap = result.snapshot

      expect(snap[:metadata][:schema_version]).to eq(1)
      expect(snap[:metadata][:account_id]).to eq(account.id)
      expect(snap[:metadata][:generated_at]).to be_present

      expect(snap[:nodes].size).to eq(1)
      expect(snap[:instances].size).to eq(1)
      expect(snap[:counts][:nodes]).to eq(1)
      expect(snap[:counts][:running_instances]).to eq(1)
      expect(snap[:drift_summary]).to include(:drifted_count, :reconciled_count, :drift_ratio_pct)
    end

    it "fails on missing account" do
      result = described_class.snapshot!(account: nil)
      expect(result.ok?).to be false
      expect(result.error).to match(/account required/)
    end

    it "isolates per-account state (different account → different snapshot)" do
      other = create(:account)
      result = described_class.snapshot!(account: other)
      expect(result.snapshot[:nodes]).to be_empty
      expect(result.snapshot[:counts][:nodes]).to eq(0)
    end
  end
end
