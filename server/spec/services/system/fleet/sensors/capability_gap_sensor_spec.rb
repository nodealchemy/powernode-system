# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::CapabilityGapSensor do
  let(:account) { create(:account) }

  # Builds a module whose manifest declares `requires:` entries. manifest_yaml
  # is the only persisted record of what a module requires (unlike `provides`,
  # which is denormalized onto the capabilities column), so the sensor reads
  # it directly.
  def module_requiring(*requires, name: "consumer")
    create(:system_node_module,
           account: account,
           name: name,
           manifest_yaml: { "dependencies" => { "requires" => requires } }.to_yaml)
  end

  def module_providing(*capabilities, name: "provider", priority: 50)
    create(:system_node_module,
           account: account,
           name: name,
           priority: priority,
           capabilities: capabilities)
  end

  subject(:sensor) { described_class.new(account: account) }

  it "emits a signal for a capability no module on the account provides" do
    mod = module_requiring("capability:runtime.rust")

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.kind).to eq("system.capability_gap")
    expect(signals.first.payload).to include(
      "capability" => "runtime.rust",
      "module_id" => mod.id
    )
  end

  it "stays silent when a module provides the capability" do
    module_requiring("capability:runtime.go")
    module_providing("runtime.go")

    expect(sensor.sense).to be_empty
  end

  # The whole point of extracting CapabilityResolver: the sensor must call a
  # gap exactly what the importer would. A bare provider tag deliberately does
  # NOT satisfy a versioned constraint, so this must still register as a gap.
  it "agrees with the importer that a bare tag cannot satisfy a versioned constraint" do
    module_requiring("capability:runtime.go@>= 1.25")
    module_providing("runtime.go") # bare, unversioned

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.payload["constraint"]).to eq(">= 1.25")
  end

  it "is satisfied by a versioned provider that meets the constraint" do
    module_requiring("capability:runtime.go@>= 1.25")
    module_providing("runtime.go@1.25.0")

    expect(sensor.sense).to be_empty
  end

  it "ignores non-capability requirements, which resolve by name elsewhere" do
    module_requiring("powernode/some-module@1.0")

    expect(sensor.sense).to be_empty
  end

  # Fingerprints drive DecisionEngine dedup. Two gaps on one module must not
  # collapse into a single signal, and the same gap must be stable across
  # ticks or it re-fires forever.
  it "fingerprints per module-and-capability" do
    mod = module_requiring("capability:runtime.rust", "capability:runtime.zig")

    prints = sensor.sense.map(&:fingerprint)

    expect(prints.uniq.size).to eq(2)
    expect(prints).to all(include(mod.id))
    expect(sensor.sense.map(&:fingerprint)).to match_array(prints)
  end

  it "does not report a module as satisfying its own requirement" do
    create(:system_node_module,
           account: account,
           name: "self-referential",
           capabilities: ["runtime.go"],
           manifest_yaml: { "dependencies" => { "requires" => ["capability:runtime.go"] } }.to_yaml)

    expect(sensor.sense.size).to eq(1)
  end

  it "is scoped to the account and never sees another account's providers" do
    module_requiring("capability:runtime.go")
    create(:system_node_module, account: create(:account), capabilities: ["runtime.go"])

    expect(sensor.sense.size).to eq(1)
  end

  # A sensor runs every tick on the whole fleet. Malformed YAML on one module
  # must not take the sense pass down — a crashed sensor also breaks
  # RemediationValidator's absence scoring for every other signal it owns.
  it "survives a module with unparseable manifest_yaml" do
    create(:system_node_module, account: account, name: "broken", manifest_yaml: "\tnot: [valid")
    module_requiring("capability:runtime.rust")

    expect { sensor.sense }.not_to raise_error
    expect(sensor.sense.size).to eq(1)
  end

  it "ignores modules with no manifest at all" do
    create(:system_node_module, account: account, manifest_yaml: nil)

    expect(sensor.sense).to be_empty
  end

  # This repo has shipped a sensor that was never registered and therefore
  # never ran. An unregistered sensor is indistinguishable from a working one
  # that finds nothing, so the wiring gets its own assertion.
  it "is registered in FleetAutonomyService::SENSORS" do
    expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
  end
end
