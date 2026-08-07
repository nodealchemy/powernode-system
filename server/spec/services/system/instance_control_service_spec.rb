# frozen_string_literal: true

require 'rails_helper'

# IMP-bb5fdd6bce28 — physical instances have no real IPMI/WoL driver behind
# them (no ipmitool/wakeonlan call anywhere in the codebase). The IPMI/WoL
# branches used to only Rails.logger.info(...) and then claim
# { success: true, status: ... }, which the AASM finalizer turned into a
# confident "running"/"stopped" row while the machine's actual power state
# never changed. These specs pin the safety fix: until a real driver exists,
# these branches must report failure so the transitional status reverts
# instead of a false terminal stamp landing on the row.
RSpec.describe System::InstanceControlService do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }

  describe '#execute — physical start via IPMI (no driver implemented)' do
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'stopped',
             config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'reports failure instead of a fake success' do
      result = described_class.execute(instance: instance, action: :start)

      expect(result.success?).to be false
    end

    it 'does not stamp the row running — the machine never actually powered on' do
      described_class.execute(instance: instance, action: :start)

      expect(instance.reload.status).not_to eq('running')
    end
  end

  describe '#execute — physical start via Wake-on-LAN (no driver implemented)' do
    # mac_address is a first-class column, NOT stored under config["mac_address"].
    # Regression guard for the bonus defect: the WoL branch must read the real
    # column so it is actually reachable for normally-populated instances.
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'stopped',
             mac_address: '00:11:22:33:44:55')
    end

    it 'recognizes the mac_address column and still reports failure (no fake success)' do
      result = described_class.execute(instance: instance, action: :start)

      expect(result.success?).to be false
      expect(result.error).to eq('Wake-on-LAN is not implemented')
    end

    it 'does not stamp the row running' do
      described_class.execute(instance: instance, action: :start)

      expect(instance.reload.status).not_to eq('running')
    end
  end

  describe '#execute — physical stop via IPMI fallback (no SSH route, no driver implemented)' do
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'running',
             private_ip_address: nil, config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'reports failure instead of a fake success' do
      result = described_class.execute(instance: instance, action: :stop)

      expect(result.success?).to be false
    end

    it 'does not stamp the row stopped — the machine never actually powered off' do
      described_class.execute(instance: instance, action: :stop)

      expect(instance.reload.status).not_to eq('stopped')
    end
  end

  describe '#execute — physical reboot via IPMI fallback (no SSH route, no driver implemented)' do
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'running',
             private_ip_address: nil, config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'reports failure instead of a fake success' do
      result = described_class.execute(instance: instance, action: :reboot)

      expect(result.success?).to be false
    end
  end

  describe '#execute — failed stop reverts the transitional status back to running' do
    # IMP-0d7071dc03f7 — revert_status's "stopping" branch calls mark_running!,
    # but mark_running's AASM from-list didn't include :stopping, so the
    # may_mark_running? guard was always false and the row stuck in
    # "stopping" instead of reverting to the last-known-good "running" state.
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'running',
             private_ip_address: nil, config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'reverts to running instead of getting stuck in stopping' do
      result = described_class.execute(instance: instance, action: :stop)

      expect(result.success?).to be false
      expect(instance.reload.status).to eq('running')
    end
  end

  describe '#execute — failed start reverts the transitional status back to stopped' do
    # IMP-0d7071dc03f7 — revert_status's "starting" branch calls mark_stopped!,
    # but mark_stopped's AASM from-list didn't include :starting, so the
    # may_mark_stopped? guard was always false and the row stuck in
    # "starting" instead of reverting to the last-known-good "stopped" state.
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'stopped',
             config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'reverts to stopped instead of getting stuck in starting' do
      result = described_class.execute(instance: instance, action: :start)

      expect(result.success?).to be false
      expect(instance.reload.status).to eq('stopped')
    end
  end

  describe '#execute — physical stop still uses the real SSH path when reachable' do
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'running',
             private_ip_address: '10.0.1.20', config: { 'ipmi' => { 'host' => '10.0.0.5' } })
    end

    it 'succeeds via SSH without touching the IPMI stub' do
      allow(System::SshExecutionService).to receive(:execute).and_return(
        System::Runtime::Result.ok(data: { exit_code: 0 })
      )

      result = described_class.execute(instance: instance, action: :stop)

      expect(result.success?).to be true
      expect(instance.reload.status).to eq('stopped')
    end
  end

  # IMP-af53c24a956f — terminate had zero coverage. cloud_instance_id is a
  # store_accessor on config (see NodeInstance), so it's settable directly on
  # the factory the same way cloud_sync_service_spec/image_creation_service_spec
  # already do it.
  describe '#execute — terminate (cloud)' do
    let(:instance) do
      create(:system_node_instance, node: node, status: 'stopped', cloud_instance_id: 'i-terminate-1')
    end
    # Mirrors decision_engine_spec's convention: instance_double the adapter
    # contract, then stub the specific action method per example.
    let(:adapter) { instance_double('System::Providers::BaseProvider', provider_type: 'proxmox') }

    before { allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter) }

    it 'terminates the instance when the provider reports success' do
      # Full build_instance_response shape — real adapters always include the
      # ip keys (as nil) on terminate, which drives the post-success ip write.
      # A bare { success: true } stub would skip that branch and hide bugs in it.
      allow(adapter).to receive(:terminate_instance).with('i-terminate-1').and_return(
        success: true, cloud_instance_id: 'i-terminate-1', status: 'terminated',
        private_ip_address: nil, public_ip_address: nil, provider_type: 'proxmox'
      )

      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be true
      expect(instance.reload.status).to eq('terminated')
    end

    # The inverse hazard of reverting a failed terminate: once the provider
    # destroy has genuinely succeeded, NOTHING may un-terminate the row — the
    # machine is gone. Post-success bookkeeping (the ip-field write) can fail
    # transiently; that must surface in the Result, not resurrect the row.
    it 'keeps the row terminated when post-success bookkeeping raises' do
      allow(adapter).to receive(:terminate_instance).with('i-terminate-1').and_return(
        success: true, private_ip_address: nil, public_ip_address: nil
      )
      allow(instance).to receive(:update!)
        .and_raise(ActiveRecord::StatementInvalid, 'server closed the connection')

      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be false
      expect(instance.reload.status).to eq('terminated')
    end

    # A failed terminate must not leave a false terminated stamp on the row —
    # the disk may still exist on the provider side. The row goes to :error so
    # an operator investigates instead of the platform believing it's gone.
    it 'does not stamp the row terminated when the provider reports failure — goes to error instead' do
      allow(adapter).to receive(:terminate_instance).with('i-terminate-1')
        .and_return(success: false, error: 'guest is locked')

      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be false
      expect(result.error).to eq('guest is locked')
      expect(instance.reload.status).to eq('error')
    end

    it 'does not stamp the row terminated when the provider raises — goes to error instead' do
      allow(adapter).to receive(:terminate_instance).with('i-terminate-1')
        .and_raise(System::Providers::BaseProvider::ProviderError, 'api timeout')

      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be false
      expect(instance.reload.status).to eq('error')
    end
  end

  describe '#execute — terminate (physical)' do
    # Physical terminate is an unconditional platform-side no-op success —
    # there is no provider to call and no driver to fake (see the IPMI/WoL
    # specs above for why physical control otherwise refuses rather than
    # fakes success).
    let(:instance) do
      create(:system_node_instance, :physical, node: node, status: 'stopped')
    end

    it 'succeeds without a provider and marks the row terminated' do
      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be true
      expect(instance.reload.status).to eq('terminated')
    end
  end

  describe '#execute — terminate refused under ops hold' do
    let(:instance) do
      create(:system_node_instance, node: node, status: 'stopped', cloud_instance_id: 'i-held-1',
             ops_hold_at: Time.current, ops_hold_reason: 'offline /persist edit')
    end

    it 'refuses and leaves the status unchanged — terminate would destroy the disks under hold' do
      result = described_class.execute(instance: instance, action: :terminate)

      expect(result.success?).to be false
      expect(result.error).to match(/ops hold/i)
      expect(instance.reload.status).to eq('stopped')
    end
  end
end
