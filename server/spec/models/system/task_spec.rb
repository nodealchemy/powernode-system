# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Task, type: :model do
  let(:account) { create(:account) }
  let(:node) { create(:system_node) }

  describe 'constants' do
    it 'defines valid statuses' do
      expect(described_class::STATUSES).to eq(%w[pending scheduled running complete failed aborted cancelled])
    end

    # COMMANDS is now a VALIDATION and is exactly the set the platform can
    # execute. Asserting equality with the two dispatcher sets — rather than
    # listing strings here — is what stops it drifting back into fiction: it
    # previously advertised volumes, snapshots, networks, backup/restore and
    # `custom` (no dispatcher, no producer) while OMITTING every storage.*
    # command and ci.package_build, which are real verbs in daily use.
    it 'is exactly what the dispatcher can route, server-side or to the agent' do
      derived = (System::ExecutionDispatcher::COMMAND_REGISTRY.keys +
                 System::ExecutionDispatcher::AGENT_DELEGATED_COMMANDS).uniq

      expect(described_class::COMMANDS).to match_array(derived)
    end

    it 'lists the agent-delegated storage verbs it used to omit' do
      expect(described_class::COMMANDS).to include(
        'storage.mount', 'storage.unmount', 'storage.chown', 'ci.package_build'
      )
    end

    it 'no longer advertises work the platform cannot do' do
      expect(described_class::COMMANDS).not_to include(
        'provision', 'deprovision', 'create_volume', 'create_snapshot',
        'create_network', 'backup', 'restore', 'custom', 'sync'
      )
    end

    describe 'the validation' do
      let(:account) { create(:account) }
      let(:node)    { create(:system_node, account: account) }

      it 'rejects a command the platform cannot execute' do
        task = build(:system_task, account: account, operable: node, command: 'not_a_real_command')

        expect(task).not_to be_valid
        expect(task.errors[:command]).to be_present
      end

      it 'accepts every listed command' do
        described_class::COMMANDS.each do |cmd|
          # `restart` is the one command that must also declare its blast
          # radius — see the RESTART_SCOPES block below.
          options = cmd == 'restart' ? { 'scope' => 'instance' } : {}
          task = build(:system_task, account: account, operable: node, command: cmd, options: options)
          expect(task).to be_valid, "#{cmd} is listed but rejected: #{task.errors.full_messages.join('; ')}"
        end
      end

      # Guarded on the CHANGE: a row written before the list narrowed must stay
      # transitionable, or its progress ticks and fail!/complete! would brick.
      it 'lets a legacy row carrying an unlisted command still transition' do
        task = create(:system_task, account: account, operable: node, command: 'sync_modules')
        task.update_column(:command, 'retired_verb_from_before_the_narrowing')

        expect(task.reload).to be_valid
        expect { task.start! }.not_to raise_error
        expect(task.reload.status).to eq('running')
      end

      # ...but it can never be RE-POINTED at an unlisted command.
      it 'refuses to change a legacy row onto another unlisted command' do
        task = create(:system_task, account: account, operable: node, command: 'sync_modules')
        task.update_column(:command, 'retired_verb_from_before_the_narrowing')

        task.command = 'another_unlisted_verb'

        expect(task).not_to be_valid
      end
    end
  end

  # A `restart` names two actuators with wildly different blast radii, and
  # until now the choice between them was INFERRED downstream from whether
  # options["unit"] happened to be set — so the destructive reading (reboot the
  # whole VM through the provider) was what an undeclared restart got. This is
  # the chokepoint every producer passes through: the gated HTTP create, the
  # worker API, the MCP tools and the in-process callers all reach save.
  describe 'restart scope declaration' do
    let(:account) { create(:account) }
    let(:node)    { create(:system_node, account: account) }

    def restart(options)
      build(:system_task, account: account, operable: node, command: 'restart', options: options)
    end

    it 'exposes the two scopes it accepts' do
      expect(described_class::RESTART_SCOPE_KEY).to eq('scope')
      expect(described_class::RESTART_SCOPES).to eq(%w[unit instance])
    end

    it 'refuses a restart that declares no scope' do
      task = restart({})

      expect(task).not_to be_valid
      expect(task.errors[:options].join).to include('scope')
    end

    # The exact shape of the old hazard: the obvious POST body for "bounce the
    # service" used to reboot the machine.
    it 'refuses a restart whose options are absent entirely' do
      task = build(:system_task, account: account, operable: node, command: 'restart', options: nil)

      expect(task).not_to be_valid
    end

    it 'refuses a scope outside the enumeration' do
      expect(restart({ 'scope' => 'service' })).not_to be_valid
      expect(restart({ 'scope' => '' })).not_to be_valid
    end

    it 'accepts a unit-scoped restart that names its unit' do
      expect(restart({ 'scope' => 'unit', 'unit' => 'powernode-abc-rails.service' })).to be_valid
    end

    it 'refuses a unit-scoped restart that names no unit' do
      task = restart({ 'scope' => 'unit' })

      expect(task).not_to be_valid
      expect(task.errors[:options].join).to include('unit')
    end

    it 'accepts an instance-scoped restart' do
      expect(restart({ 'scope' => 'instance' })).to be_valid
    end

    # Contradiction, not a harmless extra key: the VM reboots and the named
    # unit is never restarted, so the caller's stated intent is not what runs.
    it 'refuses an instance-scoped restart that also names a unit' do
      task = restart({ 'scope' => 'instance', 'unit' => 'powernode-abc-rails.service' })

      expect(task).not_to be_valid
      expect(task.errors[:options].join).to include('unit')
    end

    # Guarded on the CHANGE, same as command and operable_type: restart rows
    # minted before the declaration existed are still in flight, and making
    # them unsaveable would brick their progress ticks and status transitions.
    context 'a persisted restart row that predates the declaration' do
      let(:legacy) do
        task = create(:system_task, account: account, operable: node, command: 'sync_modules',
                                    status: 'running', progress: 10)
        task.update_columns(command: 'restart', options: { 'unit' => 'powernode-legacy-rails.service' })
        task.reload
      end

      it 'can still be updated on unrelated attributes' do
        expect { legacy.update!(progress: 60) }.not_to raise_error
        expect(legacy.reload.progress).to eq(60)
      end

      it 'can still complete' do
        expect { legacy.complete! }.not_to raise_error
        expect(legacy.reload.status).to eq('complete')
      end

      it 'still cannot have its options rewritten into an undeclared shape' do
        expect(legacy.update(options: { 'unit' => 'other.service' })).to be(false)
        expect(legacy.errors[:options]).to be_present
      end
    end
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:operable).optional }
    it { is_expected.to belong_to(:initiated_by).class_name('User').optional }
  end

  describe 'validations' do
    subject { build(:system_task, account: account) }

    it { is_expected.to validate_presence_of(:command) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:progress).only_integer.is_greater_than_or_equal_to(0).is_less_than_or_equal_to(100) }

    # IMP-973670faeba9 — operable_type is free text on an open polymorphic
    # belongs_to, so the last line of defense is the model itself: every
    # producer reaches save!, not just the gated HTTP create path.
    it 'rejects an operable_type outside the allowlist' do
      task = build(:system_task, account: account, operable: nil,
                                 operable_type: 'Account', operable_id: account.id)

      expect(task).not_to be_valid
      expect(task.errors[:operable_type]).to be_present
    end

    # Every allowlisted type must also be ANCHORABLE: resolve_scoped reads
    # account_id and passes a record through untouched when it finds none, so a
    # type listed here without one would be allowlisted and unscoped at once.
    it 'accepts every allowlisted type, and each one can be account-anchored' do
      described_class::OPERABLE_TYPES.each do |type|
        task = build(:system_task, account: account, operable: nil,
                                   operable_type: type, operable_id: account.id)
        task.valid?
        expect(task.errors[:operable_type]).to be_empty, "#{type} is listed but rejected"

        klass = type.safe_constantize
        expect(klass).to be_present, "#{type} names no model"
        expect(klass.column_names).to include('account_id'),
                                      "#{type} has no account_id — resolve_scoped cannot anchor it and passes it through"
      end
    end

    it 'still allows a task with no operable' do
      expect(build(:system_task, account: account, operable: nil)).to be_valid
    end

    # operable_type was free text for the table's lifetime, so rows predating
    # the allowlist can carry anything. Validating on every save would make
    # those rows unsaveable — a worker mid-flight could not tick progress or
    # record a failure. The guard is on the CHANGE, so an unrelated update to a
    # legacy row still goes through.
    context 'a persisted row whose type predates the allowlist' do
      let(:legacy) do
        task = create(:system_task, account: account, status: 'running', progress: 10)
        task.update_columns(operable_type: 'System::RetiredThing', operable_id: account.id)
        task.reload
      end

      it 'can still be updated on unrelated attributes' do
        expect { legacy.update!(progress: 60) }.not_to raise_error
        expect(legacy.reload.progress).to eq(60)
      end

      it 'still cannot be re-pointed at another unlisted type' do
        expect(legacy.update(operable_type: 'Account')).to be(false)
        expect(legacy.errors[:operable_type]).to be_present
      end
    end
  end

  describe 'scopes' do
    let!(:pending_op) { create(:system_task, account: account, status: 'pending') }
    let!(:scheduled_op) { create(:system_task, account: account, status: 'scheduled') }
    let!(:running_op) { create(:system_task, account: account, status: 'running') }
    let!(:complete_op) { create(:system_task, account: account, status: 'complete') }
    let!(:failed_op) { create(:system_task, account: account, status: 'failed') }
    let!(:aborted_op) { create(:system_task, account: account, status: 'aborted') }
    let!(:cancelled_op) { create(:system_task, account: account, status: 'cancelled') }

    describe 'status scopes' do
      it '.pending returns only pending operations' do
        expect(described_class.pending).to include(pending_op)
        expect(described_class.pending).not_to include(running_op)
      end

      it '.scheduled returns only scheduled operations' do
        expect(described_class.scheduled).to include(scheduled_op)
      end

      it '.running returns only running operations' do
        expect(described_class.running).to include(running_op)
      end

      it '.complete returns only complete operations' do
        expect(described_class.complete).to include(complete_op)
      end

      it '.failed returns only failed operations' do
        expect(described_class.failed).to include(failed_op)
      end
    end

    describe '.active' do
      it 'returns pending, scheduled, and running operations' do
        expect(described_class.active).to include(pending_op, scheduled_op, running_op)
        expect(described_class.active).not_to include(complete_op, failed_op, aborted_op, cancelled_op)
      end
    end

    describe '.finished' do
      it 'returns complete, failed, aborted, and cancelled operations' do
        expect(described_class.finished).to include(complete_op, failed_op, aborted_op, cancelled_op)
        expect(described_class.finished).not_to include(pending_op, scheduled_op, running_op)
      end
    end
  end

  describe 'status predicates' do
    let(:operation) { build(:system_task, account: account) }

    described_class::STATUSES.each do |status|
      describe "##{status}?" do
        it "returns true when status is #{status}" do
          operation.status = status
          expect(operation.public_send("#{status}?")).to be true
        end
      end
    end
  end

  describe 'AASM transition guards (may_*?)' do
    let(:operation) { build(:system_task, account: account) }

    describe '#may_start?' do
      it 'is true for pending operations' do
        operation.status = 'pending'
        expect(operation.may_start?).to be true
      end

      it 'is true for scheduled operations' do
        operation.status = 'scheduled'
        expect(operation.may_start?).to be true
      end

      it 'is false for running operations' do
        operation.status = 'running'
        expect(operation.may_start?).to be false
      end
    end

    describe '#may_complete?' do
      it 'is true for running operations' do
        operation.status = 'running'
        expect(operation.may_complete?).to be true
      end

      it 'is false for pending operations' do
        operation.status = 'pending'
        expect(operation.may_complete?).to be false
      end
    end

    describe '#may_fail?' do
      it 'is true for running operations' do
        operation.status = 'running'
        expect(operation.may_fail?).to be true
      end
    end

    describe '#may_abort?' do
      it 'is true for running operations' do
        operation.status = 'running'
        expect(operation.may_abort?).to be true
      end
    end

    describe '#may_cancel?' do
      it 'is true for pending operations' do
        operation.status = 'pending'
        expect(operation.may_cancel?).to be true
      end

      it 'is true for scheduled operations' do
        operation.status = 'scheduled'
        expect(operation.may_cancel?).to be true
      end

      it 'is false for running operations' do
        operation.status = 'running'
        expect(operation.may_cancel?).to be false
      end
    end
  end

  describe 'state transitions' do
    let(:operation) { create(:system_task, account: account, status: 'pending') }

    describe '#start!' do
      it 'transitions from pending to running' do
        operation.start!
        expect(operation.status).to eq('running')
        expect(operation.started_at).to be_present
        expect(operation.progress).to eq(0)
      end

      it 'raises AASM::InvalidTransition for non-pending operations' do
        operation.update!(status: 'running')
        expect { operation.start! }.to raise_error(AASM::InvalidTransition)
      end

      it 'adds a started event' do
        operation.start!
        expect(operation.events.last['type']).to eq('started')
      end
    end

    describe '#complete!' do
      before { operation.update!(status: 'running', started_at: 1.minute.ago) }

      it 'transitions from running to complete' do
        operation.complete!
        expect(operation.status).to eq('complete')
        expect(operation.completed_at).to be_present
        expect(operation.progress).to eq(100)
      end

      it 'raises AASM::InvalidTransition for non-running operations' do
        operation.update!(status: 'pending')
        expect { operation.complete! }.to raise_error(AASM::InvalidTransition)
      end
    end

    describe '#fail!' do
      before { operation.update!(status: 'running', started_at: 1.minute.ago) }

      it 'transitions from running to failed' do
        operation.fail!('Something went wrong')
        expect(operation.status).to eq('failed')
        expect(operation.error_message).to eq('Something went wrong')
        expect(operation.completed_at).to be_present
      end

      it 'adds a failed event' do
        operation.fail!('Error message')
        expect(operation.events.last['type']).to eq('failed')
        expect(operation.events.last['message']).to eq('Error message')
      end
    end

    describe '#abort!' do
      before { operation.update!(status: 'running', started_at: 1.minute.ago) }

      it 'transitions from running to aborted' do
        operation.abort!('User aborted')
        expect(operation.status).to eq('aborted')
        expect(operation.error_message).to eq('User aborted')
      end
    end

    describe '#cancel!' do
      it 'transitions from pending to cancelled' do
        operation.cancel!('No longer needed')
        expect(operation.status).to eq('cancelled')
        expect(operation.error_message).to eq('No longer needed')
      end

      it 'raises AASM::InvalidTransition for running operations' do
        operation.update!(status: 'running')
        expect { operation.cancel! }.to raise_error(AASM::InvalidTransition)
      end
    end

    describe '#update_progress!' do
      before { operation.update!(status: 'running', started_at: 1.minute.ago) }

      it 'updates progress for running operations' do
        expect(operation.update_progress!(50, 'Halfway done')).to be true
        expect(operation.progress).to eq(50)
      end

      it 'clamps progress to valid range' do
        operation.update_progress!(150)
        expect(operation.progress).to eq(100)

        operation.update_progress!(-10)
        expect(operation.progress).to eq(0)
      end

      it 'returns false for non-running operations' do
        operation.update!(status: 'pending')
        expect(operation.update_progress!(50)).to be false
      end
    end
  end

  describe 'event management' do
    let(:operation) { create(:system_task, account: account) }

    describe '#add_event' do
      it 'adds an event to the events array' do
        operation.add_event('info', 'Something happened', { key: 'value' })

        expect(operation.events.length).to eq(1)
        expect(operation.events.first['type']).to eq('info')
        expect(operation.events.first['message']).to eq('Something happened')
        expect(operation.events.first['data']).to eq({ 'key' => 'value' })
        expect(operation.events.first['timestamp']).to be_present
      end

      it 'appends to existing events' do
        operation.add_event('event1', 'First')
        operation.add_event('event2', 'Second')

        expect(operation.events.length).to eq(2)
      end
    end

    describe '#last_event' do
      it 'returns the last event' do
        operation.add_event('event1', 'First')
        operation.add_event('event2', 'Second')

        expect(operation.last_event['type']).to eq('event2')
      end

      it 'returns nil when no events' do
        expect(operation.last_event).to be_nil
      end
    end
  end

  describe 'duration methods' do
    let(:operation) { create(:system_task, account: account) }

    describe '#duration' do
      it 'returns nil when not started' do
        expect(operation.duration).to be_nil
      end

      it 'returns duration in seconds for completed operations' do
        operation.update!(started_at: 5.minutes.ago, completed_at: 1.minute.ago)
        expect(operation.duration).to be_within(1).of(240)
      end

      it 'returns duration to current time for running operations' do
        operation.update!(status: 'running', started_at: 1.minute.ago)
        expect(operation.duration).to be_within(1).of(60)
      end
    end

    describe '#duration_formatted' do
      it 'returns nil when not started' do
        expect(operation.duration_formatted).to be_nil
      end

      it 'formats duration with hours, minutes, seconds' do
        # Set explicit times for predictable duration
        start_time = Time.current - 2.hours - 30.minutes - 45.seconds
        end_time = Time.current
        operation.update!(started_at: start_time, completed_at: end_time)
        # Duration should be approximately 2h 30m 45s
        expect(operation.duration_formatted).to match(/\d+h \d+m \d+s/)
      end

      it 'formats short durations without hours' do
        operation.update!(started_at: 45.seconds.ago, completed_at: Time.current)
        expect(operation.duration_formatted).to match(/^\d+s$/)
      end
    end
  end

  describe '#active? and #finished?' do
    let(:operation) { build(:system_task, account: account) }

    it 'active? returns true for pending, scheduled, running' do
      %w[pending scheduled running].each do |status|
        operation.status = status
        expect(operation.active?).to be true
      end
    end

    it 'active? returns false for finished statuses' do
      %w[complete failed aborted cancelled].each do |status|
        operation.status = status
        expect(operation.active?).to be false
      end
    end

    it 'finished? returns true for complete, failed, aborted, cancelled' do
      %w[complete failed aborted cancelled].each do |status|
        operation.status = status
        expect(operation.finished?).to be true
      end
    end
  end

  describe 'polymorphic operable' do
    it 'can be associated with a Node' do
      operation = create(:system_task, account: account, operable: node)
      expect(operation.operable).to eq(node)
      expect(operation.operable_type).to eq('System::Node')
    end

    it 'can be associated with a NodeInstance' do
      instance = create(:system_node_instance, node: node)
      operation = create(:system_task, account: account, operable: instance)
      expect(operation.operable).to eq(instance)
      expect(operation.operable_type).to eq('System::NodeInstance')
    end
  end
end
