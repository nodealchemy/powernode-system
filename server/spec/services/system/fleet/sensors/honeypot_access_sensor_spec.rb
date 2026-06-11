# frozen_string_literal: true

require "rails_helper"

# Audit finding F3-08: honeypot_access signals carried no instance_id, so the
# bound system.instance_terminate approval had no target to quarantine and
# could not dedup per instance.
RSpec.describe System::Fleet::Sensors::HoneypotAccessSensor do
  let(:account)       { create(:account) }
  let(:sensor)        { described_class.new(account: account) }
  let(:canary_module) { create(:system_node_module, account: account) }

  def trigger_event
    create(:system_fleet_event, account: account,
           kind: "system.honeypot_triggered",
           severity: "high",
           source: "honeypot",
           payload: { "source" => "auth.log", "module_id" => canary_module.id },
           node_module_id: canary_module.id,
           emitted_at: 1.minute.ago)
  end

  describe "#sense" do
    it "emits nothing without honeypot_triggered events" do
      expect(sensor.sense).to eq([])
    end

    context "when running instances host the canary module" do
      let(:platform)  { create(:system_node_platform, account: account) }
      let(:template)  { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)      { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }
      let!(:assignment) do
        create(:system_node_module_assignment, node: node, node_module: canary_module)
      end

      it "stamps the hosting instance_id so the terminate approval has a target" do
        trigger_event

        signals = sensor.sense
        expect(signals.size).to eq(1)
        payload = signals.first.payload
        expect(payload["instance_id"]).to eq(instance.id)
        expect(payload["module_id"]).to eq(canary_module.id)
        expect(payload["source"]).to eq("auth.log")
      end

      it "emits one signal per hosting running instance" do
        node2 = create(:system_node, account: account, node_template: template)
        instance2 = create(:system_node_instance, :running, node: node2)
        create(:system_node_module_assignment, node: node2, node_module: canary_module)

        trigger_event

        signals = sensor.sense
        expect(signals.map { |s| s.payload["instance_id"] })
          .to contain_exactly(instance.id, instance2.id)
      end
    end

    context "when nothing hosts the canary module" do
      it "still emits an instance-less signal carrying module_id for fallback dedup" do
        trigger_event

        signals = sensor.sense
        expect(signals.size).to eq(1)
        expect(signals.first.payload["instance_id"]).to be_nil
        expect(signals.first.payload["module_id"]).to eq(canary_module.id)
      end
    end
  end
end
