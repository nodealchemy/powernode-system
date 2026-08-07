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
