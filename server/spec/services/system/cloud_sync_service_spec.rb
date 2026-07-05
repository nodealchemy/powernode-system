# frozen_string_literal: true

require "rails_helper"

# Audit F4-06 — sync_region_instances called provider_adapter.list_instances
# with no rescue, so a provider without a region-listing surface (pro_cloud)
# blew up the sync with a raised NotImplementedError instead of a structured
# result.
RSpec.describe System::CloudSyncService do
  let(:account)    { create(:account) }
  let(:region)     { create(:system_provider_region) }
  let(:connection) { double("provider connection") }
  let(:adapter) do
    instance_double("System::Providers::BaseProvider", provider_type: "pro_cloud")
  end

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region)
      .with(region, account).and_return(connection)
    allow(System::Providers::Registry).to receive(:for)
      .with(connection, region: region).and_return(adapter)
  end

  describe "#sync_region_instances" do
    it "returns a structured error when the provider lacks sync support" do
      allow(adapter).to receive(:supports?).with(:sync).and_return(false)
      allow(adapter).to receive(:list_instances)

      result = described_class.new.sync_region_instances(region: region, account: account)

      expect(result.success?).to be false
      expect(result.error).to match(/does not support .*sync/i)
      expect(adapter).not_to have_received(:list_instances)
    end

    # IMP-555e29eeb4ab: a VM deleted out-of-band never appears in
    # list_instances, and this method only iterated the cloud listing — the
    # row was never terminated by the scheduled path (SystemCloudSyncJob,
    # hourly). NotFound->terminated exists only in sync_instance_state,
    # which nothing schedules, so the deleted instance decayed into the
    # error-state strand instead of ever reaching :terminated.
    context "when a local instance is missing from the cloud listing (deleted out-of-band)" do
      before { allow(adapter).to receive(:supports?).with(:sync).and_return(true) }

      it "marks the missing instance terminated but leaves the still-present one alone" do
        present = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-present")
        deleted = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-deleted")

        allow(adapter).to receive(:list_instances).and_return(
          success: true,
          instances: [
            { cloud_instance_id: "i-present", status: "running",
              private_ip_address: present.private_ip_address, public_ip_address: present.public_ip_address }
          ],
          page_count: 1, truncated: false
        )

        result = described_class.new.sync_region_instances(region: region, account: account)

        expect(result.success?).to be true
        expect(deleted.reload.status).to eq("terminated")
        expect(present.reload.status).to eq("running")
      end

      it "does not terminate an already-terminated instance again" do
        instance = create(:system_node_instance, provider_region: region, cloud_instance_id: "i-gone", status: "terminated")

        allow(adapter).to receive(:list_instances).and_return(
          success: true, instances: [], page_count: 1, truncated: false
        )

        expect { described_class.new.sync_region_instances(region: region, account: account) }
          .not_to change { instance.reload.updated_at }
      end

      it "does not terminate when the listing was truncated (can't distinguish deletion from an unseen page)" do
        instance = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-1")
        allow(connection).to receive(:provider_id).and_return("conn-1")

        allow(adapter).to receive(:list_instances).and_return(
          success: true, instances: [], page_count: 1, truncated: true
        )

        described_class.new.sync_region_instances(region: region, account: account)

        expect(instance.reload.status).to eq("running")
      end
    end
  end
end
