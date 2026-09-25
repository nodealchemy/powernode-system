# frozen_string_literal: true

require "rails_helper"

# fleet.tick_complete carries each sensor's diagnostics, keyed by sensor_key.
#
# A sensor that deliberately skips candidates (ConfigDriftSensor skips this
# deployment's own hosting node) would otherwise do it silently. The count
# belongs on the tick's own event, NOT as a signal: a signal is what the
# decision engine acts on, and re-signalling a skip recreates the noise the
# skip removed. A sensor that raised reports nothing here, so "ran, skipped 0"
# (present, 0) stays distinct from "not measured" (absent, and named in
# failed_sensors).
RSpec.describe System::Fleet::FleetAutonomyService, "fleet.tick_complete sensor_diagnostics" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { described_class.new(account: account, agent: agent) }

  def sensor(short_name, diagnostics: nil, &sense)
    Class.new(System::Fleet::Sensors::BaseSensor) do
      define_singleton_method(:name) { "System::Fleet::Sensors::#{short_name}" }
      define_method(:sense, &sense)
      define_method(:diagnostics) { diagnostics } if diagnostics
    end
  end

  def last_tick_complete
    System::FleetEvent.where(account: account, kind: "fleet.tick_complete").order(emitted_at: :desc).first
  end

  it "carries a sensor's diagnostics by sensor_key, including a zero count" do
    stub_const("#{described_class}::SENSORS", [
      sensor("CountingSensor", diagnostics: { skipped_self_managed: 0 }) { [] },
      sensor("QuietSensor") { [] }
    ])

    service.tick!

    expect(last_tick_complete.payload["sensor_diagnostics"]).to eq("counting" => { "skipped_self_managed" => 0 })
  end

  it "omits a sensor that raised, which failed_sensors names instead" do
    stub_const("#{described_class}::SENSORS", [
      sensor("CountingSensor", diagnostics: { skipped_self_managed: 3 }) { raise "boom" }
    ])
    allow(Rails.logger).to receive(:error)

    service.tick!

    expect(last_tick_complete.payload["sensor_diagnostics"]).to eq({})
    expect(last_tick_complete.payload["failed_sensors"]).to eq([ "CountingSensor" ])
  end

  it "carries the config drift sensor's skip count through a real tick" do
    stub_const("#{described_class}::SENSORS", [ System::Fleet::Sensors::ConfigDriftSensor ])

    service.tick!

    expect(last_tick_complete.payload["sensor_diagnostics"]).to eq("config_drift" => { "skipped_self_managed" => 0 })
  end
end
