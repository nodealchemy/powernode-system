# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::DetachVolume do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:volume) { create(:system_provider_volume) }

  let(:operation) do
    create(:system_task,
      account: account,
      operable: volume,
      command: 'detach_volume',
      status: 'running',
      progress: 0
    )
  end

  describe '.call' do
    context 'when operable is not a ProviderVolume' do
      let(:bad_op) do
        create(:system_task, account: account, operable: node, command: 'detach_volume')
      end

      it 'returns an error result' do
        result = described_class.call(operation: bad_op)
        expect(result.success?).to be false
        expect(result.error).to match(/must be System::ProviderVolume/)
      end
    end

    context 'when the service succeeds' do
      before do
        allow(System::VolumeManagementService).to receive(:detach).and_return(
          System::Runtime::Result.ok
        )
      end

      it 'returns ok' do
        expect(described_class.call(operation: operation).success?).to be true
      end

      it 'forwards force: false by default' do
        described_class.call(operation: operation)

        expect(System::VolumeManagementService).to have_received(:detach).with(
          volume: volume,
          force: false
        )
      end
    end

    context 'when force: true is set in options' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: volume,
          command: 'detach_volume',
          status: 'running',
          options: { 'force' => true }
        )
      end

      before do
        allow(System::VolumeManagementService).to receive(:detach).and_return(System::Runtime::Result.ok)
      end

      it 'forwards force: true to the service' do
        described_class.call(operation: operation)

        expect(System::VolumeManagementService).to have_received(:detach).with(
          volume: volume,
          force: true
        )
      end
    end

    context 'when the service fails' do
      before do
        allow(System::VolumeManagementService).to receive(:detach).and_return(
          System::Runtime::Result.err(error: 'volume in use')
        )
      end

      it 'returns an error result with the service message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to eq('volume in use')
      end
    end

    context 'when the service raises' do
      before do
        allow(System::VolumeManagementService).to receive(:detach).and_raise(StandardError, 'boom')
      end

      it 'rescues and returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to include('boom')
      end
    end
  end
end
