# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::ProvisionInstance do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:region) { create(:system_provider_region) }
  let(:instance_type) { create(:system_provider_instance_type) }

  let(:operation) do
    create(:system_task,
      account: account,
      operable: node,
      command: 'provision',
      status: 'running',
      progress: 0,
      options: {
        'provider_region_id' => region.id,
        'provider_instance_type_id' => instance_type.id
      }
    )
  end

  describe '.call' do
    context 'when operable is not a Node' do
      let(:other_op) do
        create(:system_task,
          account: account,
          operable: create(:system_node_instance, node: node),
          command: 'provision'
        )
      end

      it 'returns an error result' do
        result = described_class.call(operation: other_op)
        expect(result.success?).to be false
        expect(result.error).to match(/must be System::Node/)
      end
    end

    context 'when required options are missing' do
      let(:incomplete_op) do
        create(:system_task,
          account: account,
          operable: node,
          command: 'provision',
          options: {}
        )
      end

      it 'returns an error result without calling ProvisioningService' do
        allow(System::ProvisioningService).to receive(:provision_instance)

        result = described_class.call(operation: incomplete_op)

        expect(result.success?).to be false
        expect(result.error).to match(/Missing required options/)
        expect(System::ProvisioningService).not_to have_received(:provision_instance)
      end
    end

    context 'when provisioning succeeds' do
      let(:provision_response) do
        System::Runtime::Result.ok(data: { instance: { id: 'i-new', cloud_instance_id: 'i-aws-123' } })
      end

      before do
        allow(System::ProvisioningService).to receive(:provision_instance).and_return(provision_response)
      end

      it 'returns ok with the service data sans success flag' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be true
        expect(result.data[:instance]).to eq(id: 'i-new', cloud_instance_id: 'i-aws-123')
      end

      it 'forwards options to the service, stripping the routing keys' do
        described_class.call(operation: operation)

        expect(System::ProvisioningService).to have_received(:provision_instance).with(
          node: node,
          provider_region_id: region.id,
          provider_instance_type_id: instance_type.id,
          operation_id: operation.id,
          options: {}
        )
      end
    end

    context 'when provisioning fails' do
      before do
        allow(System::ProvisioningService).to receive(:provision_instance).and_return(
          System::Runtime::Result.err(error: 'no capacity')
        )
      end

      it 'returns an error result with the service message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to eq('no capacity')
      end
    end

    context 'when ProvisioningService raises' do
      before do
        allow(System::ProvisioningService).to receive(:provision_instance).and_raise(StandardError, 'boom')
      end

      it 'rescues and returns an error result with class+message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to include('boom')
        expect(result.data[:exception]).to eq('StandardError')
      end
    end
  end
end
