# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::AttachVolume do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:node_instance) { create(:system_node_instance, :running, node: node) }
  let(:volume) { create(:system_provider_volume) }

  let(:operation) do
    create(:system_task,
      account: account,
      operable: volume,
      command: 'attach_volume',
      status: 'running',
      progress: 0,
      options: { 'instance_id' => node_instance.id, 'device' => '/dev/xvdf' }
    )
  end

  describe '.call' do
    context 'when operable is not a ProviderVolume' do
      let(:bad_op) do
        create(:system_task, account: account, operable: node, command: 'attach_volume')
      end

      it 'returns an error result' do
        result = described_class.call(operation: bad_op)
        expect(result.success?).to be false
        expect(result.error).to match(/must be System::ProviderVolume/)
      end
    end

    context 'when instance_id is missing from options' do
      let(:no_instance_op) do
        create(:system_task, account: account, operable: volume, command: 'attach_volume', options: {})
      end

      it 'returns an error result' do
        result = described_class.call(operation: no_instance_op)
        expect(result.success?).to be false
        expect(result.error).to match(/instance_id/)
      end
    end

    context 'when the referenced NodeInstance does not exist' do
      let(:bad_id_op) do
        create(:system_task,
          account: account,
          operable: volume,
          command: 'attach_volume',
          options: { 'instance_id' => SecureRandom.uuid }
        )
      end

      it 'returns an error result' do
        result = described_class.call(operation: bad_id_op)
        expect(result.success?).to be false
        expect(result.error).to match(/not found/)
      end
    end

    context 'when VolumeManagementService.attach succeeds' do
      before do
        allow(System::VolumeManagementService).to receive(:attach).and_return(
          System::Runtime::Result.ok(data: { device: '/dev/xvdf' })
        )
      end

      it 'returns ok with the service data' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be true
        expect(result.data[:device]).to eq('/dev/xvdf')
      end

      it 'forwards device hint to the service' do
        described_class.call(operation: operation)

        expect(System::VolumeManagementService).to have_received(:attach).with(
          volume: volume,
          instance: node_instance,
          device: '/dev/xvdf'
        )
      end
    end

    context 'when VolumeManagementService.attach fails' do
      before do
        allow(System::VolumeManagementService).to receive(:attach).and_return(
          System::Runtime::Result.err(error: 'volume already attached')
        )
      end

      it 'returns an error result with the service message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to eq('volume already attached')
      end
    end

    context 'when the service raises' do
      before do
        allow(System::VolumeManagementService).to receive(:attach).and_raise(StandardError, 'boom')
      end

      it 'rescues and returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to include('boom')
      end
    end
  end
end
