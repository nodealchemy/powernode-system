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

    # F4-09 — happy + provider-error unit coverage (the F4-01 class of
    # always-broken path shipped precisely because none existed).
    it "creates the row, provisions via the adapter, and stores the cloud volume id" do
      allow(adapter).to receive(:supports?).with(:volumes).and_return(true)
      allow(adapter).to receive(:create_volume)
        .with(hash_including(size_gb: 10))
        .and_return({ success: true, volume_id: "vol-77" })

      result = described_class.new.provision(account: account, region: region,
                                             volume_type: volume_type, size_gb: 10,
                                             options: { name: "data-1" })

      expect(result.success?).to be true
      volume = result.data[:volume]
      expect(volume.external_id).to eq("vol-77")
      expect(volume.status).to eq("available")
      expect(volume.name).to eq("data-1")
    end

    it "marks the row error (not stranded in creating) when the provider errors" do
      allow(adapter).to receive(:supports?).with(:volumes).and_return(true)
      allow(adapter).to receive(:create_volume)
        .and_return({ success: false, error: "quota exceeded" })

      result = described_class.new.provision(account: account, region: region,
                                             volume_type: volume_type, size_gb: 10)

      expect(result.success?).to be false
      expect(result.error).to eq("quota exceeded")
      expect(result.data[:volume].reload.status).to eq("error")
    end
  end

  # F4-09 — attach/detach/delete had zero unit coverage; the only volume spec
  # was an integration file that mutated models directly and never invoked
  # this service.
  describe "attach / detach / delete (F4-09)" do
    let(:platform) { create(:system_node_platform, account: account) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let(:instance) do
      create(:system_node_instance, :running, node: node, cloud_instance_id: "vm-1")
    end
    let(:volume) do
      create(:system_provider_volume, account: account, provider_region: region,
             volume_type: volume_type, status: "available",
             external_id: "vol-1")
    end

    before do
      allow(System::Providers::Registry).to receive(:for_volume)
        .with(volume).and_return(adapter)
    end

    describe "#attach" do
      it "attaches via the adapter and transitions the volume to in-use" do
        allow(adapter).to receive(:attach_volume)
          .with("vol-1", "vm-1", device: anything)
          .and_return({ success: true, device: "/dev/vdb" })

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be true
        expect(result.data[:device]).to eq("/dev/vdb")
        volume.reload
        expect(volume.status).to eq("in-use")
        expect(volume.node_instance_id).to eq(instance.id)
      end

      it "refuses an already-attached volume before touching the provider" do
        volume.update!(node_instance: instance, status: "in-use")
        allow(adapter).to receive(:attach_volume)

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be false
        expect(result.error).to match(/already attached/i)
        expect(adapter).not_to have_received(:attach_volume)
      end

      it "propagates a provider attach failure without mutating the volume" do
        allow(adapter).to receive(:attach_volume)
          .and_return({ success: false, error: "device busy" })

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be false
        expect(result.error).to eq("device busy")
        expect(volume.reload.status).to eq("available")
      end
    end

    describe "#detach" do
      before { volume.update!(node_instance: instance, status: "in-use", device_name: "/dev/vdb") }

      it "detaches via the adapter and returns the volume to available" do
        allow(adapter).to receive(:detach_volume)
          .with("vol-1", force: false).and_return({ success: true })

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be true
        volume.reload
        expect(volume.status).to eq("available")
        expect(volume.node_instance_id).to be_nil
      end

      it "returns ok without a provider call when the volume is not attached" do
        volume.update!(node_instance: nil, status: "available")
        allow(adapter).to receive(:detach_volume)

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be true
        expect(adapter).not_to have_received(:detach_volume)
      end

      it "propagates a provider detach failure and stays attached" do
        allow(adapter).to receive(:detach_volume)
          .and_return({ success: false, error: "volume in use" })

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be false
        expect(volume.reload.status).to eq("in-use")
      end
    end

    describe "#delete" do
      it "deletes via the adapter and destroys the row" do
        allow(adapter).to receive(:delete_volume)
          .with("vol-1").and_return({ success: true })

        result = described_class.new.delete(volume: volume)

        expect(result.success?).to be true
        expect(System::ProviderVolume.find_by(id: volume.id)).to be_nil
      end

      it "refuses to delete an attached volume" do
        volume.update!(node_instance: instance, status: "in-use")
        allow(adapter).to receive(:delete_volume)

        result = described_class.new.delete(volume: volume)

        expect(result.success?).to be false
        expect(result.error).to match(/attached/i)
        expect(adapter).not_to have_received(:delete_volume)
        expect(System::ProviderVolume.find_by(id: volume.id)).to be_present
      end

      it "destroys an unprovisioned row (no cloud volume) without a provider call" do
        local_only = create(:system_provider_volume, account: account, provider_region: region,
                            volume_type: volume_type, status: "available")
        allow(adapter).to receive(:delete_volume)

        result = described_class.new.delete(volume: local_only)

        expect(result.success?).to be true
        expect(System::ProviderVolume.find_by(id: local_only.id)).to be_nil
        expect(adapter).not_to have_received(:delete_volume)
      end

      it "keeps the row when the provider delete fails" do
        allow(adapter).to receive(:delete_volume)
          .and_return({ success: false, error: "snapshot in progress" })

        result = described_class.new.delete(volume: volume)

        expect(result.success?).to be false
        expect(System::ProviderVolume.find_by(id: volume.id)).to be_present
      end
    end
  end
end
