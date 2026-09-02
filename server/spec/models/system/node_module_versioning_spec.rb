# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'System::NodeModule versioning', type: :model do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:node_module) { create(:system_node_module, account: account) }

  describe 'versioning associations' do
    it 'has_many versions' do
      v1 = create(:system_node_module_version, node_module: node_module, version_number: 1)
      v2 = create(:system_node_module_version, node_module: node_module, version_number: 2)

      expect(node_module.versions).to contain_exactly(v1, v2)
    end

    it 'belongs_to current_version optionally' do
      expect(node_module.current_version).to be_nil

      version = create(:system_node_module_version, node_module: node_module)
      node_module.update!(current_version: version)

      expect(node_module.reload.current_version).to eq(version)
    end
  end

  # Regression (imp 019f6d9a): promotion must advance the denormalized
  # current_version_number in lockstep with current_version_id. The old
  # id-only writes left the number at its default while the id moved — the
  # drift the sensor / fleet reconciler / UI mis-read.
  describe 'current_version_number consistency' do
    let!(:version) { create(:system_node_module_version, node_module: node_module, version_number: 7) }

    describe '#promote_to_version!' do
      it 'writes current_version_id AND current_version_number in one atomic update' do
        expect(node_module.promote_to_version!(version)).to be true

        node_module.reload
        expect(node_module.current_version_id).to eq(version.id)
        expect(node_module.current_version_number).to eq(7)
      end

      it 'is idempotent — a no-op (false) when the version is already current' do
        node_module.promote_to_version!(version)
        expect(node_module.promote_to_version!(version)).to be false
      end

      it 'returns false and writes nothing when handed nil' do
        expect(node_module.promote_to_version!(nil)).to be false
        expect(node_module.reload.current_version_id).to be_nil
      end
    end

    it 'self-heals a normal save that flips only current_version_id (before_save guard)' do
      node_module.update!(current_version_id: version.id)

      expect(node_module.reload.current_version_number).to eq(7)
    end
  end

  describe 'locking behavior' do
    describe '#locked?' do
      it 'returns false by default' do
        expect(node_module.locked?).to be false
      end

      it 'returns true when lock_spec is true' do
        node_module.update!(lock_spec: true)
        expect(node_module.locked?).to be true
      end
    end

    describe '#lock!' do
      it 'sets lock_spec to true' do
        node_module.lock!
        expect(node_module.reload.lock_spec).to be true
      end
    end

    describe '#unlock!' do
      before { node_module.update!(lock_spec: true) }

      it 'sets lock_spec to false' do
        node_module.unlock!
        expect(node_module.reload.lock_spec).to be false
      end
    end
  end

  describe 'versioning scopes' do
    describe '.locked' do
      let!(:locked_module) { create(:system_node_module, :locked, account: account) }
      let!(:unlocked_module) { create(:system_node_module, account: account) }

      it 'returns only locked modules' do
        expect(System::NodeModule.locked).to contain_exactly(locked_module)
      end
    end

    describe '.unlocked' do
      let!(:locked_module) { create(:system_node_module, :locked, account: account) }
      let!(:unlocked_module) { create(:system_node_module, account: account) }

      it 'returns only unlocked modules' do
        expect(System::NodeModule.unlocked).to include(unlocked_module)
        expect(System::NodeModule.unlocked).not_to include(locked_module)
      end
    end

    describe '.versioned' do
      let!(:versioned_module) do
        mod = create(:system_node_module, account: account)
        version = create(:system_node_module_version, node_module: mod)
        mod.update!(current_version: version)
        mod
      end
      let!(:unversioned_module) { create(:system_node_module, account: account) }

      it 'returns only modules with current_version set' do
        # Account.after_create_commit auto-bootstraps module catalog rows on
        # `account`, so `versioned` returns many modules beyond the two this
        # block creates. Verify the SCOPE behavior (versioned in / unversioned
        # out) rather than asserting exhaustive set equality.
        scoped = System::NodeModule.where(account: account).versioned
        expect(scoped).to include(versioned_module)
        expect(scoped).not_to include(unversioned_module)
      end
    end
  end

  describe 'versioning methods' do
    describe '#versioned?' do
      it 'returns false when no versions exist' do
        expect(node_module.versioned?).to be false
      end

      it 'returns true when versions exist' do
        create(:system_node_module_version, node_module: node_module)
        expect(node_module.versioned?).to be true
      end
    end

    describe '#latest_version' do
      let!(:v1) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
      let!(:v2) { create(:system_node_module_version, node_module: node_module, version_number: 2) }
      let!(:v3) { create(:system_node_module_version, node_module: node_module, version_number: 3) }

      it 'returns the version with highest version_number' do
        expect(node_module.latest_version).to eq(v3)
      end
    end

    describe '#version' do
      let!(:v1) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
      let!(:v2) { create(:system_node_module_version, node_module: node_module, version_number: 2) }

      it 'finds version by number' do
        expect(node_module.version(1)).to eq(v1)
        expect(node_module.version(2)).to eq(v2)
      end

      it 'returns nil for non-existent version' do
        expect(node_module.version(99)).to be_nil
      end
    end

    describe '#create_version!' do
      it 'creates a new version' do
        expect {
          node_module.create_version!(changelog: 'Test version')
        }.to change { node_module.versions.count }.by(1)
      end

      it 'captures current module state' do
        node_module.update!(mask: { 'key' => 'value' }, file_spec: { 'file' => 'spec' })

        version = node_module.create_version!(changelog: 'Captured state')

        expect(version.mask).to eq({ 'key' => 'value' })
        expect(version.file_spec).to eq({ 'file' => 'spec' })
      end

      it 'updates current_version reference' do
        version = node_module.create_version!(changelog: 'New version')

        expect(node_module.reload.current_version).to eq(version)
        expect(node_module.current_version_number).to eq(version.version_number)
      end

      it 'raises error when module is locked' do
        node_module.update!(lock_spec: true)

        expect {
          node_module.create_version!(changelog: 'Should fail')
        }.to raise_error(System::ModuleVersionService::LockError)
      end

      it 'records the user who created the version' do
        version = node_module.create_version!(changelog: 'User version', user: user)

        expect(version.created_by).to eq(user)
      end
    end

    describe '#rollback_to!' do
      let!(:v1) do
        node_module.update!(mask: { 'v1' => true })
        node_module.create_version!(changelog: 'Version 1')
      end
      let!(:v2) do
        node_module.update!(mask: { 'v2' => true })
        node_module.create_version!(changelog: 'Version 2')
      end

      it 'restores module state from version' do
        node_module.update!(mask: { 'v3' => true })
        node_module.rollback_to!(v1)

        expect(node_module.reload.mask).to eq({ 'v1' => true })
      end

      it 'creates a new version for the rollback' do
        expect {
          node_module.rollback_to!(v1)
        }.to change { node_module.versions.count }.by(1)
      end

      it 'raises error when module is locked' do
        node_module.update!(lock_spec: true)

        expect {
          node_module.rollback_to!(v1)
        }.to raise_error(System::ModuleVersionService::LockError)
      end

      it 'raises error for version from different module' do
        other_module = create(:system_node_module, account: account)
        other_version = create(:system_node_module_version, node_module: other_module)

        expect {
          node_module.rollback_to!(other_version)
        }.to raise_error(System::ModuleVersionService::RollbackError)
      end
    end

    describe '#rollback_to_previous!' do
      before do
        node_module.update!(mask: { 'v1' => true })
        node_module.create_version!(changelog: 'Version 1')
        node_module.update!(mask: { 'v2' => true })
        node_module.create_version!(changelog: 'Version 2')
      end

      it 'rolls back to the previous version' do
        node_module.update!(mask: { 'v3' => true })
        node_module.rollback_to_previous!

        # After rollback, mask should be from v2 (the previous current)
        expect(node_module.reload.mask['v2']).to be true
      end

      it 'raises error when no previous version exists' do
        new_module = create(:system_node_module, account: account)
        new_module.create_version!(changelog: 'First version')

        expect {
          new_module.rollback_to_previous!
        }.to raise_error(System::ModuleVersionService::RollbackError)
      end
    end

    describe '#version_history' do
      before do
        3.times do |i|
          node_module.create_version!(changelog: "Version #{i + 1}")
        end
      end

      it 'returns version history with summary information' do
        history = node_module.version_history

        expect(history.length).to eq(3)
        expect(history.first[:version_number]).to eq(3) # ordered by desc
        expect(history.first).to include(:id, :changelog, :created_at, :is_current)
      end

      it 'respects limit parameter' do
        history = node_module.version_history(limit: 2)

        expect(history.length).to eq(2)
      end
    end
  end

  describe 'data file management' do
    describe '#set_data_file' do
      it 'sets file attributes with calculated checksum' do
        content = 'test file content here'
        node_module.set_data_file(filename: 'test.tar.gz', content: content)

        expect(node_module.data_file_name).to eq('test.tar.gz')
        expect(node_module.data_file_size).to eq(content.bytesize)
        expect(node_module.data_checksum).to eq(Digest::SHA256.hexdigest(content))
      end
    end

    describe '#verify_data_file' do
      let(:content) { 'test file content' }

      before do
        node_module.set_data_file(filename: 'test.tar.gz', content: content)
      end

      it 'returns true for matching content' do
        expect(node_module.verify_data_file(content)).to be true
      end

      it 'returns false for non-matching content' do
        expect(node_module.verify_data_file('different content')).to be false
      end
    end
  end

  # IMP-9a5e40a21d70 increment 2 — SET the pointer vs MOVE it on a live fleet.
  #
  # #promote_to_version! used to be one method doing both: the mechanical
  # dual-column write, and the one piece of policy this model owns (arming
  # restart_after_update). Everything that needed only the mechanical half
  # hand-rolled its own `update!` and so opted out of the policy half too — the
  # census of six such writers is in
  # spec/lint/node_module_current_version_write_seam_spec.rb.
  #
  # These examples are the EXECUTED evidence that splitting them changed nothing
  # observable. Each pins a transition, not a call site.
  describe 'pointer write vs promotion (IMP-9a5e40a21d70)' do
    let(:v1) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
    let(:v2) { create(:system_node_module_version, node_module: node_module, version_number: 2) }

    # A module that DECLARES restart_after_update. Without a declaration
    # RestartAfterUpdate.arm! returns false before touching anything (its
    # `return false if declarations(node_module).empty?` guard), so an arming
    # assertion on an undeclared module passes no matter which branch ran — it
    # would be a vacuous oracle.
    let(:declaring) do
      create(:system_node_module, account: account, config: {
               'restart_after_update' => [
                 { 'module' => 'powernode-hub-backend', 'services' => [ 'rails' ] }
               ]
             })
    end
    let(:d1) { create(:system_node_module_version, node_module: declaring, version_number: 1) }
    let(:d2) { create(:system_node_module_version, node_module: declaring, version_number: 2) }

    describe '#set_current_version!' do
      it 'writes both columns atomically and returns true' do
        expect(node_module.set_current_version!(v1)).to be true

        node_module.reload
        expect(node_module.current_version_id).to eq(v1.id)
        expect(node_module.current_version_number).to eq(1)
      end

      it 'returns false and writes nothing for nil or an already-current version' do
        expect(node_module.set_current_version!(nil)).to be false
        expect(node_module.reload.current_version_id).to be_nil

        node_module.set_current_version!(v1)
        expect(node_module.set_current_version!(v1)).to be false
      end

      # THE POINT OF THE EXTRACTION. Same write, no policy — on a module that
      # DOES declare, so a false pass is not available.
      it 'arms nothing, even on a module that declares restart_after_update' do
        expect(::System::RestartAfterUpdate).not_to receive(:arm!)

        expect(declaring.set_current_version!(d1)).to be true
        expect(::System::RestartAfterUpdate.armed?(d1.reload)).to be false
      end

      it 'does not fire the auto_create_version callback (update_columns)' do
        # Both versions must exist BEFORE the block: they are lazy `let`s, and
        # referencing v2 inside `expect { }` would create it there and read as
        # the callback having fired. (It did, on the first run of this example.)
        v1
        v2
        node_module.set_current_version!(v1)

        expect { node_module.set_current_version!(v2) }
          .not_to change { node_module.versions.count }
      end
    end

    describe '#promote_to_version! — arming keyed to the transition' do
      # nil -> X. ARMS, and that is deliberate rather than incidental: the stamp
      # lives on the VERSION and persists, so it is what fires the restart when
      # an instance FIRST materializes a `services: []` module (the `armed?` and
      # running-digest gates in RestartAfterUpdate#fire!). Not arming here would
      # reintroduce the 2026-08-16 inert deploy for first installs. Pinned so a
      # future change to this rule has to be deliberate — flipping
      # NodeModule::ARM_ON_TRANSITIONS to %i[move] fails this example.
      it 'arms on the FIRST promotion (nil -> X)' do
        expect(declaring.current_version_id).to be_nil

        expect(declaring.promote_to_version!(d1)).to be true
        expect(::System::RestartAfterUpdate.armed?(d1.reload)).to be true
      end

      it 'arms on a live move (X -> Y)' do
        declaring.promote_to_version!(d1)

        expect(declaring.promote_to_version!(d2)).to be true
        expect(::System::RestartAfterUpdate.armed?(d2.reload)).to be true
      end

      # X -> X. The republished-tag case: no move, no write, no re-stamp.
      #
      # The oracle is that arm! is NOT CALLED. An earlier draft asserted the
      # stamp value was unchanged, which looks stronger and is weaker:
      # RestartAfterUpdate#armed_at stores Time.current.iso8601, so its
      # resolution is one second and a genuine re-arm inside the same second
      # would compare equal. Assert the call, not its timestamp.
      it 'neither writes nor re-arms when the version is already current (X -> X)' do
        declaring.promote_to_version!(d1)
        expect(::System::RestartAfterUpdate.armed?(d1.reload)).to be true
        pointer_before = declaring.reload.current_version_id

        expect(::System::RestartAfterUpdate).not_to receive(:arm!)
        expect(declaring.promote_to_version!(d1)).to be false
        expect(declaring.reload.current_version_id).to eq(pointer_before)
      end

      it 'returns false for nil without arming' do
        expect(::System::RestartAfterUpdate).not_to receive(:arm!)
        expect(declaring.promote_to_version!(nil)).to be false
      end

      # The arm is a bookkeeping stamp; a promotion must never fail on it. The
      # POINTER is the assertion — the promotion has to have LANDED, not merely
      # not raised.
      it 'still moves the pointer when arming raises' do
        allow(::System::RestartAfterUpdate)
          .to receive(:arm!).and_raise(StandardError, 'vault down')

        expect(declaring.promote_to_version!(d1)).to be true
        expect(declaring.reload.current_version_id).to eq(d1.id)
      end
    end
  end
end
