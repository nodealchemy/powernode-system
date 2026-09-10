# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Campaign 01a08c9b increment B4a — system_get_sensor_config derives its
# catalog from what sensors DECLARE, across both tunable stores.
#
# Before this, `configurable_sensors` selected on `default_thresholds.present?`
# alone. That is the SensorConfig store; five sensors use it. Eight more
# resolve their windows through the account ladder (Account#settings ->
# SiteSetting -> constant) and were absent from the verb entirely, so the only
# way to learn that `sdwan_service_health_flow_window_seconds` was settable was
# to read the sensor.
RSpec.describe Ai::Tools::SystemFleetTool, "sensor config derivation" do
  let(:account) { create(:account) }
  let(:admin)   { create(:user, :admin, account: account) }
  let(:tool)    { described_class.new(account: account, user: admin) }

  def run(action, **params)
    tool.execute(params: { action: action, **params }.with_indifferent_access)
  end

  def listed_sensors
    run("system_get_sensor_config")[:data][:sensors]
  end

  let(:registry) { System::Fleet::FleetAutonomyService::SENSORS }

  let(:account_ladder_sensors) do
    registry.select { |klass| klass.account_ladder_settings.present? }
  end

  let(:sensor_config_sensors) do
    registry.select { |klass| klass.default_thresholds.present? }
  end

  describe "both arms of the catalog" do
    it "lists a sensor that reads an account-ladder setting" do
      expect(account_ladder_sensors).to be_present

      names = listed_sensors.map { |entry| entry[:sensor] }

      expect(names).to include(*account_ladder_sensors.map(&:sensor_key))
      expect(names).to include("sdwan_service_health")
    end

    it "omits a sensor that reads no tunable setting at all" do
      untunable = registry.reject(&:configurable?)
      expect(untunable).to be_present

      names = listed_sensors.map { |entry| entry[:sensor] }

      expect(names).not_to include(*untunable.map(&:sensor_key))
      # Named so the arm cannot pass by the set being empty: ModuleDriftSensor
      # declares neither store and must stay out.
      expect(names).not_to include("module_drift")
    end

    it "lists exactly the sensors that declare something, and nothing else" do
      expected = (account_ladder_sensors + sensor_config_sensors).uniq.map(&:sensor_key)

      expect(listed_sensors.map { |entry| entry[:sensor] }).to match_array(expected)
    end
  end

  # The oracle that keeps the derivation honest.
  #
  # `account_ladder_settings` derives its keys from each sensor's DEFAULT_*
  # constants by convention (DEFAULT_FLOW_WINDOW_SECONDS -> flow_window_seconds).
  # A convention with no check is a silent-drift generator: a sensor that named
  # its constant one way and its setting suffix another would under-report, and
  # nothing at runtime would say so. This compares the derived key set against
  # the suffix literals the sensor's own source passes to its resolver.
  describe "the derived keys are the keys the sensors actually read" do
    # Every resolver shape in use. A new shape makes this fail with the list,
    # which is the intended outcome: extend it deliberately, do not let a
    # sensor's keys go unchecked.
    RESOLVER_PATTERNS = [
      /\#\{ACCOUNT_SETTING_PREFIX\}_([a-z0-9_]+)"/,
      /\b(?:setting_seconds|tuned)\(\s*"([a-z0-9_]+)"/,
      /resolved_account_ladder\([^)]*\)\["([a-z0-9_]+)"\]/
    ].freeze

    # Located through Ruby itself rather than a hand-built path: the previous
    # form hardcoded the parent-repo layout and the extension slug from inside
    # the extension, and raised (rather than failed) if either moved.
    def sensor_source_path(klass)
      Object.const_source_location(klass.name)&.first
    end

    def suffixes_read_by(klass)
      path = sensor_source_path(klass)
      raise "no source location for #{klass}" if path.blank?

      source = File.read(path)

      RESOLVER_PATTERNS.flat_map { |pattern| source.scan(pattern) }.flatten.uniq.sort
    end

    # THE oracle, extracted so both arms below run the same code the real
    # sensors run.
    def mismatches_for(classes)
      classes.filter_map do |klass|
        declared = klass.account_ladder_settings.keys.sort
        read     = suffixes_read_by(klass)
        next if declared == read

        "#{klass.sensor_key}: declares #{declared.inspect} but its source reads #{read.inspect} " \
          "(recognised resolver shapes: #{RESOLVER_PATTERNS.map(&:source).inspect})"
      end
    end

    it "matches, sensor by sensor" do
      expect(mismatches_for(account_ladder_sensors)).to eq([])
    end

    it "derives the key from the constant's NAME, not merely its presence" do
      stand_in = Class.new(System::Fleet::Sensors::BaseSensor) do
        const_set(:ACCOUNT_SETTING_PREFIX, "stand_in")
        const_set(:SETTING_PREFIX, "system.stand_in")
        const_set(:DEFAULT_WINDOW_SECONDS, 42)
      end

      expect(stand_in.account_ladder_settings.keys).to eq([ "window_seconds" ])
      expect(stand_in.account_ladder_settings["window_seconds"])
        .to include("account_setting" => "stand_in_window_seconds",
                    "site_setting" => "system.stand_in.window_seconds",
                    "default" => 42)
    end

    # THE RED ARM of the mismatch loop above. Without it, a suffixes_read_by
    # that silently returned the declared set — or [] against an empty declared
    # set — would pass, and the loop would be a check that cannot fail.
    it "reports a sensor whose declared key and source literal disagree" do
      Dir.mktmpdir do |dir|
        source = File.join(dir, "drifted_sensor.rb")
        # Constant says `window_seconds`; the resolver reads `windows_seconds`.
        # Exactly the drift the convention has no runtime defence against.
        File.write(source, <<~RUBY)
          DEFAULT_WINDOW_SECONDS = 42
          def window_seconds = setting_seconds("windows_seconds", DEFAULT_WINDOW_SECONDS)
        RUBY

        drifted = Class.new(System::Fleet::Sensors::BaseSensor) do
          const_set(:ACCOUNT_SETTING_PREFIX, "drifted")
          const_set(:DEFAULT_WINDOW_SECONDS, 42)
        end
        stub_const("System::Fleet::Sensors::DriftedSensor", drifted)
        allow(self).to receive(:sensor_source_path).with(drifted).and_return(source)

        mismatches = mismatches_for([ drifted ])

        expect(mismatches.size).to eq(1)
        expect(mismatches.first).to include("declares [\"window_seconds\"]")
        expect(mismatches.first).to include("source reads [\"windows_seconds\"]")
      end
    end

    it "reports nothing for a sensor whose declared key and source literal agree" do
      Dir.mktmpdir do |dir|
        source = File.join(dir, "aligned_sensor.rb")
        File.write(source, <<~RUBY)
          DEFAULT_WINDOW_SECONDS = 42
          def window_seconds = setting_seconds("window_seconds", DEFAULT_WINDOW_SECONDS)
        RUBY

        aligned = Class.new(System::Fleet::Sensors::BaseSensor) do
          const_set(:ACCOUNT_SETTING_PREFIX, "aligned")
          const_set(:DEFAULT_WINDOW_SECONDS, 42)
        end
        stub_const("System::Fleet::Sensors::AlignedSensor", aligned)
        allow(self).to receive(:sensor_source_path).with(aligned).and_return(source)

        expect(mismatches_for([ aligned ])).to eq([])
      end
    end

    it "returns nothing for a sensor with no ladder prefix" do
      bare = Class.new(System::Fleet::Sensors::BaseSensor) do
        const_set(:DEFAULT_WINDOW_SECONDS, 42)
      end

      expect(bare.account_ladder_settings).to eq({})
      expect(bare.configurable?).to be(false)
    end
  end

  describe "the reported effective value walks the real ladder" do
    let(:klass) { System::Fleet::Sensors::SdwanServiceHealthSensor }

    def reported
      run("system_get_sensor_config", sensor: klass.sensor_key)[:data][:sensors]
        .first[:account_ladder_effective]["flow_window_seconds"]
    end

    it "falls back to the constant when nothing is configured" do
      expect(reported).to eq(klass::DEFAULT_FLOW_WINDOW_SECONDS)
    end

    it "reads the deployment-wide SiteSetting when the account has none" do
      SiteSetting.set("#{klass::SETTING_PREFIX}.flow_window_seconds", "1800", setting_type: "integer")

      expect(reported).to eq(1800)
    end

    it "prefers the account's own setting over the SiteSetting" do
      SiteSetting.set("#{klass::SETTING_PREFIX}.flow_window_seconds", "1800", setting_type: "integer")
      account.update!(settings: { "#{klass::ACCOUNT_SETTING_PREFIX}_flow_window_seconds" => 60 })

      expect(reported).to eq(60)
      # The value the SENSOR uses, not just the one the verb prints — a report
      # that agreed with itself and not with the sensor would be the defect.
      expect(klass.new(account: account).flow_window_seconds).to eq(60)
    end

    it "treats a non-positive configured value as unset, not as zero" do
      account.update!(settings: { "#{klass::ACCOUNT_SETTING_PREFIX}_flow_window_seconds" => 0 })

      expect(reported).to eq(klass::DEFAULT_FLOW_WINDOW_SECONDS)
    end
  end

  describe "declared bounds are applied and reported identically" do
    let(:klass) { System::Fleet::Sensors::DiskImagePublicationFailureStreakSensor }

    it "clamps an over-range value in both the report and the sensor" do
      account.update!(settings: { "disk_image_failure_streak_threshold" => 40 })

      reported = run("system_get_sensor_config", sensor: klass.sensor_key)[:data][:sensors]
                   .first[:account_ladder_effective]["threshold"]

      expect(reported).to eq(20)
      expect(klass.new(account: account).send(:streak_threshold)).to eq(20)
    end

    it "keeps the stored key an operator already uses" do
      expect(klass.account_ladder_settings["threshold"]["account_setting"])
        .to eq("disk_image_failure_streak_threshold")
    end

    # THE ONE BEHAVIOUR CHANGE this increment makes, asserted in both
    # directions because it moves the sensor's sensitivity DOWN (a stored 0
    # used to clamp up to 1 and alarm on the first failed publication; it now
    # reads as unset and needs three). The direction that hides a problem is
    # the direction that has to be pinned.
    it "treats a stored 0 as unset, not as a clamp up to 1" do
      account.update!(settings: { "disk_image_failure_streak_threshold" => 0 })

      expect(klass.new(account: account).send(:streak_threshold)).to eq(klass::DEFAULT_THRESHOLD)
      expect(klass::DEFAULT_THRESHOLD).to eq(3)
    end

    it "treats a negative and a non-numeric stored value the same way" do
      [ -5, "not a number" ].each do |stored|
        account.update!(settings: { "disk_image_failure_streak_threshold" => stored })

        expect(klass.new(account: account).send(:streak_threshold))
          .to eq(klass::DEFAULT_THRESHOLD), "stored #{stored.inspect} did not read as unset"
      end
    end

    it "still honours a legitimate in-range value" do
      # The other arm: "unset" must not swallow a real tuning.
      account.update!(settings: { "disk_image_failure_streak_threshold" => 7 })

      expect(klass.new(account: account).send(:streak_threshold)).to eq(7)
    end
  end

  # F12 — a sensor that DECLARES bounds but resolves privately would make the
  # read verb report a clamped value the sensor does not use, which is exactly
  # the lie the declared-bounds design exists to prevent. Today only one sensor
  # declares bounds; this keeps the next one honest.
  describe "declared bounds are only declared by sensors that resolve through the shared seam" do
    it "holds for every sensor declaring ACCOUNT_LADDER_BOUNDS" do
      offenders = registry.select { |klass| klass.account_ladder_bounds.present? }.reject do |klass|
        path = Object.const_source_location(klass.name)&.first
        path.present? && File.read(path).include?("resolved_account_ladder")
      end

      expect(offenders.map(&:sensor_key)).to eq([])
    end

    it "finds at least one sensor declaring bounds, so the check is not vacuous" do
      expect(registry.select { |klass| klass.account_ladder_bounds.present? }).to be_present
    end
  end

  describe "the write verb agrees with what the read verb calls writable" do
    it "accepts every sensor the read reports as writable" do
      writable = listed_sensors.select { |entry| entry[:writable] }

      expect(writable).to be_present
      writable.each do |entry|
        key = entry[:defaults].keys.first
        result = run("system_update_sensor_config", sensor: entry[:sensor], config: { key => nil })

        expect(result[:success]).to be(true), "#{entry[:sensor]} listed writable but refused: #{result[:error]}"
      end
    end

    it "refuses every sensor the read reports as not writable, naming where the key does live" do
      unwritable = listed_sensors.reject { |entry| entry[:writable] }

      expect(unwritable).to be_present
      unwritable.each do |entry|
        key = entry[:account_ladder].keys.first
        result = run("system_update_sensor_config", sensor: entry[:sensor], config: { key => 900 })

        expect(result[:success]).to be(false), "#{entry[:sensor]} listed unwritable but accepted a write"
        expect(result[:error]).to include(entry[:account_ladder][key]["account_setting"])
      end
    end

    it "stores nothing for a refused account-ladder write" do
      run("system_update_sensor_config",
          sensor: "sdwan_service_health", config: { "flow_window_seconds" => 60 })

      expect(System::Fleet::SensorConfig.where(account_id: account.id).count).to eq(0)
      expect(account.reload.settings.to_h).not_to include("sdwan_service_health_flow_window_seconds")
    end
  end

  describe "annotations stay correct" do
    it "keeps the read non-mutating and the write mutating" do
      expect(described_class.declared_action("system_get_sensor_config")[:mutating]).to be(false)
      expect(described_class.declared_action("system_update_sensor_config")[:mutating]).to be(true)
    end

    it "describes both stores in the read's published schema" do
      description = described_class.action_definitions["system_get_sensor_config"][:description]

      expect(description).to match(/account ladder/i)
      expect(description).to match(/writable/i)
    end
  end
end
