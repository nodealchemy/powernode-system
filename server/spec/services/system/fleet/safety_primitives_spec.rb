# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block L1 + Q — HoneypotAccessSensor + AttributionFeedbackService
# (and CanaryModuleService observe path).
RSpec.describe "Fleet safety primitives" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "honeypot-mod")
  end

  describe System::Honeypot::CanaryModuleService do
    it "marks a module with honeypot config flag" do
      ok = described_class.mark!(node_module: mod, lure_kind: "credential_store")
      expect(ok).to be true
      expect(mod.reload.config["honeypot"]["canary"]).to be true
      expect(mod.config["honeypot"]["lure_kind"]).to eq("credential_store")
    end

    it "is idempotent" do
      described_class.mark!(node_module: mod)
      original = mod.reload.config["honeypot"]["marked_at"]
      expect {
        described_class.mark!(node_module: mod)
      }.not_to change { mod.reload.config["honeypot"]["marked_at"] }
      expect(original).to be_present
    end

    it ".canary? returns true when tagged" do
      described_class.mark!(node_module: mod)
      expect(described_class.canary?(node_module: mod.reload)).to be true
    end

    it ".observe_access! emits a high-severity FleetEvent on canary access" do
      described_class.mark!(node_module: mod)
      expect {
        described_class.observe_access!(node_module: mod.reload, source: "test_runner")
      }.to change(System::FleetEvent, :count).by(1)

      event = System::FleetEvent.last
      expect(event.kind).to eq("system.honeypot_triggered")
      expect(event.severity).to eq("high")
      expect(event.node_module_id).to eq(mod.id)
    end

    it ".observe_access! is a no-op for non-canary modules" do
      expect {
        described_class.observe_access!(node_module: mod, source: "test_runner")
      }.not_to change(System::FleetEvent, :count)
    end
  end

  describe System::Fleet::Sensors::HoneypotAccessSensor do
    let(:sensor) { described_class.new(account: account) }

    it "emits no signal when no honeypot events recently" do
      expect(sensor.sense).to be_empty
    end

    it "emits critical-severity signal when honeypot_triggered events present" do
      System::Honeypot::CanaryModuleService.mark!(node_module: mod)
      System::Honeypot::CanaryModuleService.observe_access!(node_module: mod.reload, source: "intrusion_test")

      signals = sensor.sense
      expect(signals.size).to eq(1)
      s = signals.first
      expect(s.kind).to eq("system.honeypot_access")
      expect(s.severity).to eq(:critical)
      expect(s.payload["module_id"]).to eq(mod.id)
    end
  end

  describe System::Fleet::AttributionFeedbackService do
    let(:service) { described_class.new(account: account) }

    it "creates a CompoundLearning + FleetEvent on confirm" do
      expect {
        result = service.record!(
          instance_id: instance.id,
          candidate_module_id: mod.id,
          candidate_kind: "assignment_change",
          confirmed: true,
          note: "this was the cause"
        )
        expect(result[:ok]).to be true
        expect(result[:learning_id]).to be_present
      }.to change(Ai::CompoundLearning, :count).by(1)
       .and change(System::FleetEvent, :count).by(1)

      learning = Ai::CompoundLearning.last
      expect(learning.tags).to include("fleet", "attribution", "module:#{mod.id}",
                                        "kind:assignment_change", "outcome:confirmed")
      expect(learning.category).to eq("discovery")
    end

    it "creates a failure_mode learning on reject" do
      result = service.record!(
        instance_id: instance.id,
        candidate_module_id: mod.id,
        candidate_kind: "assignment_change",
        confirmed: false
      )
      expect(result[:ok]).to be true
      expect(Ai::CompoundLearning.last.category).to eq("failure_mode")
      expect(Ai::CompoundLearning.last.tags).to include("outcome:rejected")
    end

    it "fails fast when instance is in a different account" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
      other_node = create(:system_node, account: other_account, node_template: other_template)
      other_instance = create(:system_node_instance, :running, node: other_node)

      result = service.record!(
        instance_id: other_instance.id,
        candidate_module_id: mod.id,
        candidate_kind: "assignment_change",
        confirmed: true
      )
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/instance not in account/)
    end

    it "fails fast when module is in a different account" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_mod = create(:system_node_module, account: other_account, node_platform: other_platform,
                         category: create(:system_node_module_category, account: other_account),
                         variety: "subscription", name: "other-mod")
      result = service.record!(
        instance_id: instance.id,
        candidate_module_id: other_mod.id,
        candidate_kind: "assignment_change",
        confirmed: true
      )
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/module not in account/)
    end
  end
end
