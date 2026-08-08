# frozen_string_literal: true

require "rails_helper"

# Audit finding F3-05 (see decision_engine_spec.rb's "system.instance_state_drifted"
# context, ~line 333): this sensor's signal kind had no SIGNAL_BINDINGS entry,
# so every provider-state drift it detected was silently discarded as decision
# :skipped. The kind-registry example below pins that against regressing.
RSpec.describe System::Fleet::Sensors::InstanceStateDriftSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:adapter)  { instance_double("System::Providers::BaseProvider") }
  let(:sensor)   { described_class.new(account: account) }

  before { allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter) }

  def running_instance(cloud_instance_id: "i-#{SecureRandom.hex(4)}")
    create(:system_node_instance, node: node, status: "running", cloud_instance_id: cloud_instance_id)
  end

  describe "#sense" do
    it "emits system.instance_state_drifted when the provider reports the instance stopped" do
      instance = running_instance
      allow(adapter).to receive(:sync_status).with(instance.cloud_instance_id)
        .and_return(success: true, status: "stopped")

      sig = sensor.sense.find { |s| s.kind == "system.instance_state_drifted" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.instance_state_drifted")
      expect(sig.severity).to eq(:high)
      expect(sig.payload["instance_id"]).to eq(instance.id)
      expect(sig.payload["expected_status"]).to eq("running")
      expect(sig.payload["actual_status"]).to eq("stopped")
    end

    # IMP-e26d76041d9a — the unordered LIMIT window: Postgres may return the
    # same arbitrary MAX_PER_TICK rows every tick, so instances beyond the
    # window were never drift-checked. A successful provider read IS a status
    # sync, so it stamps last_synced_at (CloudSyncService's column, same
    # success-only convention), and sense orders by it NULLS FIRST — the
    # window rotates least-recently-synced first.
    # IMP-bcadb1ecd52d — the starvation valve. The IMP-e26d76041d9a rotation
    # ordered by SUCCESS-stamped last_synced_at, so never-stampable rows (no
    # cloud id, no adapter, persistently failing reads) kept NULL forever,
    # pinned the front of the window, and with MAX_PER_TICK of them starved
    # everything else. Rotation now orders by last_sync_attempted_at, stamped
    # on EVERY attempt; last_synced_at stays success-only for its readers.
    describe "starvation valve (attempt-ordered rotation)" do
      it "cannot be starved by never-stampable instances" do
        stub_const("#{described_class}::MAX_PER_TICK", 3)
        3.times { running_instance(cloud_instance_id: nil) } # never stampable
        reachable = running_instance
        allow(adapter).to receive(:sync_status).and_return(success: true, status: "running")

        sensor.sense # tick 1: window consumed by the unstampables (attempts stamped)
        sensor.sense # tick 2: rotation must reach the stampable instance

        expect(adapter).to have_received(:sync_status).with(reachable.cloud_instance_id)
      end

      it "stamps last_sync_attempted_at on every attempt while last_synced_at stays success-only" do
        failing = running_instance
        allow(adapter).to receive(:sync_status).and_return(success: false, error: "boom")

        sensor.sense

        expect(failing.reload.last_sync_attempted_at).to be_present
        expect(failing.reload.last_synced_at).to be_nil
      end
    end

    describe "window rotation" do
      it "stamps last_synced_at on a successful provider read" do
        instance = running_instance
        allow(adapter).to receive(:sync_status)
          .and_return(success: true, status: "running")

        expect { sensor.sense }.to change { instance.reload.last_synced_at }.from(nil)
      end

      it "fills the capped window least-recently-synced first" do
        stub_const("#{described_class}::MAX_PER_TICK", 2)
        # Ordering pivoted to last_sync_attempted_at (IMP-bcadb1ecd52d) —
        # stamped on every attempt, so the rotation cannot be pinned by rows
        # that never sync successfully.
        recently = running_instance
        recently.update_column(:last_sync_attempted_at, 1.minute.ago)
        stale = running_instance
        stale.update_column(:last_sync_attempted_at, 2.days.ago)
        never = running_instance # nil last_sync_attempted_at sorts first

        seen = []
        allow(adapter).to receive(:sync_status) do |cloud_id|
          seen << cloud_id
          { success: true, status: "running" }
        end

        sensor.sense

        expect(seen).to contain_exactly(never.cloud_instance_id, stale.cloud_instance_id)
      end
    end

    it "returns no signal when the provider status still agrees with the DB" do
      instance = running_instance
      allow(adapter).to receive(:sync_status).with(instance.cloud_instance_id)
        .and_return(success: true, status: "running")

      expect(sensor.sense).to be_empty
    end

    # The provider call can fail (timeout, auth error, etc.) — the sensor
    # must treat that as "no data" and skip the instance, not fabricate a
    # drift signal from a stale/zeroed status.
    it "does not fabricate a drift signal when the provider call is unavailable" do
      instance = running_instance
      allow(adapter).to receive(:sync_status).with(instance.cloud_instance_id)
        .and_return(success: false, error: "timeout")

      expect(sensor.sense).to be_empty
    end
  end

  it "registers system.instance_state_drifted in the DecisionEngine's SIGNAL_BINDINGS" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_state_drifted"]

    expect(binding).to be_present
    expect(binding[:action_category]).to eq("system.instance_reboot")
  end
end
