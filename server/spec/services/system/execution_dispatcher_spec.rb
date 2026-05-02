# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::ExecutionDispatcher do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node) }

  describe '.run' do
    context 'when the command is unsupported' do
      let(:operation) do
        # Build with a known-good command, then mutate the in-memory record so
        # the dispatcher resolution path sees an unknown command without
        # tripping ActiveRecord validations.
        op = create(:system_task, account: account, operable: node, command: 'sync')
        op.send(:write_attribute, :command, 'definitely_not_a_real_command')
        op
      end

      it 'fails the operation and returns an unprocessable_entity outcome' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be true
        expect(outcome.status_code).to eq(:unprocessable_entity)
        expect(outcome.result.success?).to be false
        expect(operation.reload.status).to eq('failed')
        expect(operation.error_message).to include('Unsupported command')
      end
    end

    context 'when the operation cannot be claimed (already running)' do
      let(:operation) do
        op = create(:system_task, :running, account: account, operable: instance, command: 'start')
        # Force into a state Operation#start! cannot transition out of.
        op.update!(status: 'complete')
        op
      end

      it 'returns a 409 conflict outcome without re-running the operation' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be false
        expect(outcome.status_code).to eq(:conflict)
        expect(outcome.result.success?).to be false
        expect(outcome.result.error).to include('cannot be started')
      end
    end

    context 'when the runtime service raises' do
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'start') }

      before do
        allow(System::Runtime::ControlInstance).to receive(:call).and_raise(StandardError, 'boom')
      end

      it 'fails the operation and returns 500' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be true
        expect(outcome.status_code).to eq(:internal_server_error)
        expect(outcome.result.success?).to be false
        expect(operation.reload.status).to eq('failed')
        expect(operation.error_message).to match(/Dispatcher exception/)
      end
    end

    context 'when the runtime service returns success' do
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'start') }

      before do
        allow(System::Runtime::ControlInstance).to receive(:call) do
          System::Runtime::Result.ok(data: { status: 'running' })
        end
      end

      it 'transitions the operation to complete and returns 200' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be true
        expect(outcome.status_code).to eq(:ok)
        expect(outcome.result.success?).to be true
        expect(operation.reload.status).to eq('complete')
        expect(operation.progress).to eq(100)
      end
    end

    context 'when the runtime service returns error' do
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'start') }

      before do
        allow(System::Runtime::ControlInstance).to receive(:call) do
          System::Runtime::Result.err(error: 'cloud refused')
        end
      end

      it 'transitions the operation to failed with the error message' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be true
        expect(outcome.status_code).to eq(:ok)
        expect(outcome.result.success?).to be false
        expect(operation.reload.status).to eq('failed')
        expect(operation.error_message).to eq('cloud refused')
      end
    end
  end

  describe 'COMMAND_REGISTRY' do
    it 'is frozen to prevent runtime mutation' do
      expect(described_class::COMMAND_REGISTRY).to be_frozen
    end

    it 'maps every Operation::COMMANDS entry that has a runtime to a runtime class' do
      registered = described_class::COMMAND_REGISTRY.keys.sort
      operation_commands = System::Task::COMMANDS

      # Every key in the registry must appear in the operation commands whitelist;
      # otherwise the dispatcher would accept a command the model rejects.
      expect(registered - operation_commands).to be_empty
    end

    it 'maps the IP management commands to ManagePublicIp runtime' do
      expect(described_class::COMMAND_REGISTRY['associate_public_ip']).to eq(System::Runtime::ManagePublicIp)
      expect(described_class::COMMAND_REGISTRY['disassociate_public_ip']).to eq(System::Runtime::ManagePublicIp)
    end
  end
end
