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
  end
end
