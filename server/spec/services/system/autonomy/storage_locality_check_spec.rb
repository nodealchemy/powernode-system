# frozen_string_literal: true

require "rails_helper"

# RCP v2 (campaign 019f9250, increment p0c) — INV-6: member storage = local
# disk of a distinct node; shared NFS forbidden for member root disks.
RSpec.describe System::Autonomy::StorageLocalityCheck do
  let(:node) { create(:system_node, account: create(:account)) }

  describe ".network_backed_storage?" do
    it "returns nil (unverified) when the adapter doesn't support list_volume_types" do
      adapter = instance_double("System::Providers::BaseProvider")
      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: "dna-data")
      ).to be_nil
    end

    it "returns nil when storage_name is blank" do
      adapter = instance_double(System::Providers::ProxmoxProvider)
      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: nil)
      ).to be_nil
    end

    it "returns false for a local (zfspool) storage pool" do
      adapter = instance_double(System::Providers::ProxmoxProvider)
      allow(adapter).to receive(:list_volume_types).with("dna").and_return([
        { cloud_id: "dna-data", name: "dna-data", plugin_type: "zfspool", shared: false }
      ])

      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: "dna-data")
      ).to be false
    end

    it "returns true for an nfs storage pool" do
      adapter = instance_double(System::Providers::ProxmoxProvider)
      allow(adapter).to receive(:list_volume_types).with("dna").and_return([
        { cloud_id: "dsm-data", name: "dsm-data", plugin_type: "nfs", shared: true }
      ])

      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: "dsm-data")
      ).to be true
    end

    it "returns nil when the named storage isn't in the returned list" do
      adapter = instance_double(System::Providers::ProxmoxProvider)
      allow(adapter).to receive(:list_volume_types).with("dna").and_return([
        { cloud_id: "dna-data", name: "dna-data", plugin_type: "zfspool", shared: false }
      ])

      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: "unknown-storage")
      ).to be_nil
    end

    it "returns nil (fails soft) when the live call itself raises" do
      adapter = instance_double(System::Providers::ProxmoxProvider)
      allow(adapter).to receive(:list_volume_types).and_raise(StandardError, "PVE unreachable")

      expect(
        described_class.network_backed_storage?(provider_adapter: adapter, region_code: "dna", storage_name: "dna-data")
      ).to be_nil
    end
  end

  describe ".violation_for" do
    it "returns nil when not network-backed" do
      expect(described_class.violation_for(storage_name: "dna-data", network_backed: false, node: node)).to be_nil
    end

    it "returns a confirmed INV-6 descriptor when network-backed and confirmed" do
      violation = described_class.violation_for(storage_name: "dsm-data", network_backed: true, node: node, confirmed: true)
      expect(violation).to include(invariant: "INV-6", severity: :high, node_id: node.id, verified: true)
      expect(violation[:detail]).to match(/NFS\/CIFS per live PVE/)
    end

    it "returns an unverified-flag descriptor when network_backed is reported but not confirmed" do
      violation = described_class.violation_for(storage_name: "some-storage", network_backed: true, node: node, confirmed: false)
      expect(violation[:verified]).to be false
      expect(violation[:detail]).to match(/could not be independently verified/)
    end
  end

  describe ".assert_local_storage!" do
    let(:local_adapter) do
      instance_double(System::Providers::ProxmoxProvider).tap do |a|
        allow(a).to receive(:list_volume_types).and_return([ { cloud_id: "dna-data", name: "dna-data", plugin_type: "zfspool", shared: false } ])
      end
    end
    let(:nfs_adapter) do
      instance_double(System::Providers::ProxmoxProvider).tap do |a|
        allow(a).to receive(:list_volume_types).and_return([ { cloud_id: "dsm-data", name: "dsm-data", plugin_type: "nfs", shared: true } ])
      end
    end

    it "does not raise when strict: false, even for network-backed storage" do
      expect {
        described_class.assert_local_storage!(provider_adapter: nfs_adapter, region_code: "dna", storage_name: "dsm-data", strict: false)
      }.not_to raise_error
    end

    it "does not raise when strict: true and storage is confirmed local" do
      expect {
        described_class.assert_local_storage!(provider_adapter: local_adapter, region_code: "dna", storage_name: "dna-data", strict: true)
      }.not_to raise_error
    end

    it "raises when strict: true and storage is confirmed network-backed" do
      expect {
        described_class.assert_local_storage!(provider_adapter: nfs_adapter, region_code: "dna", storage_name: "dsm-data", strict: true)
      }.to raise_error(System::Autonomy::StorageLocalityCheck::StorageLocalityViolation, /network-attached/)
    end

    it "fails closed (raises) when strict: true and the answer is undetermined" do
      unverifiable_adapter = instance_double("System::Providers::BaseProvider")
      expect {
        described_class.assert_local_storage!(provider_adapter: unverifiable_adapter, region_code: "dna", storage_name: "mystery", strict: true)
      }.to raise_error(System::Autonomy::StorageLocalityCheck::StorageLocalityViolation, /could not verify/)
    end
  end
end
