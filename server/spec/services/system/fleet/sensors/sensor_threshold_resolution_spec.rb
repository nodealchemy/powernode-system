# frozen_string_literal: true

require "rails_helper"

# IMP-ca485128072e (APO-2e) — fleet sensor thresholds are OPERATOR CONFIGURATION.
#
# Before this change every sensor threshold was a class constant, and the APO-2b
# sensor had added ENV overrides on top (FLEET_UNRECOVERABLE_MAX_PER_TICK and
# two siblings). Neither is operator-settable: a constant needs a redeploy, and
# an ENV var needs a redeploy AND a systemd unit edit on every node running the
# reconciler — while docs/FLEET_SENSORS.md documented a `Fleet::SensorConfig`
# row and a pair of MCP verbs, none of which existed.
#
# This file pins the seam that replaces both: ONE resolution path on BaseSensor,
# DB-backed (System::Fleet::SensorConfig), falling back to the class constant
# when no row exists or the stored value is unusable.
RSpec.describe "Fleet sensor threshold resolution", type: :service do
  let(:account) { create(:account) }

  status_sensor       = System::Fleet::Sensors::InstanceStatusSensor
  unrecoverable_sensor = System::Fleet::Sensors::InstanceUnrecoverableSensor

  # A LOCAL, not a constant: a constant assigned inside a describe block lands
  # at top level and can be clobbered by another spec file in the same run.
  sensor_source_dir = File.expand_path(
    "../../../../../app/services/system/fleet/sensors", __dir__
  )

  describe "System::Fleet::SensorConfig" do
    it "is a real, account-scoped model (the docs named it long before it existed)" do
      expect(defined?(System::Fleet::SensorConfig)).to eq("constant")
      expect(System::Fleet::SensorConfig.table_name).to eq("system_fleet_sensor_configs")
    end

    it "upserts by [account, sensor] rather than accumulating rows" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 600 }
      )
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 900 }
      )

      rows = System::Fleet::SensorConfig.where(account_id: account.id, sensor: "instance_status")
      expect(rows.count).to eq(1)
      expect(rows.first.config["silent_threshold_seconds"]).to eq(900)
    end

    it "merges partial updates rather than replacing the whole config" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_unrecoverable",
        config: { "max_per_tick" => 5, "emit_window_seconds" => 60 }
      )
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_unrecoverable", config: { "max_per_tick" => 7 }
      )

      cfg = System::Fleet::SensorConfig.config_for(account: account, sensor: "instance_unrecoverable")
      expect(cfg).to include("max_per_tick" => 7, "emit_window_seconds" => 60)
    end
  end

  describe "the BaseSensor resolution seam" do
    it "derives a stable sensor key from the class name" do
      expect(status_sensor.sensor_key).to eq("instance_status")
      expect(unrecoverable_sensor.sensor_key).to eq("instance_unrecoverable")
    end

    it "publishes the tunable keys with their constant defaults" do
      expect(status_sensor.default_thresholds).to eq(
        "silent_threshold_seconds" => status_sensor::SILENT_THRESHOLD.to_i
      )
      expect(unrecoverable_sensor.default_thresholds).to eq(
        "max_per_tick" => unrecoverable_sensor::MAX_PER_TICK,
        "emit_window_seconds" => unrecoverable_sensor::EMIT_WINDOW_SECONDS,
        "reboot_attempt_threshold" => unrecoverable_sensor::REBOOT_ATTEMPT_THRESHOLD,
        # Campaign 01a07025 / app-2 — the ephemeral-pool reap lane's grace
        # window, registered on the SAME seam rather than as a fifth
        # mechanism, so `platform.system_get_sensor_config` lists it.
        "ephemeral_error_grace_seconds" => unrecoverable_sensor::EPHEMERAL_ERROR_GRACE_SECONDS
      )
    end

    it "falls back to the class constant when no row exists" do
      expect(status_sensor.resolved_threshold("silent_threshold_seconds", account: account))
        .to eq(status_sensor::SILENT_THRESHOLD.to_i)
    end

    it "prefers a stored override" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 600 }
      )
      expect(status_sensor.resolved_threshold("silent_threshold_seconds", account: account)).to eq(600)
    end

    it "falls back to the constant on an unusable stored value (fail closed, never crash a tick)" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_unrecoverable",
        config: { "max_per_tick" => "not-a-number", "emit_window_seconds" => 0 }
      )
      expect(unrecoverable_sensor.resolved_threshold("max_per_tick", account: account))
        .to eq(unrecoverable_sensor::MAX_PER_TICK)
      expect(unrecoverable_sensor.resolved_threshold("emit_window_seconds", account: account))
        .to eq(unrecoverable_sensor::EMIT_WINDOW_SECONDS)
    end

    # Review finding (major): the first cut tested Float with `.positive?` and
    # then called `.to_i`, so 0.5 coerced to 0 — a value the model's own
    # comment says can never be stored. 0 is TRUTHY in Ruby, so
    # `coerce_threshold(stored) || fallback` returned it instead of falling
    # back, and `.limit(0)` / a `Time.current` cutoff followed. The
    # "not-a-number" and integer-0 cases above both survive that bug, which is
    # why this case is stated separately.
    it "treats a fractional Float as unusable rather than truncating it to zero" do
      expect(System::Fleet::SensorConfig.coerce_threshold(0.5)).to be_nil
      expect(System::Fleet::SensorConfig.coerce_threshold(0.9)).to be_nil
      expect(System::Fleet::SensorConfig.coerce_threshold(1.5)).to be_nil
      expect(System::Fleet::SensorConfig.coerce_threshold(Float::NAN)).to be_nil
      # An integral Float is how a JSON body can spell a whole number.
      expect(System::Fleet::SensorConfig.coerce_threshold(600.0)).to eq(600)

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_unrecoverable", config: { "max_per_tick" => 0.5 }
      )
      expect(unrecoverable_sensor.resolved_threshold("max_per_tick", account: account))
        .to eq(unrecoverable_sensor::MAX_PER_TICK)
      expect(unrecoverable_sensor.resolved_thresholds(account: account)["max_per_tick"])
        .to eq(unrecoverable_sensor::MAX_PER_TICK)
    end

    it "refuses a key the sensor does not declare (a typo must not read as a tuning)" do
      expect { status_sensor.resolved_threshold("no_such_key", account: account) }
        .to raise_error(KeyError)
    end

    it "keeps overrides account-scoped" do
      other = create(:account)
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 600 }
      )
      expect(status_sensor.resolved_threshold("silent_threshold_seconds", account: other))
        .to eq(status_sensor::SILENT_THRESHOLD.to_i)
    end
  end

  describe "InstanceUnrecoverableSensor's silent threshold" do
    # The sensor's own comment: it reads InstanceStatusSensor's threshold
    # "so the two sensors cannot disagree about which instances are silent".
    # A per-sensor override must not break that — the unrecoverable sensor
    # classifies exactly the population the status sensor calls silent.
    it "tracks the instance_status override, not an instance_unrecoverable one" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 600 }
      )
      sensor = unrecoverable_sensor.new(account: account)
      expect(sensor.send(:silent_threshold_seconds)).to eq(600)
    end
  end

  describe "behaviour: an operator raising the threshold silences the signal" do
    def silent_instance(age)
      create(:system_node_instance, :running, account: account, last_heartbeat_at: age.ago)
    end

    it "emits instance_silent at the constant default" do
      silent_instance(4.minutes)
      kinds = status_sensor.new(account: account).sense.map(&:kind)
      expect(kinds).to include("system.instance_silent")
    end

    it "stops emitting once the account's stored threshold exceeds the silence" do
      silent_instance(4.minutes)
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 3600 }
      )
      kinds = status_sensor.new(account: account).sense.map(&:kind)
      expect(kinds).not_to include("system.instance_silent")
    end

    it "reports the RESOLVED threshold in the signal payload, not the constant" do
      silent_instance(4.hours)
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status", config: { "silent_threshold_seconds" => 600 }
      )
      sig = status_sensor.new(account: account).sense.find { |s| s.kind == "system.instance_silent" }
      expect(sig.payload["threshold_seconds"]).to eq(600)
    end
  end

  # ENV is not operator configuration on this platform: the reconciler runs
  # inside a module-composed systemd unit, so an override needs a unit edit and
  # a redeploy on every node. Asserted against the FILE BYTES, because a
  # behaviour test cannot see a constant that merely still READS an ENV var.
  #
  # CODE lines only: a `#` comment naming the retired variable is the record of
  # what was removed and must stay readable. The check is still byte-level and
  # still region-scoped — restoring the read reddens it, because a restored
  # `MAX_PER_TICK = (ENV[...] || 25).to_i` is not a comment line.
  describe "no ENV-sourced thresholds remain in the fleet sensors tree" do
    offenders = Dir.glob(File.join(sensor_source_dir, "*.rb")).sort.select do |path|
      File.readlines(path).any? do |line|
        stripped = line.lstrip
        !stripped.start_with?("#") && stripped.match?(/ENV\s*\[/)
      end
    end

    it "reads no ENV var anywhere under app/services/system/fleet/sensors" do
      expect(offenders.map { |p| File.basename(p) }).to be_empty
    end

    it "swept a non-empty sensor corpus (anti-vacuity for the glob above)" do
      expect(Dir.glob(File.join(sensor_source_dir, "*.rb")).size).to be >= 20
    end
  end
end
