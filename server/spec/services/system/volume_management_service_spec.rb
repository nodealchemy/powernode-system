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

    # IMP-7e549d7506cf (Route 2 remediation) — #provision's rescue arms used
    # to put e.message straight into Runtime::Result#error, which
    # ai/tools/system_fleet_tool.rb forwards to the model verbatim. Drives
    # the ACTUAL rescue arms with controlled exceptions carrying a sentinel.
    describe "sanitizes exceptions before they reach the caller (IMP-7e549d7506cf)" do
      it "does not forward raw UnknownProviderError text for a region with no provider" do
        sentinel = "SENTINEL_VOL_REGION_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for)
          .with(connection, region: region)
          .and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.provision(account: account, region: region,
                                               volume_type: volume_type, size_gb: 10)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      it "does not forward raw ProviderError text from the adapter" do
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:supports?).with(:volumes).and_return(true)
        allow(adapter).to receive(:create_volume)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.provision(account: account, region: region,
                                               volume_type: volume_type, size_gb: 10)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw StandardError text or the exception class name" do
        sentinel = "SENTINEL_VOL_STANDARD_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:supports?).with(:volumes).and_return(true)
        allow(adapter).to receive(:create_volume).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.provision(account: account, region: region,
                                               volume_type: volume_type, size_gb: 10)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("StandardError")
      end
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

    # IMP-7e549d7506cf (Route 2 remediation) — every one of this producer's
    # rescue arms (attach, detach, delete, check, snapshot, delete_snapshot,
    # restore_snapshot, plus the shared #resolve_adapter and
    # #record_restored_copy private helpers) used to put e.message (or, for
    # ActiveRecord::RecordInvalid, e.record.errors.full_messages) straight
    # into Runtime::Result#error. Each test here drives the ACTUAL rescue
    # arm with a controlled exception carrying a sentinel — round-2 review
    # found this comment naming only attach/detach/snapshot while the file
    # covered less than that name implied; the list above is now the full
    # set actually exercised below.
    describe "sanitizes exceptions before they reach the caller (IMP-7e549d7506cf)" do
      it "does not forward raw UnknownProviderError text (attach)" do
        sentinel = "SENTINEL_VOL_UNKNOWN_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for_volume)
          .with(volume).and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      it "does not forward raw ProviderError text (attach)" do
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:attach_volume)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw StandardError text or the exception class name (attach)" do
        sentinel = "SENTINEL_VOL_STANDARD_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:attach_volume).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.attach(volume: volume, instance: instance)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("StandardError")
      end

      it "does not forward raw ActiveRecord::RecordInvalid validation text (snapshot)" do
        sentinel = "SENTINEL_VOL_RECORDINVALID_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        invalid = System::ProviderVolumeSnapshot.new
        invalid.errors.add(:base, sentinel)
        allow(volume.account.system_provider_volume_snapshots).to receive(:create!)
          .and_raise(ActiveRecord::RecordInvalid, invalid)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.snapshot(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
      end

      it "does not forward raw UnknownProviderError text (detach)" do
        volume.update!(node_instance: instance, status: "in-use", device_name: "/dev/vdb")
        sentinel = "SENTINEL_VOL_UNKNOWN_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for_volume)
          .with(volume).and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      it "does not forward raw ProviderError text (detach)" do
        volume.update!(node_instance: instance, status: "in-use", device_name: "/dev/vdb")
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:detach_volume)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw StandardError text or the exception class name (detach)" do
        volume.update!(node_instance: instance, status: "in-use", device_name: "/dev/vdb")
        sentinel = "SENTINEL_VOL_STANDARD_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:detach_volume).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.detach(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("StandardError")
      end

      it "does not forward raw UnknownProviderError text (delete)" do
        sentinel = "SENTINEL_VOL_UNKNOWN_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for_volume)
          .with(volume).and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.delete(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      it "does not forward raw ProviderError text (delete)" do
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:delete_volume)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.delete(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw UnknownProviderError text (check)" do
        sentinel = "SENTINEL_VOL_UNKNOWN_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for_volume)
          .with(volume).and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.check(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      it "does not forward raw ProviderError text (check)" do
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:get_volume)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.check(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw ProviderError text (snapshot)" do
        sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        allow(adapter).to receive(:create_volume_snapshot)
          .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.snapshot(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("ProviderError")
      end

      it "does not forward raw StandardError text or the exception class name (snapshot)" do
        sentinel = "SENTINEL_VOL_STANDARD_#{SecureRandom.hex(8)}"
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        allow(adapter).to receive(:create_volume_snapshot).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.snapshot(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("StandardError")
      end

      it "does not forward raw UnknownProviderError text (resolve_adapter, via snapshot)" do
        sentinel = "SENTINEL_VOL_UNKNOWN_#{SecureRandom.hex(8)}"
        allow(System::Providers::Registry).to receive(:for_volume)
          .with(volume).and_raise(System::Providers::Registry::UnknownProviderError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.new.snapshot(volume: volume)

        expect(result.success?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("UnknownProviderError")
      end

      context "with a completed snapshot" do
        let(:vol_snapshot) do
          create(:system_provider_volume_snapshot, account: account, volume: volume,
                 status: "completed", external_id: "snap-1")
        end

        it "does not forward raw ProviderError text (delete_snapshot)" do
          sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:delete_volume_snapshot)
            .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
          expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

          result = described_class.new.delete_snapshot(snapshot: vol_snapshot)

          expect(result.success?).to be false
          expect(result.error).not_to include(sentinel)
          expect(result.error).not_to include("ProviderError")
        end

        it "does not forward raw ProviderError text (restore_snapshot)" do
          sentinel = "SENTINEL_VOL_PROVIDER_#{SecureRandom.hex(8)}"
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:in_place)
          allow(adapter).to receive(:restore_volume_snapshot)
            .and_raise(System::Providers::BaseProvider::ProviderError, sentinel)
          expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

          result = described_class.new.restore_snapshot(snapshot: vol_snapshot)

          expect(result.success?).to be false
          expect(result.error).not_to include(sentinel)
          expect(result.error).not_to include("ProviderError")
        end

        it "does not forward raw StandardError text or the exception class name (restore_snapshot)" do
          sentinel = "SENTINEL_VOL_STANDARD_#{SecureRandom.hex(8)}"
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:in_place)
          allow(adapter).to receive(:restore_volume_snapshot).and_raise(StandardError, sentinel)
          expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

          result = described_class.new.restore_snapshot(snapshot: vol_snapshot)

          expect(result.success?).to be false
          expect(result.error).not_to include(sentinel)
          expect(result.error).not_to include("StandardError")
        end

        it "does not forward raw ActiveRecord::RecordInvalid validation text (record_restored_copy, via restore_snapshot)" do
          sentinel = "SENTINEL_VOL_RECORDINVALID_#{SecureRandom.hex(8)}"
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
          allow(adapter).to receive(:restore_volume_snapshot)
            .and_return({ success: true, volume_id: "vol-restored-1", size_gb: 50 })
          invalid = System::ProviderVolume.new
          invalid.errors.add(:base, sentinel)
          allow(volume.account.system_provider_volumes).to receive(:create!)
            .and_raise(ActiveRecord::RecordInvalid, invalid)
          expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

          result = described_class.new.restore_snapshot(snapshot: vol_snapshot)

          expect(result.success?).to be false
          expect(result.error).not_to include(sentinel)
          # The provider-created volume id IS caller-relevant (an operator
          # needs it to reconcile the orphan by hand) and stays in the
          # message; only the raw AR validation text is sanitized away.
          expect(result.error).to include("vol-restored-1")
        end
      end
    end
  end
end
