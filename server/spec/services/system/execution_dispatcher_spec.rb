# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::ExecutionDispatcher do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node) }

  describe '.run' do
    context 'when the command is unsupported' do
      let(:operation) do
        # Create with a known-good command, then write the unknown one straight
        # to the column and reload. update_column bypasses validation AND leaves
        # the attribute clean, which is exactly the production shape this arm
        # exists for: a row persisted before COMMANDS was narrowed, carrying a
        # command the dispatcher can no longer route.
        #
        # It has to be done this way now. `write_attribute` marks command DIRTY,
        # and System::Task validates command on CHANGE — so the dispatcher's own
        # failure path could not save the row, and the example failed for a
        # reason that cannot occur in production.
        op = create(:system_task, account: account, operable: node, command: 'sync_modules')
        op.update_column(:command, 'definitely_not_a_real_command')
        op.reload
      end

      it 'fails the operation and returns an unprocessable_entity outcome' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be true
        expect(outcome.status_code).to eq(:unprocessable_content)
        expect(outcome.result.success?).to be false
        expect(operation.reload.status).to eq('failed')
        expect(operation.error_message).to include('Unsupported command')
      end
    end

    context 'when the command is agent-delegated (node-executed)' do
      let(:operation) do
        create(:system_task, account: account, operable: instance, command: 'upgrade_boot_image')
      end

      it 'leaves the task pending for the agent — never claims or fails it' do
        outcome = described_class.run(operation)

        expect(outcome.claimed).to be false
        expect(outcome.status_code).to eq(:accepted)
        expect(outcome.result.success?).to be true
        expect(outcome.result.to_h.dig(:data, :delegated_to_agent)).to be true
        # Critical: the task must stay pending so the node agent's poll picks it
        # up. The dispatcher must NOT transition it to running/failed.
        expect(operation.reload.status).to eq('pending')
        expect(operation.error_message).to be_blank
      end

      it 'treats every agent handler command (storage.*, a2a_call) the same' do
        %w[a2a_call storage.chown storage.mount].each do |cmd|
          op = create(:system_task, account: account, operable: instance, command: 'sync_modules')
          op.send(:write_attribute, :command, cmd)
          outcome = described_class.run(op)
          expect(outcome.status_code).to eq(:accepted), "expected #{cmd} to be agent-delegated"
          expect(op.reload.status).to eq('pending')
        end
      end
    end

    context 'when the operation cannot be claimed (already running)' do
      let(:operation) do
        op = create(:system_task, :running, account: account, operable: instance, command: 'sync_modules')
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
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'sync_modules') }

      before do
        allow(System::Runtime::SyncModules).to receive(:call).and_raise(StandardError, 'boom')
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
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'sync_modules') }

      before do
        allow(System::Runtime::SyncModules).to receive(:call) do
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
      let(:operation) { create(:system_task, account: account, operable: instance, command: 'sync_modules') }

      before do
        allow(System::Runtime::SyncModules).to receive(:call) do
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

    # Dispatch-spine decision step 3 (knowledge 01a031f2). These thirteen verbs
    # had never executed once in the platform's history: 476 System::Task rows
    # have ever existed, across exactly six commands, and none of them is here.
    # The provider plane they nominally owned runs through
    # MCP -> ProvisioningService / InstanceControlService with no Task at all.
    #
    # Pinned as ABSENT rather than simply deleted, because "we removed it" is
    # not a property any test holds — someone restoring a verb "for symmetry"
    # would reintroduce an unreachable branch that LOOKS reachable, which is the
    # exact shape that produced the dispatch-spine investigation. Re-adding one
    # must fail here and be argued for.
    RETIRED_VERBS = %w[
      provision deprovision
      associate_public_ip disassociate_public_ip
      attach_volume detach_volume
      build_module commit_module
      sync
    ].freeze

    # start/stop/reboot/terminate were in the list above and were RESTORED.
    # A lifetime row count of zero proves a verb is UNUSED; deleting it needs
    # UNREACHABLE, and those are different claims. NodeInstanceGating
    # #control_or_error passes the command as a VARIABLE
    # (create_instance_operation(event.to_s)), so no literal grep could see the
    # producer, and for a cloud provider the registry IS the execution path.
    # Pinned so the mistake cannot be repeated by a future tidy-up.
    HAS_LIVE_PRODUCER = %w[start stop reboot terminate].freeze

    it 'no longer registers any of the retired zero-caller provider verbs' do
      expect(described_class::COMMAND_REGISTRY.keys & RETIRED_VERBS).to be_empty
    end

    it 'rejects a retired verb at dispatch rather than silently accepting it' do
      RETIRED_VERBS.each do |verb|
        expect(described_class::COMMAND_REGISTRY[verb]).to be_nil
        expect(described_class.agent_delegated?(verb, {})).to be(false),
          "#{verb} is neither dispatchable nor agent-delegated, so it must be unroutable"
      end
    end

    it 'keeps every verb that still has a live producer' do
      HAS_LIVE_PRODUCER.each do |verb|
        expect(described_class::COMMAND_REGISTRY[verb]).to be_present,
          "#{verb} is created by NodeInstanceGating#control_or_error and, on a " \
          "cloud provider, dispatched through this registry — unregistering it " \
          "breaks instance control for every non-local provider"
      end
    end

    it 'registers exactly the commands the server dispatches' do
      expect(described_class::COMMAND_REGISTRY.keys).to contain_exactly(
        'start', 'stop', 'reboot', 'terminate', 'restart',
        'sync_modules', 'apply_config', 'ssh_command'
      )
    end
  end

  # A `restart` task means two entirely different things depending on whether
  # it names a unit:
  #
  #   options["unit"] absent  -> instance-scoped. COMMAND_REGISTRY routes it to
  #     Runtime::ControlInstance, whose ACTION_FOR_COMMAND maps "restart" to
  #     the "reboot" action — it reboots the WHOLE VM via the provider adapter.
  #   options["unit"] present -> unit-scoped. Only the agent can do this
  #     (tasks/handlers/lifecycle.go LifecycleHandler -> systemctl restart).
  #
  # System::Task's after_commit enqueues server-side execution on create, so
  # without this split a unit restart would ALSO reboot the VM.
  describe '.unit_scoped_restart?' do
    it 'treats a restart carrying options["unit"] as agent-delegated' do
      expect(described_class.agent_delegated?('restart', { 'unit' => 'powernode-abc-rails.service' })).to be true
    end

    it 'leaves a bare restart on the provider path (instance reboot)' do
      expect(described_class.agent_delegated?('restart', {})).to be false
      expect(described_class.agent_delegated?('restart', nil)).to be false
      expect(described_class.agent_delegated?('restart')).to be false
    end

    it 'does not extend the split to other lifecycle verbs' do
      expect(described_class.agent_delegated?('reboot', { 'unit' => 'x.service' })).to be false
      expect(described_class.agent_delegated?('terminate', { 'unit' => 'x.service' })).to be false
    end
  end

  describe '.run with a unit-scoped restart' do
    let(:operation) do
      create(:system_task, account: account, operable: instance, command: 'restart',
                           options: { 'unit' => "powernode-#{SecureRandom.uuid}-rails.service" })
    end

    it 'leaves the task pending for the agent instead of rebooting the instance' do
      expect(System::InstanceControlService).not_to receive(:execute)

      outcome = described_class.run(operation)

      expect(outcome.claimed).to be false
      expect(outcome.status_code).to eq(:accepted)
      expect(operation.reload.status).to eq('pending')
    end
  end
end
