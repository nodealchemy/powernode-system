# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::ControlInstance do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  describe '.call' do
    context 'when operable is not a NodeInstance' do
      let(:operation) { create(:system_task, account: account, operable: node, command: 'start') }

      it 'returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to match(/must be System::NodeInstance/)
      end
    end

    context 'when the command is not a known control command' do
      let(:operation) do
        op = create(:system_task, account: account, operable: instance, command: 'start')
        op.send(:write_attribute, :command, 'spelunk')
        op
      end

      it 'returns an error result' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to match(/Unsupported control command/)
      end
    end

    %w[start stop restart reboot terminate].each do |command|
      context "when command is '#{command}'" do
        let(:operation) do
          create(:system_task,
            account: account,
            operable: instance,
            command: command,
            status: 'running',
            progress: 0
          )
        end

        let(:expected_action) { command == 'reboot' ? 'restart' : command }

        before do
          allow(System::InstanceControlService).to receive(:execute).and_return(
            System::Runtime::Result.ok(data: { status: 'running' })
          )
        end

        it 'delegates to InstanceControlService with the mapped action' do
          described_class.call(operation: operation)

          expect(System::InstanceControlService).to have_received(:execute).with(
            instance: instance,
            action: expected_action,
            operation_id: operation.id,
            force: false
          )
        end

        it 'returns an ok result containing the service data' do
          result = described_class.call(operation: operation)

          expect(result.success?).to be true
          expect(result.data).to eq(status: 'running')
        end
      end
    end

    context 'when the service returns failure' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: instance,
          command: 'start',
          status: 'running',
          progress: 0
        )
      end

      before do
        allow(System::InstanceControlService).to receive(:execute).and_return(
          System::Runtime::Result.err(error: 'cloud refused')
        )
      end

      it 'returns an error result with the service message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to eq('cloud refused')
      end
    end

    context 'when the service raises' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: instance,
          command: 'start',
          status: 'running',
          progress: 0
        )
      end

      before do
        allow(System::InstanceControlService).to receive(:execute).and_raise(StandardError, 'boom')
      end

      it 'rescues and returns an error result with class+message' do
        result = described_class.call(operation: operation)
        expect(result.success?).to be false
        expect(result.error).to include('boom')
        expect(result.data[:exception]).to eq('StandardError')
      end
    end

    context 'when operation has force: true in options' do
      let(:operation) do
        create(:system_task,
          account: account,
          operable: instance,
          command: 'stop',
          status: 'running',
          progress: 0,
          options: { 'force' => true }
        )
      end

      before do
        allow(System::InstanceControlService).to receive(:execute).and_return(
          System::Runtime::Result.ok
        )
      end

      it 'forwards force: true to the service' do
        described_class.call(operation: operation)

        expect(System::InstanceControlService).to have_received(:execute).with(
          hash_including(force: true)
        )
      end
    end
  end
end
