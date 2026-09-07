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

    # `terminate` LEFT this loop in campaign 01a0790b increment 2 — the command
    # is gone from System::Task::COMMANDS, so create(...) would now raise
    # RecordInvalid. Destroying an instance is System::Executors::TerminateInstance's
    # job; the agent answers a terminate Task with `systemctl reboot`.
    %w[start stop restart reboot].each do |command|
      context "when command is '#{command}'" do
        let(:operation) do
          create(:system_task,
            account: account,
            operable: instance,
            command: command,
            # A restart reaches this class ONLY as an undeclared row now.
            # Increment 2 narrowed System::Task::RESTART_SCOPES to %w[unit], and
            # the model separately refuses a restart that declares no scope at
            # all — so neither {"scope"=>"instance"} nor {} can be CREATED
            # today. The row is therefore created valid and then stripped with
            # update_column below, reaching the shape that WAS creatable before
            # the declaration validation existed (System::Task's own note at the
            # validation says so). Whether any such row is still in flight on
            # this fleet is NOT claimed here and is not what the fixture rests
            # on — the point is only that ExecutionDispatcher.restart_scope maps
            # {} to "instance", which is the branch this class serves.
            #
            # ROUTING IS NOT EXERCISED BY THIS FILE. ControlInstance maps by
            # command alone and reads options only for `force`, so the pre-strip
            # scope/unit cannot leak into any assertion below. That {} routes
            # here rather than to the agent is pinned in
            # spec/services/system/execution_dispatcher_spec.rb.
            options: command == 'restart' ? { 'scope' => 'unit', 'unit' => 'x.service' } : {},
            status: 'running',
            progress: 0
          ).tap do |t|
            # See the options comment above: become the legacy undeclared row.
            t.update_column(:options, {}) if command == 'restart'
          end
        end

        let(:expected_action) do
          {
            'start' => 'start',
            'stop' => 'stop',
            'restart' => 'reboot',
            'reboot' => 'reboot'
          }.fetch(command)
        end

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

  # Guards the two ways ACTION_FOR_COMMAND can silently drift from its downstream
  # contract. Neither is caught by the '.call' examples above, which stub
  # InstanceControlService.execute — so a mapped action InstanceControlService
  # itself rejects (e.g. "restart") never surfaces there.
  describe 'ACTION_FOR_COMMAND contract' do
    it 'maps every command to an action InstanceControlService#validate_action! accepts' do
      service = System::InstanceControlService.new

      described_class::ACTION_FOR_COMMAND.each do |command, action|
        expect { service.send(:validate_action!, action) }
          .not_to raise_error, "command '#{command}' maps to action '#{action}', which InstanceControlService rejects"
      end
    end

    it 'has an entry for every command ExecutionDispatcher routes to ControlInstance' do
      dispatched_commands = System::ExecutionDispatcher::COMMAND_REGISTRY
        .select { |_, service_class| service_class == described_class }
        .keys

      expect(dispatched_commands - described_class::ACTION_FOR_COMMAND.keys).to be_empty
    end
  end
end
