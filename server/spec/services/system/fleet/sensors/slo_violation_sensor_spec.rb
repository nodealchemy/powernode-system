# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::SloViolationSensor do
  let(:account)     { create(:account) }
  let(:platform)    { create(:system_node_platform, account: account) }
  let(:template)    { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)        { create(:system_node, account: account, node_template: template) }
  let(:node_module) { create(:system_node_module, account: account) }
  let(:sensor)      { described_class.new(account: account) }

  def attach_instance(heartbeat:)
    instance = create(:system_node_instance, node: node, status: "running", last_heartbeat_at: heartbeat)
    create(:system_node_module_assignment, node: node, node_module: node_module)
    instance
  end

  def make_definition(uptime_target_pct: 99.9)
    System::Slo::Definition.create!(
      node_module: node_module,
      name: "slo-#{SecureRandom.hex(3)}",
      window: "1h",
      uptime_target_pct: uptime_target_pct
    )
  end

  describe "#sense" do
    it "emits a system.slo_violation signal when uptime falls below target" do
      defn = make_definition
      attach_instance(heartbeat: 2.hours.ago) # outside the 1h window -> counts as unhealthy

      sig = sensor.sense.find { |s| s.kind == "system.slo_violation" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.slo_violation")
      expect(sig.severity).to eq(:medium) # single metric off-target
      expect(sig.payload["module_id"]).to eq(node_module.id)
      expect(sig.payload["violations"]).to include(a_hash_including("metric" => "uptime_pct"))
      expect(sig.fingerprint).to eq("slo_violation:#{defn.id}")
    end

    it "returns no signal when the module is within every configured target" do
      make_definition
      attach_instance(heartbeat: Time.current)

      expect(sensor.sense).to be_empty
    end
  end

  it "binds system.slo_violation to the module_assign gate in SIGNAL_BINDINGS" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.slo_violation"]

    expect(binding).to be_present
    expect(binding[:action_category]).to eq("system.module_assign")
  end
end
