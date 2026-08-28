# frozen_string_literal: true

require 'rails_helper'

# Agent hardware-inventory ingest (IMP-657e05418572).
#
# Until this landed, NodeInstance#gpu_count / #gpu_type / #gpu_memory_mb /
# #available_memory_mb / #hardware_model_hint all documented a fallback to a
# `config` hint "the on-node agent reports" — and NOTHING produced one. The
# agent now carries the inventory inside the EXISTING node_capabilities
# heartbeat block; this is the mapping that turns it into those hints.
#
# THE PAYLOAD BELOW IS NOT HAND-BUILT, AND NOT A COPY. It is READ from the
# artifact the Go detector itself writes:
#
#   agent/internal/runtime/testdata/node_capabilities_golden.json
#   written + asserted by hardware_test.go :: TestDetectCapabilitiesWirePayload
#
# One artifact, two consumers. A cross-language lane where each end keeps its
# own copy of the fixture goes green against an input no node ever emits — and
# two hand-kept literals would have tripped only the Go side. Reading the file
# means an agent wire-shape change lands in THIS spec's input directly.
RSpec.describe System::NodeInstance, 'agent hardware hint ingest', type: :model do
  let(:node) { create(:system_node) }

  # A `let`, not a constant: a constant assigned inside a describe block lands
  # on Object, where a same-named one in another spec file silently clobbers it.
  let(:golden_path) do
    File.expand_path(
      '../../../../agent/internal/runtime/testdata/node_capabilities_golden.json',
      __dir__
    )
  end
  let(:agent_wire_payload) { File.read(golden_path).strip }

  it 'reads the payload the Go detector actually wrote' do
    expect(File).to exist(golden_path),
                    "missing #{golden_path} — regenerate with " \
                    "UPDATE_GOLDEN=1 go test ./internal/runtime/ -run TestDetectCapabilitiesWirePayload"
    expect(JSON.parse(agent_wire_payload)).to include('gpu_count', 'memory_total_mb', 'hardware_model')
  end

  # No provider_instance_type: the SKU wins over the config hint in every
  # capacity reader, so a bound SKU would mask exactly what we're testing.
  # This is the bare-metal shape the defect is about.
  def bare_metal(config: {})
    create(:system_node_instance,
           node: node,
           variety: 'physical',
           provider_instance_type: nil,
           config: config)
  end

  def caps(overrides = {})
    JSON.parse(agent_wire_payload).merge(overrides.stringify_keys)
  end

  describe 'the wire payload the agent actually emits' do
    it 'maps the whole inventory into the config hints the capacity readers read' do
      instance = bare_metal
      instance.record_capabilities!(JSON.parse(agent_wire_payload))
      instance.reload

      expect(instance.config['gpu']).to eq(
        'count' => 2, 'type' => 'NVIDIA H100 PCIe', 'memory_mb' => 81_559
      )
      expect(instance.config['memory_mb']).to eq(257_000)
      expect(instance.config['hardware_model']).to eq('PowerEdge R740')

      # ...and therefore the readers themselves resolve, which is the whole
      # point: system_find_node_with_gpu can finally see a bare-metal GPU node.
      expect(instance.gpu_count).to eq(2)
      expect(instance.gpu_type).to eq('NVIDIA H100 PCIe')
      expect(instance.gpu_memory_mb).to eq(81_559)
      expect(instance.gpu?).to be(true)
      expect(instance.available_memory_mb).to eq(257_000)
    end

    it 'still records the kernel capability block it rode in on' do
      instance = bare_metal
      instance.record_capabilities!(JSON.parse(agent_wire_payload))
      instance.reload

      expect(instance.capabilities['erofs_available']).to be(true)
      expect(instance.supports_erofs?).to be(true)
    end
  end

  # The load-bearing safety property. We deliberately do NOT rely on knowing
  # whether any live row carries a hand-set hint: the ingest is built so that
  # answer cannot matter.
  describe 'never clobbers an operator-set value' do
    let(:operator_config) do
      {
        'gpu' => { 'count' => 8, 'type' => 'A100', 'memory_mb' => 40_960 },
        'memory_mb' => 999_999,
        'hardware_model' => 'operator_asserted_box'
      }
    end

    it 'leaves every operator-set hint intact when detection disagrees' do
      instance = bare_metal(config: operator_config)
      instance.record_capabilities!(JSON.parse(agent_wire_payload))
      instance.reload

      expect(instance.config['gpu']).to eq(operator_config['gpu'])
      expect(instance.config['memory_mb']).to eq(999_999)
      expect(instance.config['hardware_model']).to eq('operator_asserted_box')
    end

    it 'never writes an empty detection result over an existing value' do
      instance = bare_metal(config: operator_config)
      # A kernel-only report: the agent measured nothing about the hardware
      # (no lspci, no nvidia-smi, unreadable meminfo, no DMI).
      instance.record_capabilities!(
        'kernel_version' => '6.8.0-136-generic', 'erofs_available' => true
      )
      instance.reload

      expect(instance.config['gpu']).to eq(operator_config['gpu'])
      expect(instance.config['memory_mb']).to eq(999_999)
      expect(instance.config['hardware_model']).to eq('operator_asserted_box')
    end

    it 'does not invent hints on a row that had none when nothing was detected' do
      instance = bare_metal
      instance.record_capabilities!('kernel_version' => '6.8.0-136-generic')
      instance.reload

      expect(instance.config).not_to have_key('gpu')
      expect(instance.config).not_to have_key('memory_mb')
      expect(instance.config).not_to have_key('hardware_model')
      expect(instance.available_memory_mb).to be_nil
      expect(instance.gpu?).to be(false)
    end
  end

  describe 'absence stays distinguishable from a measured zero' do
    it 'writes an explicit zero when a detector ran and found no GPU' do
      instance = bare_metal
      instance.record_capabilities!(
        caps('gpu_count' => 0).except('gpu_type', 'gpu_memory_mb')
      )
      instance.reload

      expect(instance.config['gpu']).to eq('count' => 0)
      expect(instance.gpu_count).to eq(0)
      expect(instance.gpu?).to be(false)
    end

    it 'writes no gpu hint at all when the count was never measured' do
      instance = bare_metal
      instance.record_capabilities!(
        caps.except('gpu_count', 'gpu_type', 'gpu_memory_mb')
      )
      instance.reload

      expect(instance.config).not_to have_key('gpu')
      # Other detected facts in the same report still land — the probes are
      # independent, so one unmeasured fact must not suppress the others.
      expect(instance.config['memory_mb']).to eq(257_000)
    end

    it 'omits gpu memory_mb on the lspci fallback rather than reporting zero VRAM' do
      instance = bare_metal
      instance.record_capabilities!(
        caps('gpu_count' => 1, 'gpu_type' => 'NVIDIA Corporation GA100')
          .except('gpu_memory_mb')
      )
      instance.reload

      expect(instance.config['gpu']).to eq('count' => 1, 'type' => 'NVIDIA Corporation GA100')
      expect(instance.gpu_memory_mb).to be_nil
    end
  end

  describe 'agent-owned hints refresh; operator-owned hints do not' do
    it 'updates a value the agent itself wrote on an earlier heartbeat' do
      instance = bare_metal
      instance.record_capabilities!(caps('memory_total_mb' => 4096))
      instance.reload
      expect(instance.config['memory_mb']).to eq(4096)

      instance.record_capabilities!(caps('memory_total_mb' => 8192))
      instance.reload
      expect(instance.config['memory_mb']).to eq(8192)
    end

    it 'does not re-issue a config write when a repeat report changes nothing' do
      instance = bare_metal
      instance.record_capabilities!(JSON.parse(agent_wire_payload))
      instance.reload
      before = instance.config

      # Asserting the VALUE is unchanged cannot fail — an identical rewrite
      # looks the same. Assert the write does not happen: this runs on every
      # 30s heartbeat for every node in the fleet.
      expect(instance).not_to receive(:update_columns).with(hash_including(:config))
      allow(instance).to receive(:update_columns).and_call_original
      instance.record_capabilities!(JSON.parse(agent_wire_payload))

      expect(instance.reload.config).to eq(before)
    end

    # The hole a key-name provenance stamp leaves open: the stamp itself
    # round-trips through the ordinary operator edit path (the serializer
    # returns the whole config; NodeInstancesController#update permits
    # `config: {}` wholesale), so "the agent owns this key" would be handed
    # straight back and the correction silently overwritten next heartbeat.
    it 'stops refreshing a hint once anything else has changed it' do
      instance = bare_metal
      instance.record_capabilities!(caps('memory_total_mb' => 4096))
      instance.reload
      expect(instance.config['memory_mb']).to eq(4096)

      # Operator corrects the value and PATCHes the whole config back,
      # provenance stamp included — exactly what the UI round-trip produces.
      round_tripped = instance.config.merge('memory_mb' => 65_536)
      instance.update!(config: round_tripped)

      instance.record_capabilities!(caps('memory_total_mb' => 4096))
      instance.reload
      expect(instance.config['memory_mb']).to eq(65_536)

      # ...and it stays corrected on every subsequent heartbeat.
      instance.record_capabilities!(caps('memory_total_mb' => 8192))
      expect(instance.reload.config['memory_mb']).to eq(65_536)
    end

    it 'leaves the untouched hints refreshable after one of them is corrected' do
      instance = bare_metal
      instance.record_capabilities!(JSON.parse(agent_wire_payload))
      instance.reload

      instance.update!(config: instance.config.merge('memory_mb' => 65_536))
      instance.record_capabilities!(caps('hardware_model' => 'PowerEdge R760'))
      instance.reload

      expect(instance.config['memory_mb']).to eq(65_536)
      expect(instance.config['hardware_model']).to eq('PowerEdge R760')
    end
  end

  describe 'hardware_model canonicalisation' do
    it 'maps a device-tree Pi model onto the token suggest_network_profile knows' do
      instance = bare_metal
      instance.record_capabilities!(
        caps('hardware_model' => 'Raspberry Pi 5 Model B Rev 1.0', 'memory_total_mb' => 7900)
      )
      instance.reload

      expect(instance.config['hardware_model']).to eq('raspberry_pi_5')
      instance.update_columns(architecture: 'arm64')
      expect(instance.reload.suggest_network_profile).to eq('heavyweight')
    end

    # The fleet-visible consequence of producing a memory fact at all: before
    # this, a bare-metal instance with no bound SKU had no memory fact and
    # suggest_network_profile always took its "cannot prove headroom" branch.
    # Pinned so the promotion is a declared behaviour, not a surprise.
    it 'lets an amd64 bare-metal host classify heavyweight on first contact' do
      instance = bare_metal
      instance.update_columns(architecture: 'amd64')
      expect(instance.suggest_network_profile).to eq('lightweight')

      instance.record_capabilities!(caps('memory_total_mb' => 15_800))
      expect(instance.reload.suggest_network_profile).to eq('heavyweight')
    end

    it 'still classifies lightweight when the detected memory is under the floor' do
      instance = bare_metal
      instance.update_columns(architecture: 'amd64')
      instance.record_capabilities!(caps('memory_total_mb' => 2048))
      expect(instance.reload.suggest_network_profile).to eq('lightweight')
    end

    it 'maps a Pi 4 the same way' do
      instance = bare_metal
      instance.record_capabilities!(caps('hardware_model' => 'Raspberry Pi 4 Model B Rev 1.4'))
      instance.reload

      expect(instance.config['hardware_model']).to eq('raspberry_pi_4')
    end

    it 'passes an unrecognised model through verbatim' do
      instance = bare_metal
      instance.record_capabilities!(caps('hardware_model' => 'PowerEdge R740'))
      instance.reload

      expect(instance.config['hardware_model']).to eq('PowerEdge R740')
      expect(instance.send(:hardware_model_hint)).to eq('poweredge_r740')
    end
  end

  describe '.hardware_hints_from_capabilities' do
    it 'returns only the keys detection actually produced' do
      expect(described_class.hardware_hints_from_capabilities('kernel_version' => '6.8'))
        .to eq({})
    end

    it 'is forgiving about a blank or nil report' do
      expect(described_class.hardware_hints_from_capabilities(nil)).to eq({})
      expect(described_class.hardware_hints_from_capabilities({})).to eq({})
    end

    it 'ignores a non-numeric count rather than fabricating one' do
      expect(described_class.hardware_hints_from_capabilities('gpu_count' => 'lots'))
        .to eq({})
    end
  end
end
