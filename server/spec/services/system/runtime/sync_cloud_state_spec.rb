# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::SyncCloudState do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:node_instance) { create(:system_node_instance, :running, node: node) }
  let(:region) { create(:system_provider_region) }

  describe '.call' do
    context 'when operable is a NodeInstance' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: node_instance,
          command: 'sync',
          status: 'running'
        )
      end

      before do
        allow(System::CloudSyncService).to receive(:sync_instance_state).and_return(
          System::Runtime::Result.ok(data: { status_changed: false })
        )
      end

      it 'delegates to CloudSyncService.sync_instance_state' do
        result = described_class.call(operation: operation)

        expect(System::CloudSyncService).to have_received(:sync_instance_state).with(instance: node_instance)
        expect(result.success?).to be true
      end
    end

    context 'when operable is a Node' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: node,
          command: 'sync',
          status: 'running'
        )
      end

      before do
        allow(System::CloudSyncService).to receive(:sync_node_instances).and_return(
          System::Runtime::Result.ok(data: { instances_synced: 3 })
        )
      end

      it 'delegates to CloudSyncService.sync_node_instances' do
        described_class.call(operation: operation)

        expect(System::CloudSyncService).to have_received(:sync_node_instances).with(node: node)
      end
    end

    context 'when operable is a ProviderRegion' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: region,
          command: 'sync',
          status: 'running'
        )
      end

      before do
        allow(System::CloudSyncService).to receive(:sync_region_instances).and_return(
          System::Runtime::Result.ok
        )
      end

      it 'delegates to CloudSyncService.sync_region_instances with the operation account' do
        described_class.call(operation: operation)

        expect(System::CloudSyncService).to have_received(:sync_region_instances).with(
          region: region,
          account: account
        )
      end
    end

    context 'when operable is an unsupported type' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: create(:system_provider_volume),
          command: 'sync',
          status: 'running'
        )
      end

      it 'returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to match(/Cannot sync operable of type/)
      end
    end

    context 'when the service returns failure' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: node_instance,
          command: 'sync',
          status: 'running'
        )
      end

      before do
        allow(System::CloudSyncService).to receive(:sync_instance_state).and_return(
          System::Runtime::Result.err(error: 'cloud unreachable')
        )
      end

      it 'returns an error result with the service message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to eq('cloud unreachable')
      end
    end

    context 'when the service raises' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: node_instance,
          command: 'sync',
          status: 'running'
        )
      end

      before do
        allow(System::CloudSyncService).to receive(:sync_instance_state).and_raise(StandardError, 'boom')
      end

      it 'rescues and returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to include('boom')
      end
    end
  end
end
