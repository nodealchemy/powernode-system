# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b B5 — fleet.tick_complete names the sensors that raised.
#
# collect_signals has collected the failed sensor names since F3-11(a), but
# handed them only to the validator. The event every other reader sees
# omitted them, so a tick whose honeypot sensor raised looked exactly like a
# healthy tick. The honeypot status contributor reads this key to report its
# feed as not measured instead of clear.
RSpec.describe System::Fleet::FleetAutonomyService, "fleet.tick_complete failed_sensors" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { described_class.new(account: account, agent: agent) }

  # A stand-in sensor. collect_signals reports `sensor_class.name.demodulize`,
  # so the class name is what the payload must carry.
  def sensor(short_name, &sense)
    Class.new do
      define_singleton_method(:name) { "System::Fleet::Sensors::#{short_name}" }
      define_method(:initialize) { |account:| @account = account }
      define_method(:sense, &sense)
    end
  end

  def last_tick_complete
    System::FleetEvent.where(account: account, kind: "fleet.tick_complete").order(emitted_at: :desc).first
  end

  it "names a sensor that raised" do
    stub_const("#{described_class}::SENSORS", [ sensor("HoneypotAccessSensor") { raise "boom" }, sensor("QuietSensor") { [] } ])
    allow(Rails.logger).to receive(:error)

    service.tick!

    expect(last_tick_complete).to be_present
    expect(last_tick_complete.payload["failed_sensors"]).to eq([ "HoneypotAccessSensor" ])
  end

  it "carries an empty list when every sensor ran, so an absent key is never read as success" do
    stub_const("#{described_class}::SENSORS", [ sensor("QuietSensor") { [] } ])

    service.tick!

    expect(last_tick_complete.payload).to have_key("failed_sensors")
    expect(last_tick_complete.payload["failed_sensors"]).to eq([])
  end
end
