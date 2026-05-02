# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::ManagePublicIp do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) do
    # Override public_ip_address explicitly: the factory populates it from
    # Faker, which would mask the runtime's pre-/post-call IP transitions.
    create(:system_node_instance, :running,
      node: node,
      variety: 'cloud',
      public_ip_address: nil,
      config: { 'cloud_instance_id' => 'i-abc123' }
    )
  end
  let(:adapter) { instance_double(System::Providers::MockProvider) }

  before do
    allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
  end

  describe '.call (associate_public_ip)' do
    let(:operation) do
      create(:system_task,
        account: account,
        operable: instance,
        command: 'associate_public_ip',
        status: 'running',
        progress: 0
      )
    end

    context 'when allocation and association both succeed' do
      before do
        allow(adapter).to receive(:allocate_ip).and_return(
          { success: true, allocation_id: 'eipalloc-1', public_ip: '203.0.113.10' }
        )
        allow(adapter).to receive(:associate_ip).with('i-abc123', allocation_id: 'eipalloc-1').and_return(
          { success: true, public_ip: '203.0.113.10', association_id: 'eipassoc-1' }
        )
      end

      it 'persists the public IP, allocation_id, and association_id, and returns ok' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be true
        instance.reload
        expect(instance.public_ip_address).to eq('203.0.113.10')
        expect(instance.config['public_ip_allocation_id']).to eq('eipalloc-1')
        expect(instance.config['public_ip_association_id']).to eq('eipassoc-1')
      end
    end

    context 'when associate_ip fails after allocation succeeds' do
      before do
        allow(adapter).to receive(:allocate_ip).and_return(
          { success: true, allocation_id: 'eipalloc-2', public_ip: '203.0.113.20' }
        )
        allow(adapter).to receive(:associate_ip).and_return({ success: false, error: 'cloud rejected' })
        allow(adapter).to receive(:release_ip).and_return({ success: true })
      end

      it 'releases the orphaned allocation to avoid leaks' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be false
        expect(result.error).to include('cloud rejected')
        expect(adapter).to have_received(:release_ip).with('eipalloc-2')
        instance.reload
        expect(instance.public_ip_address).to be_nil
      end
    end

    context 'when the instance has no cloud_instance_id' do
      before do
        instance.update!(config: {})
        # Defensive: if the runtime DOES call allocate_ip when it shouldn't,
        # this stub will raise and fail the test loudly.
        allow(adapter).to receive(:allocate_ip).and_raise('should not be called')
      end

      it 'returns an error without calling the provider' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be false
        expect(result.error).to include('cloud_instance_id')
      end
    end

    context 'when the instance is physical (not cloud)' do
      let(:instance) { create(:system_node_instance, :physical, node: node) }

      it 'returns an error before resolving the adapter' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be false
        expect(result.error).to include('cloud instance')
      end
    end
  end

  describe '.call (disassociate_public_ip)' do
    let(:operation) do
      create(:system_task,
        account: account,
        operable: instance,
        command: 'disassociate_public_ip',
        status: 'running',
        progress: 0
      )
    end

    before do
      instance.update!(
        public_ip_address: '203.0.113.10',
        config: instance.config.merge(
          'public_ip_allocation_id' => 'eipalloc-1',
          'public_ip_association_id' => 'eipassoc-1'
        )
      )
    end

    context 'when both disassociate and release succeed' do
      before do
        allow(adapter).to receive(:disassociate_ip).with('eipassoc-1').and_return({ success: true })
        allow(adapter).to receive(:release_ip).with('eipalloc-1').and_return({ success: true })
      end

      it 'clears the IP and allocation IDs from the instance' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be true
        instance.reload
        expect(instance.public_ip_address).to be_nil
        expect(instance.config).not_to have_key('public_ip_allocation_id')
        expect(instance.config).not_to have_key('public_ip_association_id')
      end
    end

    context 'when no allocation or association is recorded' do
      before do
        instance.update!(config: { 'cloud_instance_id' => 'i-abc123' })
      end

      it 'returns an error rather than calling the provider blindly' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be false
        expect(result.error).to include('no recorded')
      end
    end

    context 'when disassociate_ip fails' do
      before do
        allow(adapter).to receive(:disassociate_ip).and_return({ success: false, error: 'unknown association' })
      end

      it 'surfaces the error and leaves the IP attached' do
        result = described_class.call(operation: operation)

        expect(result.success?).to be false
        expect(result.error).to include('unknown association')
        instance.reload
        expect(instance.public_ip_address).to eq('203.0.113.10')
      end
    end
  end

  describe '.call with an unsupported command' do
    let(:operation) do
      op = create(:system_task, account: account, operable: instance, command: 'sync', status: 'running')
      op.send(:write_attribute, :command, 'rebrand_my_cloud')
      op
    end

    it 'returns an error result' do
      result = described_class.call(operation: operation)
      expect(result.success?).to be false
      expect(result.error).to match(/Unsupported public IP command/)
    end
  end

  describe '.call with operable that is not a NodeInstance' do
    let(:operation) { create(:system_task, account: account, operable: node, command: 'associate_public_ip') }

    it 'returns an error result' do
      result = described_class.call(operation: operation)
      expect(result.success?).to be false
      expect(result.error).to match(/must be System::NodeInstance/)
    end
  end
end
