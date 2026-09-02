# frozen_string_literal: true

require "rails_helper"

# IMP-ca485128072e (APO-2e) — docs/FLEET_SENSORS.md has documented
# system_get_sensor_config / system_update_sensor_config since the sensor
# section was written, and both were catalogued ASPIRATIONAL: no verb, no
# registry entry, no model behind them. This file pins the pair as REAL MCP
# surface, which is what retires the two ASPIRATIONAL_VERBS entries.
RSpec.describe Ai::Tools::SystemFleetTool, "sensor config actions" do
  let(:account) { create(:account) }
  let(:admin)   { create(:user, :admin, account: account) }
  let(:tool)    { described_class.new(account: account, user: admin) }

  def run(action, **params)
    tool.execute(params: { action: action, **params }.with_indifferent_access)
  end

  describe "registration" do
    it "routes both verbs to SystemFleetTool in the core registry" do
      expect(Ai::Tools::PlatformApiToolRegistry.all_tools["system_get_sensor_config"])
        .to eq("Ai::Tools::SystemFleetTool")
      expect(Ai::Tools::PlatformApiToolRegistry.all_tools["system_update_sensor_config"])
        .to eq("Ai::Tools::SystemFleetTool")
    end

    it "declares the read as non-mutating and the write as mutating" do
      expect(described_class.declared_action("system_get_sensor_config")[:mutating]).to be(false)
      expect(described_class.declared_action("system_update_sensor_config")[:mutating]).to be(true)
    end

    it "publishes an action_definition for each (an MCP client needs the schema)" do
      expect(described_class.action_definitions["system_get_sensor_config"]).to be_present
      expect(described_class.action_definitions["system_update_sensor_config"]).to be_present
    end
  end

  describe "system_get_sensor_config" do
    it "reports defaults, overrides and the effective values for one sensor" do
      result = run("system_get_sensor_config", sensor: "instance_status")
      expect(result[:success]).to be(true)

      entry = result[:data][:sensors].first
      expect(entry[:sensor]).to eq("instance_status")
      expect(entry[:defaults]).to include("silent_threshold_seconds")
      expect(entry[:overrides]).to eq({})
      expect(entry[:effective]["silent_threshold_seconds"])
        .to eq(System::Fleet::Sensors::InstanceStatusSensor::SILENT_THRESHOLD.to_i)
    end

    it "lists every configurable sensor when none is named" do
      result = run("system_get_sensor_config")
      names = result[:data][:sensors].map { |s| s[:sensor] }
      expect(names).to include("instance_status", "instance_unrecoverable")
    end

    it "errors on a sensor the platform does not run" do
      result = run("system_get_sensor_config", sensor: "no_such_sensor")
      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/unknown sensor/i)
    end
  end

  describe "system_update_sensor_config" do
    it "persists an override and reports the new effective value" do
      result = run("system_update_sensor_config",
                   sensor: "instance_status", config: { "silent_threshold_seconds" => 600 })

      expect(result[:success]).to be(true)
      expect(result[:data][:sensor][:effective]["silent_threshold_seconds"]).to eq(600)
      expect(
        System::Fleet::Sensors::InstanceStatusSensor
          .resolved_threshold("silent_threshold_seconds", account: account)
      ).to eq(600)
    end

    it "rejects a key the sensor does not declare instead of storing dead config" do
      result = run("system_update_sensor_config",
                   sensor: "instance_status", config: { "silent_threshold_minutes" => 10 })

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/silent_threshold_minutes/)
      expect(System::Fleet::SensorConfig.where(account_id: account.id).count).to eq(0)
    end

    it "rejects a non-positive value instead of storing a threshold that disables the sensor" do
      result = run("system_update_sensor_config",
                   sensor: "instance_unrecoverable", config: { "max_per_tick" => 0 })

      expect(result[:success]).to be(false)
      expect(System::Fleet::SensorConfig.where(account_id: account.id).count).to eq(0)
    end

    # Review finding (major): the writer delegates its "is this usable?"
    # question to SensorConfig.coerce_threshold, so a hole there is a hole
    # here. 0.5 passed the first cut (`0.5.positive?` is true) and stored as a
    # value the resolver used as 0 — `.limit(0)`, i.e. the detector stops. The
    # integer-0 case above does not cover it.
    it "rejects a fractional value the resolver could only use as zero" do
      result = run("system_update_sensor_config",
                   sensor: "instance_unrecoverable", config: { "max_per_tick" => 0.5 })

      expect(result[:success]).to be(false)
      expect(result[:error].to_s).to match(/max_per_tick/)
      expect(System::Fleet::SensorConfig.where(account_id: account.id).count).to eq(0)
    end

    it "requires a config object" do
      expect(run("system_update_sensor_config", sensor: "instance_status")[:success]).to be(false)
    end
  end

  # The read-only twin of the sensor. Its description claims it is "aligned
  # with InstanceStatusSensor"; before IMP-ca485128072e it defaulted to a BARE
  # LITERAL 180, which agreed with the constant by coincidence and would have
  # diverged from every tuned account the moment thresholds became settable.
  describe "system_get_silent_instances tracks the configured threshold" do
    it "defaults to the account's resolved silent threshold, not a literal" do
      run("system_update_sensor_config",
          sensor: "instance_status", config: { "silent_threshold_seconds" => 600 })

      result = run("system_get_silent_instances")
      expect(result[:data][:threshold_seconds]).to eq(600)
    end

    it "still honours an explicit per-call override" do
      result = run("system_get_silent_instances", threshold_seconds: 45)
      expect(result[:data][:threshold_seconds]).to eq(45)
    end
  end

  describe "permissions" do
    let(:nobody) { create(:user, account: account, permissions: []) }

    it "gates the read on system.fleet.read and the write on system.fleet.manage" do
      expect(described_class::ACTION_PERMISSIONS["system_get_sensor_config"]).to eq("system.fleet.read")
      expect(described_class::ACTION_PERMISSIONS["system_update_sensor_config"]).to eq("system.fleet.manage")
    end

    it "refuses a principal holding neither" do
      result = described_class.new(account: account, user: nobody)
                              .execute(params: { action: "system_get_sensor_config" }.with_indifferent_access)
      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/permission denied/i)
    end
  end
end
