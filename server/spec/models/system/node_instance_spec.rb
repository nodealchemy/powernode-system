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
    it { is_expected.to have_many(:instance_mount_points).class_name('System::InstanceMountPoint').dependent(:destroy) }
    it { is_expected.to have_many(:mount_points).through(:instance_mount_points) }
    it { is_expected.to have_many(:tasks).class_name('System::Task').dependent(:destroy) }
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

      it 'is false for pending instances' do
        instance.status = 'pending'
        expect(instance.may_terminate?).to be false
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
end
