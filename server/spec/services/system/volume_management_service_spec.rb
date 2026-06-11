# frozen_string_literal: true

require "rails_helper"

# Audit F4-06 — provisioning a volume on a provider with no volume surface
# (local_qemu) created the ProviderVolume row first, then the adapter raised
# NotImplementedError, stranding the row in "creating". The capability gate
# must refuse BEFORE any DB row exists.
RSpec.describe System::VolumeManagementService do
  let(:account)     { create(:account) }
  let(:region)      { create(:system_provider_region) }
  let(:volume_type) { create(:system_provider_volume_type) }
  let(:connection)  { double("provider connection") }
  let(:adapter) do
    instance_double("System::Providers::BaseProvider", provider_type: "local_qemu")
  end

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region)
      .with(region, account).and_return(connection)
    allow(System::Providers::Registry).to receive(:for)
      .with(connection, region: region).and_return(adapter)
  end

  describe "#provision" do
    it "returns a structured error without creating a row when the provider lacks volume support" do
      allow(adapter).to receive(:supports?).with(:volumes).and_return(false)
      allow(adapter).to receive(:create_volume)

      result = nil
      expect {
        result = described_class.new.provision(account: account, region: region,
                                               volume_type: volume_type, size_gb: 10)
      }.not_to change(System::ProviderVolume, :count)

      expect(result.success?).to be false
      expect(result.error).to match(/does not support volume/i)
      expect(adapter).not_to have_received(:create_volume)
    end
  end
end
