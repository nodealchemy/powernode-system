# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::NodeInstance, type: :model do
  let(:node) { create(:system_node) }

  describe 'constants' do
    it 'defines valid varieties' do
      expect(described_class::VARIETIES).to eq(%w[cloud physical dynamic])
    end

    it 'defines valid statuses' do
      expect(described_class::STATUSES).to eq(%w[pending provisioning starting running stopping stopped rebooting terminated error])
    end
  end

  describe 'associations' do
    it { is_expected.to belong_to(:node).class_name('System::Node') }
    it { is_expected.to belong_to(:provider_region).class_name('System::ProviderRegion').optional }
    it { is_expected.to belong_to(:provider_instance_type).class_name('System::ProviderInstanceType').optional }
    # dependent: :nullify, NOT :destroy. Destroying the operable used to destroy
    # its task history — running tasks vanished mid-flight with no terminal
    # transition (offer 01a03064-cc38). System::PreservesTaskHistory now stamps
    # the operable onto each task and transitions it before the pointer is
    # nulled; the BEHAVIOUR is pinned in
    # spec/models/system/preserves_task_history_spec.rb, which is what would
    # catch a regression this structural matcher cannot see.
    it { is_expected.to have_many(:tasks).class_name('System::Task').dependent(:nullify) }
    it { is_expected.to have_many(:provider_volumes).class_name('System::ProviderVolume') }
  end

  describe 'validations' do
    subject { build(:system_node_instance, node: node) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:variety) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:variety).in_array(described_class::VARIETIES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it 'validates uniqueness of name scoped to node' do
      instance = create(:system_node_instance, node: node, name: 'instance-1')
      duplicate = build(:system_node_instance, node: node, name: 'instance-1')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include('has already been taken')
    end

    it 'allows same name in different nodes' do
      other_node = create(:system_node)
      create(:system_node_instance, node: node, name: 'instance-1')
      other_instance = build(:system_node_instance, node: other_node, name: 'instance-1')

      expect(other_instance).to be_valid
    end
  end

  describe 'delegations' do
    let(:account) { node.account }
    let(:instance) { create(:system_node_instance, node: node) }

    it 'delegates account to node' do
      expect(instance.account).to eq(account)
    end

    it 'delegates account_id to node' do
      expect(instance.account_id).to eq(account.id)
    end
  end

  describe 'scopes' do
    let!(:cloud_instance) { create(:system_node_instance, node: node, variety: 'cloud') }
    let!(:physical_instance) { create(:system_node_instance, node: node, variety: 'physical') }
    let!(:dynamic_instance) { create(:system_node_instance, node: node, variety: 'dynamic') }
    let!(:pending_instance) { create(:system_node_instance, node: node, status: 'pending') }
    let!(:running_instance) { create(:system_node_instance, node: node, status: 'running') }
    let!(:stopped_instance) { create(:system_node_instance, node: node, status: 'stopped') }
    let!(:terminated_instance) { create(:system_node_instance, node: node, status: 'terminated') }
    let!(:error_instance) { create(:system_node_instance, node: node, status: 'error') }

    describe 'variety scopes' do
      it '.cloud returns only cloud instances' do
        expect(described_class.cloud).to include(cloud_instance)
        expect(described_class.cloud).not_to include(physical_instance, dynamic_instance)
      end

      it '.physical returns only physical instances' do
        expect(described_class.physical).to include(physical_instance)
        expect(described_class.physical).not_to include(cloud_instance, dynamic_instance)
      end

      it '.dynamic returns only dynamic instances' do
        expect(described_class.dynamic).to include(dynamic_instance)
        expect(described_class.dynamic).not_to include(cloud_instance, physical_instance)
      end
    end

    describe 'status scopes' do
      it '.pending returns only pending instances' do
        expect(described_class.pending).to include(pending_instance)
      end

      it '.running returns only running instances' do
        expect(described_class.running).to include(running_instance)
      end

      it '.stopped returns only stopped instances' do
        expect(described_class.stopped).to include(stopped_instance)
      end

      it '.terminated returns only terminated instances' do
        expect(described_class.terminated).to include(terminated_instance)
      end

      it '.errored returns only error instances' do
        expect(described_class.errored).to include(error_instance)
      end

      it '.active returns non-terminated and non-error instances' do
        active = described_class.active
        expect(active).to include(pending_instance, running_instance, stopped_instance)
        expect(active).not_to include(terminated_instance, error_instance)
      end
    end
  end

  describe 'status predicates' do
    let(:instance) { build(:system_node_instance, node: node) }

    described_class::STATUSES.each do |status|
      describe "##{status}?" do
        it "returns true when status is #{status}" do
          instance.status = status
          expect(instance.public_send("#{status}?")).to be true
        end

        it "returns false when status is not #{status}" do
          other_status = (described_class::STATUSES - [ status ]).first
          instance.status = other_status
          expect(instance.public_send("#{status}?")).to be false
        end
      end
    end
  end

  describe '#active?' do
    let(:instance) { build(:system_node_instance, node: node) }

    it 'returns true for running instances' do
      instance.status = 'running'
      expect(instance.active?).to be true
    end

    it 'returns true for pending instances' do
      instance.status = 'pending'
      expect(instance.active?).to be true
    end

    it 'returns false for terminated instances' do
      instance.status = 'terminated'
      expect(instance.active?).to be false
    end

    it 'returns false for error instances' do
      instance.status = 'error'
      expect(instance.active?).to be false
    end
  end

  describe 'AASM transition guards (may_*?)' do
    let(:instance) { build(:system_node_instance, node: node) }

    describe '#may_start?' do
      it 'is true for stopped instances' do
        instance.status = 'stopped'
        expect(instance.may_start?).to be true
      end

      it 'is true for error instances' do
        instance.status = 'error'
        expect(instance.may_start?).to be true
      end

      it 'is false for running instances' do
        instance.status = 'running'
        expect(instance.may_start?).to be false
      end
    end

    describe '#may_stop?' do
      it 'is true for running instances' do
        instance.status = 'running'
        expect(instance.may_stop?).to be true
      end

      it 'is true for starting instances' do
        instance.status = 'starting'
        expect(instance.may_stop?).to be true
      end

      it 'is false for stopped instances' do
        instance.status = 'stopped'
        expect(instance.may_stop?).to be false
      end
    end

    describe '#may_reboot?' do
      it 'is true for running instances' do
        instance.status = 'running'
        expect(instance.may_reboot?).to be true
      end

      it 'is false for stopped instances' do
        instance.status = 'stopped'
        expect(instance.may_reboot?).to be false
      end
    end

    describe '#may_terminate?' do
      it 'is true for stopped instances' do
        instance.status = 'stopped'
        expect(instance.may_terminate?).to be true
      end

      it 'is true for running instances' do
        instance.status = 'running'
        expect(instance.may_terminate?).to be true
      end

      it 'is true for error instances' do
        instance.status = 'error'
        expect(instance.may_terminate?).to be true
      end

      # Audit 2026-06-09 finding F4-02: terminate must be reachable from ANY
      # non-terminal state. Once the provider destroys the cloud resource the
      # DB row must always reach :terminated — previously a pending/starting
      # instance whose resource was destroyed was stranded in a non-terminal
      # status forever while the MCP tool reported terminated:true.
      it 'is true for pending instances' do
        instance.status = 'pending'
        expect(instance.may_terminate?).to be true
      end

      it 'is true for provisioning and starting instances' do
        instance.status = 'provisioning'
        expect(instance.may_terminate?).to be true
        instance.status = 'starting'
        expect(instance.may_terminate?).to be true
      end

      it 'is false only for already-terminated instances' do
        instance.status = 'terminated'
        expect(instance.may_terminate?).to be false
      end
    end

    # IMP-42cf03360656: a >30-min partition (or any transient outage that
    # trips the presumed-dead reap → status "error") must not permanently
    # strand a healthy instance. Before this fix mark_running's from-list
    # omitted :error, so may_mark_running? was false and the heartbeat
    # controller's `mark_running! if may_mark_running?` silently no-op'd —
    # the instance stayed in error forever even after heartbeats resumed.
    describe '#may_mark_running?' do
      it 'is true for error instances' do
        instance.status = 'error'
        expect(instance.may_mark_running?).to be true
      end
    end
  end

  describe 'encrypted attributes' do
    it 'has encrypted key attribute defined' do
      instance = build(:system_node_instance, node: node)
      expect(instance).to respond_to(:key)
      expect(instance).to respond_to(:key=)
    end
  end

  describe 'config accessor' do
    it 'allows storing and retrieving config data' do
      instance = create(:system_node_instance, node: node)
      instance.update!(config: { 'custom' => 'value', 'ip_info' => { 'internal' => '10.0.0.1' } })

      instance.reload
      expect(instance.config['custom']).to eq('value')
      expect(instance.config['ip_info']['internal']).to eq('10.0.0.1')
    end
  end

  # -----------------------------------------------------------------------
  # M4 audit trail — System::LifecycleAuditable decorates AASM bang methods
  # with AuditLog.log_action calls. Each transition writes one
  # `system.node_instance.<event>` row.
  # -----------------------------------------------------------------------
  describe 'lifecycle audit logging (System::LifecycleAuditable)' do
    let(:account)  { node.account }
    let(:user)     { create(:user, account: account) }

    before { Audit::Context.reset! }
    after  { Audit::Context.reset! }

    def audit_logs_for(instance, action: nil)
      scope = AuditLog.where(
        account_id: account.id,
        resource_type: 'System::NodeInstance',
        resource_id: instance.id
      )
      scope = scope.where(action: action) if action
      scope.order(:created_at)
    end

    it 'writes an audit row on operator-initiated start!' do
      instance = create(:system_node_instance, node: node, status: 'stopped')

      expect {
        Audit::Context.with(user: user, ip_address: '203.0.113.10', source: 'api') do
          instance.start!
        end
      }.to change(AuditLog, :count).by(1)

      log = audit_logs_for(instance, action: 'system.node_instance.start').last
      expect(log).to be_present
      expect(log.user_id).to eq(user.id)
      expect(log.ip_address).to eq('203.0.113.10')
      expect(log.source).to eq('api')
      expect(log.old_values['status']).to eq('stopped')
      expect(log.new_values['status']).to eq('starting')
      expect(log.metadata['node_id']).to eq(node.id)
      expect(instance.reload.status).to eq('starting')
    end

    it 'writes an audit row on stop!, reboot!, and terminate! transitions' do
      instance = create(:system_node_instance, node: node, status: 'running')

      expect { instance.stop! }.to change(AuditLog, :count).by(1)
      expect(audit_logs_for(instance, action: 'system.node_instance.stop').count).to eq(1)
      expect(audit_logs_for(instance).last.new_values['status']).to eq('stopping')

      instance.update!(status: 'running')
      expect { instance.reboot! }.to change(AuditLog, :count).by(1)
      expect(audit_logs_for(instance, action: 'system.node_instance.reboot').count).to eq(1)

      instance.update!(status: 'stopped')
      expect { instance.terminate! }.to change(AuditLog, :count).by(1)
      expect(audit_logs_for(instance, action: 'system.node_instance.terminate').count).to eq(1)
    end

    it 'writes an audit row on worker mark_provisioning! / mark_running! finalizers' do
      instance = create(:system_node_instance, node: node, status: 'pending')

      expect { instance.mark_provisioning! }.to change(AuditLog, :count).by(1)
      log = audit_logs_for(instance, action: 'system.node_instance.mark_provisioning').last
      expect(log.old_values['status']).to eq('pending')
      expect(log.new_values['status']).to eq('provisioning')

      expect { instance.mark_running! }.to change(AuditLog, :count).by(1)
      log = audit_logs_for(instance, action: 'system.node_instance.mark_running').last
      expect(log.old_values['status']).to eq('provisioning')
      expect(log.new_values['status']).to eq('running')
    end

    it 'writes an audit row on mark_errored! finalizer' do
      instance = create(:system_node_instance, node: node, status: 'starting')

      expect { instance.mark_errored! }.to change(AuditLog, :count).by(1)
      log = audit_logs_for(instance, action: 'system.node_instance.mark_errored').last
      expect(log.old_values['status']).to eq('starting')
      expect(log.new_values['status']).to eq('error')
    end

    it 'pulls correlation_id from Audit::Context when supplied' do
      instance = create(:system_node_instance, node: node, status: 'pending')

      Audit::Context.with(user: user, correlation_id: 'corr-abc-123', mission_id: 'mission-xyz') do
        instance.mark_provisioning!
      end

      log = audit_logs_for(instance).last
      expect(log.metadata['correlation_id']).to eq('corr-abc-123')
      expect(log.metadata['mission_id']).to eq('mission-xyz')
    end

    it 'still transitions when audit logging fails (failure is swallowed)' do
      instance = create(:system_node_instance, node: node, status: 'stopped')

      allow(AuditLog).to receive(:log_action).and_raise(StandardError, 'boom')
      expect(Rails.logger).to receive(:error).with(/Failed to write lifecycle audit/)

      expect { instance.start! }.not_to raise_error
      expect(instance.reload.status).to eq('starting')
    end
  end

  # ----------------------------------------------------------------------
  # Phase O2 — network_profile column + suggester
  # ----------------------------------------------------------------------
  describe 'network_profile' do
    it 'exposes the allowed values via NETWORK_PROFILES' do
      expect(described_class::NETWORK_PROFILES).to eq(%w[lightweight heavyweight])
    end

    it 'defaults to lightweight when not specified' do
      instance = create(:system_node_instance, node: node)
      expect(instance.network_profile).to eq('lightweight')
    end

    it 'persists heavyweight when set explicitly' do
      instance = create(:system_node_instance, node: node, network_profile: 'heavyweight')
      expect(instance.reload.network_profile).to eq('heavyweight')
    end

    it 'rejects unknown profile values' do
      instance = build(:system_node_instance, node: node, network_profile: 'turbo')
      expect(instance).not_to be_valid
      expect(instance.errors[:network_profile]).to be_present
    end

    it 'rejects nil profile values' do
      instance = build(:system_node_instance, node: node)
      instance.network_profile = nil
      expect(instance).not_to be_valid
      expect(instance.errors[:network_profile]).to be_present
    end

    describe '.lightweight_profile / .heavyweight_profile scopes' do
      let!(:lw) { create(:system_node_instance, node: node, name: 'lw-host') }
      let!(:hw) { create(:system_node_instance, node: node, name: 'hw-host', network_profile: 'heavyweight') }

      it '.lightweight_profile returns only lightweight rows' do
        expect(described_class.lightweight_profile).to include(lw)
        expect(described_class.lightweight_profile).not_to include(hw)
      end

      it '.heavyweight_profile returns only heavyweight rows' do
        expect(described_class.heavyweight_profile).to include(hw)
        expect(described_class.heavyweight_profile).not_to include(lw)
      end
    end
  end

  describe '#suggest_network_profile' do
    let(:account) { node.account }

    # Helper — build (don't persist) a NodeInstance with the hardware
    # signature we want, bypassing the factory's provider_instance_type
    # default so we can pin the value precisely. We use #build here
    # because suggest_network_profile is a pure function of the row's
    # in-memory state — no persistence needed.
    def hw(architecture:, memory_mb: nil, hardware_model: nil)
      pit = nil
      if memory_mb
        pit = build_stubbed(:system_provider_instance_type,
                            account: account, memory_mb: memory_mb)
      end
      cfg = {}
      cfg['hardware_model'] = hardware_model if hardware_model
      build_stubbed(:system_node_instance,
                    node: node,
                    architecture: architecture,
                    provider_instance_type: pit,
                    config: cfg)
    end

    context 'on amd64 / x86_64' do
      it 'returns heavyweight when memory >= 4GB' do
        expect(hw(architecture: 'amd64', memory_mb: 4096).suggest_network_profile)
          .to eq('heavyweight')
      end

      it 'returns heavyweight at the upper end (16GB)' do
        expect(hw(architecture: 'amd64', memory_mb: 16_384).suggest_network_profile)
          .to eq('heavyweight')
      end

      it 'returns lightweight when memory < 4GB' do
        expect(hw(architecture: 'amd64', memory_mb: 2048).suggest_network_profile)
          .to eq('lightweight')
      end

      it 'returns lightweight when memory is unknown (no provider_instance_type, no config hint)' do
        expect(hw(architecture: 'amd64').suggest_network_profile).to eq('lightweight')
      end

      it 'recognises x86_64 as a synonym for amd64' do
        expect(hw(architecture: 'x86_64', memory_mb: 8192).suggest_network_profile)
          .to eq('heavyweight')
      end
    end

    context 'on aarch64 / arm64' do
      it 'returns heavyweight for a Pi 5 regardless of memory' do
        expect(hw(architecture: 'arm64', hardware_model: 'raspberry_pi_5', memory_mb: 4096)
                 .suggest_network_profile).to eq('heavyweight')
        expect(hw(architecture: 'arm64', hardware_model: 'rpi5', memory_mb: 8192)
                 .suggest_network_profile).to eq('heavyweight')
      end

      it 'returns heavyweight for a Pi 4 with 8GB+ RAM' do
        expect(hw(architecture: 'arm64', hardware_model: 'raspberry_pi_4', memory_mb: 8192)
                 .suggest_network_profile).to eq('heavyweight')
      end

      it 'returns lightweight for a Pi 4 with 4GB RAM' do
        expect(hw(architecture: 'arm64', hardware_model: 'raspberry_pi_4', memory_mb: 4096)
                 .suggest_network_profile).to eq('lightweight')
      end

      it 'returns lightweight for a Pi 4 with no memory information' do
        expect(hw(architecture: 'arm64', hardware_model: 'raspberry_pi_4')
                 .suggest_network_profile).to eq('lightweight')
      end

      it 'returns lightweight for an unknown aarch64 board with no hardware hint' do
        expect(hw(architecture: 'arm64', memory_mb: 8192).suggest_network_profile)
          .to eq('lightweight')
      end

      it 'recognises aarch64 as a synonym for arm64' do
        expect(hw(architecture: 'aarch64', hardware_model: 'pi5').suggest_network_profile)
          .to eq('heavyweight')
      end
    end

    context 'when hardware fields are missing entirely (safe default)' do
      it 'returns lightweight when architecture is nil' do
        instance = build_stubbed(:system_node_instance, node: node, architecture: nil)
        expect(instance.suggest_network_profile).to eq('lightweight')
      end

      it 'returns lightweight on an unknown architecture' do
        # The DB CHECK constraint blocks this on save, but the suggester
        # is called against in-memory rows during provisioning so it
        # must defend against any string getting through.
        instance = hw(architecture: 'riscv64', memory_mb: 65_536)
        expect(instance.suggest_network_profile).to eq('lightweight')
      end
    end

    it 'is a pure function — does not mutate the row or persist anything' do
      instance = hw(architecture: 'amd64', memory_mb: 8192)
      original_profile = instance.network_profile

      expect { instance.suggest_network_profile }.not_to change { instance.network_profile }
      expect(instance.network_profile).to eq(original_profile)
      expect(instance).not_to be_changed
    end

    it 'reads memory from config["memory_mb"] when provider_instance_type is absent' do
      instance = build_stubbed(:system_node_instance,
                               node: node,
                               architecture: 'amd64',
                               provider_instance_type: nil,
                               config: { 'memory_mb' => 8192 })
      expect(instance.suggest_network_profile).to eq('heavyweight')
    end

    it 'returns lightweight when config["memory_mb"] is non-numeric garbage' do
      instance = build_stubbed(:system_node_instance,
                               node: node,
                               architecture: 'amd64',
                               provider_instance_type: nil,
                               config: { 'memory_mb' => 'plenty' })
      expect(instance.suggest_network_profile).to eq('lightweight')
    end
  end

  describe '#blocking_dependents + #cascade_destroy_dependents!' do
    let(:instance) { create(:system_node_instance, node: node) }

    context 'when nothing references the instance' do
      it 'returns empty hash from blocking_dependents' do
        expect(instance.blocking_dependents).to eq({})
      end

      it 'cascade_destroy_dependents! returns an empty summary' do
        expect(instance.cascade_destroy_dependents!).to eq(nullified: {}, destroyed: {})
      end
    end

    context 'with a required-FK dependent (Sdwan::HostBridge)' do
      let!(:bridge) do
        create(:sdwan_host_bridge, account: node.account, node_instance: instance)
      end

      it 'blocking_dependents reports the count under the class name' do
        expect(instance.blocking_dependents).to eq('Sdwan::HostBridge' => 1)
      end

      it 'plain .destroy fails on the FK violation' do
        expect { instance.destroy }.to raise_error(ActiveRecord::InvalidForeignKey)
      end

      it 'cascade_destroy_dependents! destroys the bridge as part of the cascade' do
        summary = instance.cascade_destroy_dependents!
        expect(summary[:destroyed]).to include('Sdwan::HostBridge' => 1)
        expect(::Sdwan::HostBridge.where(id: bridge.id)).to be_empty
      end

      it 'cascade-then-.destroy succeeds end-to-end' do
        instance.cascade_destroy_dependents!
        expect(instance.destroy).to be_truthy
      end
    end

    context 'with an optional-FK dependent (System::BootstrapToken)' do
      let!(:token) do
        # No factory exists for BootstrapToken; create directly with the
        # minimum required attrs (token_hash + intended_subject + expires_at
        # per the model's validations).
        ::System::BootstrapToken.create!(
          node: node,
          node_instance: instance,
          token_hash: SecureRandom.hex(32),
          intended_subject: 'agent:test',
          expires_at: 1.hour.from_now
        )
      end

      it 'cascade_destroy_dependents! nullifies (keeps audit) instead of destroying' do
        summary = instance.cascade_destroy_dependents!
        expect(summary[:nullified]).to include('System::BootstrapToken' => 1)
        expect(token.reload.node_instance_id).to be_nil
      end
    end
  end

  # IMP-e88b38770d13 review round 1 — system_storage_assignments.node_instance_id
  # and system_storage_credentials.node_instance_id are ON DELETE CASCADE at the
  # DB level (db/migrate/20250101000009_system_baseline.rb), and this model
  # declared NO association for either table at all before this fix. A PLAIN
  # `instance.destroy` (no force, no #cascade_destroy_dependents!) therefore let
  # Postgres cascade these rows away with ZERO ActiveRecord callbacks —
  # StorageCredential's own before_destroy deprovision hook never ran. This is
  # the gap the two new `has_many ..., dependent: :destroy` declarations close.
  describe 'storage credential deprovisioning on destroy (IMP-e88b38770d13)' do
    let(:instance) { create(:system_node_instance, node: node) }
    let(:backend_instance) { create(:system_node_instance, account: node.account) }
    let(:smb_storage) do
      create(:file_storage, :smb, :node_mountable, account: node.account,
        configuration: {
          "mount_path" => "/mnt/smb-plain-destroy",
          "server_address" => "192.168.1.223",
          "share_name" => "plain-destroy-share",
          "export_host_node_instance_id" => backend_instance.id
        })
    end
    let(:smb_assignment) do
      create(:system_storage_assignment,
        account: node.account, file_storage_id: smb_storage.id,
        node_instance: instance, mount_path: "/mnt/smb-plain-destroy")
    end

    def smb_tasks
      System::Task.where(command: "storage.smb_user.apply").order(:created_at)
    end

    def issue_smb_credential!
      smb_assignment.storage_credentials.update_all(status: "revoked")
      ::System::Storage::CredentialIssuer.new(assignment: smb_assignment).issue!
    end

    it 'a PLAIN instance.destroy (no force) deprovisions the live SMB credential' do
      credential = issue_smb_credential!
      before_ids = smb_tasks.pluck(:id)

      expect(instance.destroy).to be_truthy

      new_tasks = smb_tasks.where.not(id: before_ids)
      expect(new_tasks.count).to eq(1)
      expect(new_tasks.first.options["action"]).to eq("delete")
      expect(::System::StorageCredential.where(id: credential.id)).not_to exist
    end

    it 'the force cascade_destroy_dependents! + .destroy combo also deprovisions' do
      credential = issue_smb_credential!
      before_ids = smb_tasks.pluck(:id)

      instance.cascade_destroy_dependents!
      expect(instance.destroy).to be_truthy

      new_tasks = smb_tasks.where.not(id: before_ids)
      expect(new_tasks.count).to eq(1)
      expect(new_tasks.first.options["action"]).to eq("delete")
      expect(::System::StorageCredential.where(id: credential.id)).not_to exist
    end
  end

  # Campaign 019f6084 §2.4.3 — TemplateClosureDriftSensor's pivot-vs-cloud_init
  # remediation split depends on this predicate reading the boot mode the
  # instance was ACTUALLY provisioned with. IMP-831a81e02d25: that is the
  # value ProvisioningService resolves and now stamps into the instance's own
  # config at spawn; the template lookup survives only as a fallback for rows
  # provisioned before that stamp existed.
  describe '#pivot_boot?' do
    let(:instance) { create(:system_node_instance, node: node) }

    it 'is false when the template has no boot_mode configured (cloud_init default)' do
      expect(instance.pivot_boot?).to be false
      # Nothing declared a mode, so nothing is known: #resolved_boot_mode says
      # nil rather than naming a default it cannot observe (IMP-b2e745dbdbbb).
      # Pinned here because the scanner's own `|| "cloud_init"` would absorb a
      # regression to a named default, leaving it invisible there.
      expect(instance.resolved_boot_mode).to be_nil
    end

    it 'is false for an explicit cloud_init boot_mode' do
      node.node_template.update!(config: { 'boot_mode' => 'cloud_init' })
      expect(instance.pivot_boot?).to be false
    end

    it 'is true for a direct_kernel boot_mode' do
      node.node_template.update!(config: { 'boot_mode' => 'direct_kernel' })
      expect(instance.pivot_boot?).to be true
    end

    it 'is true for a uefi_disk boot_mode' do
      node.node_template.update!(config: { 'boot_mode' => 'uefi_disk' })
      expect(instance.pivot_boot?).to be true
    end

    it 'is false when the node has no template-resolvable config (defensive)' do
      allow(instance).to receive(:node).and_return(nil)
      expect(instance.pivot_boot?).to be false
    end

    # IMP-831a81e02d25 ORACLE. The template path alone is green against the
    # defect: what the predicate got WRONG is an instance spawned with an
    # explicit boot_mode option on a template that declares none. Only a
    # per-instance record can answer that, so this example is unpassable by
    # any template-config implementation.
    it "is true from the instance's own recorded boot_mode when the template declares none" do
      expect(node.node_template.config['boot_mode']).to be_nil
      instance.merge_config!('boot_mode' => 'direct_kernel')

      expect(instance.pivot_boot?).to be true
    end

    # The other direction of the same divergence, and the mutant-killer for a
    # "consult both, take whichever is pivot" implementation: an instance
    # spawned cloud_init on a direct_kernel template did NOT pivot-boot.
    it "prefers the instance's own recorded boot_mode over the template's" do
      node.node_template.update!(config: { 'boot_mode' => 'direct_kernel' })
      instance.merge_config!('boot_mode' => 'cloud_init')

      expect(instance.pivot_boot?).to be false
    end

    # IMP-b2e745dbdbbb — the resolution is now the public #resolved_boot_mode,
    # read by System::Compliance::RcpInvariantScanner as well, so its BLANK
    # guard is load-bearing past this predicate: an empty stamp is not an
    # answer and must fall through to the template, not be returned as "".
    # (Truthiness alone does not do that, and nothing pinned it before.)
    it 'falls back to the template when the instance recorded a BLANK boot_mode' do
      node.node_template.update!(config: { 'boot_mode' => 'uefi_disk' })
      instance.merge_config!('boot_mode' => '')

      expect(instance.resolved_boot_mode).to eq('uefi_disk')
      expect(instance.pivot_boot?).to be true
    end

    # Pre-existing rows carry no stamp and MUST keep the old answer.
    it 'falls back to the template when the instance recorded no boot_mode' do
      node.node_template.update!(config: { 'boot_mode' => 'uefi_disk' })
      expect(instance.config).not_to have_key('boot_mode')

      expect(instance.pivot_boot?).to be true
    end
  end

  # inc29 fix (improvement 019f6ecc-7e0e): a native-CI builder leased before its
  # module-forge union is mounted execs a module-forge-provided build script that
  # isn't on the union yet, and the agent dead-ends the ci.module_build task at
  # "unknown_command". mark_pool_ready! now also gates on the build-critical module
  # actually being reported composed (running_module_digests), the module-composition
  # analog of the existing #sdwan_overlay_ready? gate.
  describe '#mark_pool_ready! module-forge composition gate' do
    let(:account) { create(:account) }
    let(:node) { create(:system_node, account: account) }
    let(:pool) do
      System::InstancePool.create!(
        account: account, node_template: node.node_template,
        name: "forge-gate-pool-#{SecureRandom.hex(4)}", target_size: 1, min_size: 0, max_size: 3,
        lifecycle_class: "ephemeral", status: "active",
        provider_region: create(:system_provider_region, account: account),
        provider_instance_type: create(:system_provider_instance_type, account: account)
      )
    end
    let(:instance) do
      create(:system_node_instance, node: node,
                                    instance_pool_id: pool.id, pool_state: "warming",
                                    pool_warming_started_at: 1.minute.ago)
    end

    context 'when the node is assigned the module-forge module' do
      let(:forge) { create(:system_node_module, account: account, name: "module-forge") }

      before { create(:system_node_module_assignment, node: node, node_module: forge) }

      it 'stays warming until module-forge is reported composed in running_module_digests' do
        instance.update!(running_module_digests: { "some-other-module-id" => "sha256:aaaa" })

        expect(instance.mark_pool_ready!).to be false
        expect(instance.reload.pool_state).to eq("warming")
      end

      it 'promotes to ready once module-forge appears in running_module_digests' do
        instance.update!(running_module_digests: { forge.id.to_s => "sha256:bbbb" })

        expect(instance.mark_pool_ready!).to be true
        expect(instance.reload.pool_state).to eq("ready")
      end
    end

    context 'when the node is NOT assigned module-forge (non-builder pool)' do
      it 'promotes on the normal path — the module-composition gate is not applicable' do
        instance.update!(running_module_digests: {})

        expect(instance.mark_pool_ready!).to be true
        expect(instance.reload.pool_state).to eq("ready")
      end
    end
  end

  # IMP-39f80a13c536: #module_drift / #module_drifted? is the single definition
  # of module drift — four call sites (SystemFleetTool#drift_report,
  # ModuleDriftSensor, PlatformMaintenanceExecutor drift_check, the compliance
  # snapshot) were converged onto it. Until this block existed the owning
  # model's spec never called either method: the driver's mutation replay
  # dropped `|| drift[:mismatched].any?` from #module_drifted? and this file
  # stayed at 112 examples, 0 failures — the only detector in the tree was one
  # example in a downstream consumer's spec.
  #
  # Each limb is pinned by its own fixture so that dropping any ONE `.any?`
  # clause kills exactly one example here. The `mismatched` fixture is the
  # discriminating one: the SAME keys as the assignment with DIFFERENT values —
  # the stale-digest instance a failed rolling upgrade produces, and the case
  # the retired key-set-only copies were blind to.
  describe '#module_drift / #module_drifted?' do
    let(:account) { create(:account) }
    let(:node) { create(:system_node, account: account) }
    let(:instance) { create(:system_node_instance, node: node) }

    # An assigned module whose CURRENT version carries `want` — the digest an
    # instance of this node is supposed to be running. `want: nil` builds the
    # digestless assignment the :unverifiable examples need.
    def assign_module(want:)
      node_module = create(:system_node_module, account: account)
      version = create(:system_node_module_version, node_module: node_module, oci_digest: want)
      node_module.set_current_version!(version)
      create(:system_node_module_assignment, node: node, node_module: node_module)
      node_module
    end

    context 'when the instance reports the assigned module at a different digest (mismatched)' do
      it 'is drifted and names the module with its want/have pair' do
        node_module = assign_module(want: "sha256:want")
        instance.update!(running_module_digests: { node_module.id.to_s => "sha256:stale" })

        drift = instance.module_drift
        expect(drift[:mismatched]).to eq(node_module.id => { want: "sha256:want", have: "sha256:stale" })
        expect(drift[:missing]).to be_empty
        expect(drift[:extra]).to be_empty
        expect(instance.module_drifted?).to be true
      end
    end

    context 'when an assigned module is not reported mounted at all (missing)' do
      it 'is drifted and lists the module under :missing only' do
        node_module = assign_module(want: "sha256:want")
        instance.update!(running_module_digests: {})

        drift = instance.module_drift
        expect(drift[:missing]).to eq(node_module.id => "sha256:want")
        expect(drift[:extra]).to be_empty
        expect(drift[:mismatched]).to be_empty
        expect(instance.module_drifted?).to be true
      end
    end

    context 'when the instance reports a module the node is no longer assigned (extra)' do
      it 'is drifted and lists the module under :extra only' do
        unassigned_id = SecureRandom.uuid
        instance.update!(running_module_digests: { unassigned_id => "sha256:orphan" })

        drift = instance.module_drift
        expect(drift[:extra]).to eq(unassigned_id => "sha256:orphan")
        expect(drift[:missing]).to be_empty
        expect(drift[:mismatched]).to be_empty
        expect(instance.module_drifted?).to be true
      end
    end

    context 'when every assigned module is reported at its current digest' do
      it 'is not drifted and every limb is empty' do
        node_module = assign_module(want: "sha256:want")
        instance.update!(running_module_digests: { node_module.id.to_s => "sha256:want" })

        expect(instance.module_drift).to eq(missing: {}, extra: {}, mismatched: {}, unverifiable: {})
        expect(instance.module_drifted?).to be false
      end
    end

    # Offer 01a0c60b-ee60 — an assigned module whose served version carries
    # no oci_digest used to be dropped from the assignment, so its running
    # copy fell into :extra and DriftRemediateExecutor planned a DETACH for a
    # module the node is assigned (live: a control plane's only reverse
    # proxy). It is assigned, so it is never :extra; its digest is unknown, so
    # it is never :missing or :mismatched either. It lands in :unverifiable —
    # asserted by bucket, not by module_drifted?, because a fix that dropped
    # the module from BOTH sides would also read "not drifted".
    context 'when an assigned module has no served digest (unverifiable)' do
      let!(:digestless) { assign_module(want: nil) }

      it 'lists a running copy under :unverifiable, never :extra, and is not drifted' do
        instance.update!(running_module_digests: { digestless.id.to_s => "sha256:mounted" })

        drift = instance.module_drift
        expect(drift[:unverifiable]).to eq(digestless.id => { have: "sha256:mounted" })
        expect(drift[:extra]).to be_empty
        expect(drift[:missing]).to be_empty
        expect(drift[:mismatched]).to be_empty
        expect(instance.module_drifted?).to be false
      end

      it 'lists it under :unverifiable with no have when nothing is mounted for it' do
        instance.update!(running_module_digests: {})

        drift = instance.module_drift
        expect(drift[:unverifiable]).to eq(digestless.id => { have: nil })
        expect(drift[:missing]).to be_empty
      end

      # The inverse oracle: a fix that stopped reporting extras at all would
      # pass the examples above. An unassigned running module is still :extra
      # beside the unverifiable one, and still drifts the instance.
      it 'still reports a genuinely unassigned running module as :extra' do
        unassigned_id = SecureRandom.uuid
        instance.update!(running_module_digests: { digestless.id.to_s => "sha256:mounted",
                                                   unassigned_id => "sha256:orphan" })

        drift = instance.module_drift
        expect(drift[:extra]).to eq(unassigned_id => "sha256:orphan")
        expect(drift[:unverifiable].keys).to eq([ digestless.id ])
        expect(instance.module_drifted?).to be true
      end
    end

    # The digest compared is the one the instance's PLANE is served
    # (NodeModule#served_version_for), not current_version: a pinned plane
    # with a digested pin is measured against the pin even when current has
    # no digest, and a pinned plane with no pin serves nothing — unverifiable.
    context 'on a pinned plane' do
      let(:staging) { account.environments.find_by!(slug: "staging") }
      let(:instance) { create(:system_node_instance, node: node, environment: staging) }

      it 'measures against the pin, so a digestless current_version does not make it unverifiable' do
        node_module = assign_module(want: "sha256:pinned")
        pinned = node_module.current_version
        System::ModuleEnvironmentPin.create!(account_id: account.id, node_module: node_module, environment: staging,
                                             node_module_version: pinned, promoted_at: Time.current)
        node_module.set_current_version!(
          create(:system_node_module_version, node_module: node_module, version_number: pinned.version_number + 1,
                                              oci_digest: nil)
        )
        instance.update!(running_module_digests: { node_module.id.to_s => "sha256:pinned" })

        expect(instance.module_drift).to eq(missing: {}, extra: {}, mismatched: {}, unverifiable: {})
      end

      it 'reports a module whose PIN has no digest as :unverifiable, even when current_version has one' do
        node_module = assign_module(want: "sha256:current")
        digestless_pin = create(:system_node_module_version, node_module: node_module,
                                                             version_number: node_module.current_version.version_number + 1,
                                                             oci_digest: nil)
        System::ModuleEnvironmentPin.create!(account_id: account.id, node_module: node_module, environment: staging,
                                             node_module_version: digestless_pin, promoted_at: Time.current)
        instance.update!(running_module_digests: { node_module.id.to_s => "sha256:current" })

        drift = instance.module_drift
        expect(drift[:unverifiable]).to eq(node_module.id => { have: "sha256:current" })
        expect(drift[:extra]).to be_empty
        expect(drift[:mismatched]).to be_empty
      end

      it 'reports a module with no pin on the plane as :unverifiable, not :extra' do
        node_module = assign_module(want: "sha256:current")
        instance.update!(running_module_digests: { node_module.id.to_s => "sha256:current" })

        drift = instance.module_drift
        expect(drift[:unverifiable]).to eq(node_module.id => { have: "sha256:current" })
        expect(drift[:extra]).to be_empty
      end
    end
  end
  # IMP-fb05226e89cb — the liveness question a dispatcher must ask before
  # queueing an on-node task. An on-node task (sync_modules / apply_config) is
  # only ever executed by the agent polling pending rows, so a task created for
  # an instance with no live agent sits at pending/progress 0 until the janitor
  # cancels it 48h later.
  describe '#on_node_dispatch_refusal' do
    def instance_with(status:, heartbeat: nil)
      create(:system_node_instance, node: node, status: status, last_heartbeat_at: heartbeat)
    end

    describe 'the status arm' do
      it 'refuses a terminated instance, naming the status' do
        refusal = instance_with(status: 'terminated').on_node_dispatch_refusal

        expect(refusal).to be_present
        expect(refusal).to include('terminated')
      end

      it 'refuses an errored instance, naming the status' do
        refusal = instance_with(status: 'error').on_node_dispatch_refusal

        expect(refusal).to be_present
        expect(refusal).to include('instance is error')
      end

      # Fresh heartbeats throughout: this example is about the STATUS arm, and
      # a nil heartbeat would drag the silence arm into it for `running`.
      it 'admits every status the control plane still expects to serve' do
        described_class::LIVE_REPLICA_STATUSES.each do |status|
          expect(instance_with(status: status, heartbeat: 30.seconds.ago).on_node_dispatch_refusal)
            .to be_nil, "expected #{status} to be dispatchable"
        end
      end
    end

    describe 'the silence arm' do
      it 'refuses a running instance whose agent stopped reporting' do
        refusal = instance_with(status: 'running', heartbeat: 10.minutes.ago).on_node_dispatch_refusal

        expect(refusal).to be_present
        expect(refusal).to include('silent')
      end

      it 'admits a running instance that reported recently' do
        expect(instance_with(status: 'running', heartbeat: 30.seconds.ago).on_node_dispatch_refusal)
          .to be_nil
      end

      # Scoped to the statuses where a heartbeat is EXPECTED. A stopped
      # instance is not silent, it is stopped: the task waits for the agent,
      # which is the existing semantics and correct.
      it 'admits a stopped instance whose last heartbeat is ancient' do
        expect(instance_with(status: 'stopped', heartbeat: 2.days.ago).on_node_dispatch_refusal)
          .to be_nil
      end
    end

    # THE TRAP. `stale_heartbeat?` answers "can this telemetry be trusted" and
    # returns TRUE for nil — a row that has never reported. This predicate asks
    # a different question: "was there an agent, and did it stop talking". nil
    # means "not yet", not "dead". An instance that has never heartbeated is
    # legitimately about to enrol, and the provisioning path queues sync_modules
    # for exactly those rows, so refusing them would trade a visible stuck task
    # for an invisibly never-provisioned node.
    describe 'an instance that has never reported' do
      %w[pending provisioning starting].each do |status|
        it "admits a #{status} instance with no heartbeat at all" do
          expect(instance_with(status: status, heartbeat: nil).on_node_dispatch_refusal)
            .to be_nil, "a #{status} instance that has never reported must stay dispatchable"
        end
      end

      # The inverse, and the case a naive "nil means not yet" rule gets wrong.
      # The only legitimate route to `running` records the heartbeat BEFORE the
      # transition, so a running row that never reported was marked running from
      # PROVIDER state alone (CloudSyncService writes status with a bare
      # update! from the hypervisor's view, which cannot see whether an agent
      # enrolled). InstanceStatusSensor already counts that row as silent.
      it 'refuses a running instance whose agent has never reported' do
        refusal = instance_with(status: 'running', heartbeat: nil).on_node_dispatch_refusal

        expect(refusal).to be_present
        expect(refusal).to include('never reported')
      end
    end
  end

  # IMP-9cc83aa64bff — a terminated instance never returns, so every task still
  # queued against it is unrunnable from that moment. Nothing noticed: the row
  # sat `pending` until the worker janitor's 48h UNRUNNABLE_THRESHOLD, with the
  # stuck-backlog sensor alarming at 72h if that failed. Correct as a backstop,
  # wrong as the primary path — 48 hours of pending noise in the queue an
  # operator scans to find real problems, and a task dispatched a minute before
  # termination is indistinguishable from a genuinely stuck one.
  #
  # THE SEAM IS THE COLUMN, NOT THE AASM EVENT, and that is the whole reason
  # these examples drive both. `terminated` reaches the column two ways: the
  # mark_terminated! event, and a bare update! — System::CloudSyncService writes
  # `status: data[:status]` straight from the provider's view (that is the
  # dominant path on this fleet, since the hourly sync is what notices a VM has
  # gone), and NodeApi::StatusController#update writes any member of STATUSES an
  # agent reports. An after-event hook would miss both.
  describe "cancelling unrunnable tasks on termination (IMP-9cc83aa64bff)" do
    let(:instance) { create(:system_node_instance, node: node, status: "running") }

    # No Redis stub is needed here any more: System::Task's
    # `after_commit :enqueue_execution, on: :create` — which pushed straight to
    # the Redis instance shared across every spec lane — was deleted with the
    # server dispatch arm in campaign 01a0790b increment 3. Creating a Task now
    # touches nothing but the database.

    def task_with(status: "pending", command: "sync_modules", target: instance)
      create(:system_task, account: target.account, operable: target, command: command, status: status)
    end

    it "cancels a pending task when the finalizer confirms the termination" do
      task = task_with

      instance.mark_terminated!

      expect(task.reload.status).to eq("cancelled")
    end

    # THE HOLE AN INDEPENDENT REVIEW FOUND, and the reason this hook keys on
    # more than the column. InstanceControlService#execute stamps `terminated`
    # via #terminate! BEFORE calling the provider, and reverts to :error on any
    # provider failure — which for the terminate lane is the ONLY failure path.
    # Sweeping on that stamp empties the queue of every instance whose terminate
    # was refused by a rate limit, and this branch's own liveness gate then
    # refuses to re-dispatch to an `error` instance, so nothing restores it.
    it "does NOT cancel on the optimistic pre-provider stamp" do
      task = task_with

      instance.terminate!

      expect(task.reload.status).to eq("pending")
    end

    it "cancels once the provider confirms, after an optimistic stamp" do
      task = task_with
      instance.terminate!

      # mark_terminated is legal FROM :terminated, so this changes no column —
      # the event alone has to be enough to fire the sweep.
      instance.mark_terminated!

      expect(task.reload.status).to eq("cancelled")
    end

    it "leaves the queue intact when a failed terminate is reverted to error" do
      task = task_with

      instance.terminate!
      instance.revert_termination!

      expect(instance.reload.status).to eq("error")
      expect(task.reload.status).to eq("pending")
    end

    # Pins the saved_change_to_status? half of the guard. CloudSyncService
    # writes last_synced_at on already-terminated rows every cycle; re-sweeping
    # on each is a query per tick for nothing.
    it "does not re-sweep on an unrelated update to an already-terminated row" do
      instance.update!(status: "terminated")
      later = task_with

      instance.update!(last_synced_at: Time.current)

      expect(later.reload.status).to eq("pending")
    end

    # The path an event hook would miss, and the one that actually fires on
    # this fleet.
    it "cancels when `terminated` is written by a bare update!, bypassing AASM" do
      task = task_with

      instance.update!(status: "terminated")

      expect(task.reload.status).to eq("cancelled")
    end

    # THE EXAMPLE THAT MATTERS, per the operator's ruling. `error` is
    # recoverable and these very instances oscillate out of it hourly, so a
    # returning agent must find its work waiting. This kills the over-broad
    # mutant that cancels on any terminal-LOOKING status.
    it "leaves pending tasks ALONE when the instance moves to error" do
      task = task_with

      instance.update!(status: "error")

      expect(task.reload.status).to eq("pending")
    end

    it "leaves pending tasks alone for every other status transition" do
      task = task_with

      %w[stopping stopped rebooting starting running].each do |status|
        instance.update!(status: status)
        expect(task.reload.status).to eq("pending"), "cancelled on #{status}"
      end
    end

    it "cancels a scheduled task too" do
      task = task_with(status: "scheduled")

      instance.update!(status: "terminated")

      expect(task.reload.status).to eq("cancelled")
    end

    # `cancel` transitions only from pending/scheduled, so a task the agent has
    # already claimed is left to the janitor — deliberately, and the backstop
    # stays in place for it.
    it "leaves a RUNNING task to the janitor" do
      task = task_with(status: "running")

      instance.update!(status: "terminated")

      expect(task.reload.status).to eq("running")
    end

    it "does not disturb a task that already finished" do
      task = task_with(status: "complete")

      instance.update!(status: "terminated")

      expect(task.reload.status).to eq("complete")
    end

    # Every open task is unrunnable once the box is gone, not only the on-node
    # reconcile pair — a queued `start` against a destroyed VM is equally dead.
    it "cancels open tasks whatever the command" do
      sync = task_with(command: "sync_modules")
      config = task_with(command: "apply_config")
      boot = task_with(command: "upgrade_boot_image")

      instance.update!(status: "terminated")

      expect([ sync, config, boot ].map { |t| t.reload.status }).to all(eq("cancelled"))
    end

    it "records why, so the cancellation is not a bare status flip" do
      task = task_with

      instance.update!(status: "terminated")

      expect(task.reload.error_message).to match(/terminated/i)
    end

    it "touches no other instance's tasks" do
      other = create(:system_node_instance, node: node, status: "running")
      mine = task_with
      theirs = task_with(target: other)

      instance.update!(status: "terminated")

      expect(mine.reload.status).to eq("cancelled")
      expect(theirs.reload.status).to eq("pending")
    end

    it "is idempotent across a re-terminate" do
      task = task_with
      instance.update!(status: "terminated")

      expect { instance.mark_terminated! }.not_to raise_error
      expect(task.reload.status).to eq("cancelled")
    end

    # Cleanup must never break the lifecycle transition that triggered it.
    it "still terminates when a task refuses to cancel" do
      task_with
      allow_any_instance_of(::System::Task).to receive(:cancel!).and_raise(StandardError, "boom")

      expect { instance.update!(status: "terminated") }.not_to raise_error
      expect(instance.reload.status).to eq("terminated")
    end

    # The CONTINUATION, which the single-task version above cannot see: with one
    # task, deleting the per-iteration rescue leaves the outer one to catch and
    # the example stays green. Two tasks, one refusing, is what pins it.
    it "keeps sweeping after one task refuses" do
      first = task_with
      second = task_with

      allow_any_instance_of(::System::Task).to receive(:cancel!).and_wrap_original do |original, *args|
        raise StandardError, "boom" if original.receiver.id == first.id

        original.call(*args)
      end

      instance.update!(status: "terminated")

      expect(first.reload.status).to eq("pending")
      expect(second.reload.status).to eq("cancelled")
    end

    it "does not reach another account's tasks" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account)
      other_instance = create(:system_node_instance, node: other_node, status: "running")
      theirs = task_with(target: other_instance)

      instance.update!(status: "terminated")

      expect(theirs.reload.status).to eq("pending")
    end

    # The caller-driven entry for a row finalized after giving up its provider
    # identity. It must never empty a live queue, so both fences are pinned.
    describe "#cancel_unrunnable_tasks_of_lost_row!" do
      it "cancels the pending tasks of a terminated row whose identity is lost" do
        task = task_with
        instance.mark_provider_guest_lost!(reason: "guest at the id is named other-vm")
        instance.terminate!

        instance.cancel_unrunnable_tasks_of_lost_row!

        expect(task.reload.status).to eq("cancelled")
      end

      it "does nothing to a lost row that is not terminated" do
        task = task_with
        instance.mark_provider_guest_lost!(reason: "guest at the id is named other-vm")

        instance.cancel_unrunnable_tasks_of_lost_row!

        expect(task.reload.status).to eq("pending")
      end

      it "does nothing to a terminated row that did not lose its identity" do
        task = task_with
        instance.terminate!

        instance.cancel_unrunnable_tasks_of_lost_row!

        expect(task.reload.status).to eq("pending")
      end
    end
  end

  # IMP-cdf18862a7c1 — the three arms enumerated over EVERY status, because
  # #on_node_dispatch_refusal is now composed from #offline_dispatch_refusal
  # and #silence_verdict, and two operator-facing MCP verbs
  # (system_refresh_instance_modules, system_update_node's convergence rung)
  # take those arms SEPARATELY rather than the composed answer.
  #
  # Without this, the split is asserted only by a comment: replacing the
  # refresh verb's `instance.offline_dispatch_refusal` with an inline
  # `status == "terminated"` check leaves every tool-level example green,
  # because `error` — the status the reaper writes — was untested at both
  # levels. Enumerating the statuses is what makes that mutation die.
  describe 'the dispatch arms, per status (IMP-cdf18862a7c1)' do
    def instance_with(status:, heartbeat: nil)
      create(:system_node_instance, node: node, status: status, last_heartbeat_at: heartbeat)
    end

    # OFFLINE: outside LIVE_REPLICA_STATUSES. No agent process exists at all.
    # `error` belongs here even though it is a silence-derived label —
    # Fleet::DecisionEngine#reap_presumed_dead! is what writes it.
    %w[terminated error].each do |dead|
      it "answers #{dead} on the OFFLINE arm and nothing else" do
        instance = instance_with(status: dead)

        expect(instance.offline_dispatch_refusal).to include(dead)
        expect(instance.silence_verdict).to be_nil
        expect(instance.dormant_agent_reason).to be_nil
        expect(instance.on_node_dispatch_refusal).to eq(instance.offline_dispatch_refusal)
      end
    end

    # DORMANT: live for capacity, but nothing is expected to be reporting, so
    # BOTH refusal arms are nil and neither says an agent is listening. A
    # caller that reads "no refusal" as health is wrong for exactly these.
    %w[pending provisioning stopping stopped rebooting].each do |dormant|
      it "answers #{dormant} on the DORMANT arm, with neither refusal arm firing" do
        instance = instance_with(status: dormant)

        expect(instance.offline_dispatch_refusal).to be_nil
        expect(instance.on_node_dispatch_refusal).to be_nil
        expect(instance.silence_verdict).to be_nil
        expect(instance.dormant_agent_reason).to include(dormant)
      end
    end

    # EXPECTED-TO-REPORT: the only two statuses silence is evidence in.
    it 'leaves a healthy running instance on no arm at all' do
      instance = instance_with(status: 'running', heartbeat: Time.current)

      expect(instance.offline_dispatch_refusal).to be_nil
      expect(instance.dormant_agent_reason).to be_nil
      expect(instance.silence_verdict).to be_nil
      expect(instance.on_node_dispatch_refusal).to be_nil
    end

    it 'puts a silent running instance on the SILENCE arm, not the dormant one' do
      instance = instance_with(status: 'running', heartbeat: 30.minutes.ago)

      expect(instance.offline_dispatch_refusal).to be_nil
      expect(instance.dormant_agent_reason).to be_nil
      expect(instance.silence_verdict).to eq(:went_silent)
    end

    # `starting` is expected to report, so it is NOT dormant — a nil heartbeat
    # there is "not yet", which is why silence_verdict declines to judge it.
    it 'treats a not-yet-reported starting instance as neither dormant nor refused' do
      instance = instance_with(status: 'starting', heartbeat: nil)

      expect(instance.dormant_agent_reason).to be_nil
      expect(instance.silence_verdict).to be_nil
      expect(instance.on_node_dispatch_refusal).to be_nil
    end

    # The partition is the point: every status is on exactly one arm or none,
    # and no status is on two. A status added to LIVE_REPLICA_STATUSES without
    # a decision about HEARTBEAT_EXPECTED_STATUSES fails here.
    it 'assigns every declared status to at most one arm' do
      described_class::STATUSES.each do |status|
        instance = instance_with(status: status, heartbeat: nil)
        arms = [ instance.offline_dispatch_refusal, instance.dormant_agent_reason ].compact

        expect(arms.length).to be <= 1, "#{status} landed on both the offline and dormant arms"
      end
    end
  end
end
