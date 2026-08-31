# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::ModulePromotionBacklogSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:sensor)   { described_class.new(account: account) }

  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform, name: "hub-backend")
  end

  # A version the fleet could actually run: published erofs artifact with a
  # recorded digest and a size clearing the publish floor.
  def usable_version(number:, created_at: 3.hours.ago, digest: "sha256:#{number}beef")
    create(:system_node_module_version,
           node_module: node_module,
           version_number: number,
           artifacts: { "erofs" => { "oci_digest" => digest, "size" => 32_768 } },
           created_at: created_at)
  end

  def make_current(version)
    node_module.update_columns(current_version_id: version.id,
                               current_version_number: version.version_number)
    node_module.reload
  end

  describe "#sense" do
    it "is silent when the newest usable version is already current" do
      make_current(usable_version(number: 5))

      expect(sensor.sense).to eq([])
    end

    it "is silent when a newer version exists but is still inside the lag budget" do
      make_current(usable_version(number: 5))
      usable_version(number: 6, created_at: 2.minutes.ago)

      expect(sensor.sense).to eq([])
    end

    it "alarms when a newer usable version has been waiting past the lag budget" do
      make_current(usable_version(number: 5))
      candidate = usable_version(number: 6, created_at: 3.hours.ago)

      signals = sensor.sense

      expect(signals.size).to eq(1)
      expect(signals.first.kind).to eq("system.module_promotion_stalled")
      expect(signals.first.severity).to eq(:high)
      expect(signals.first.payload["candidate_version_id"]).to eq(candidate.id)
      expect(signals.first.payload["current_version_number"]).to eq(5)
    end

    # THE CORE PROPERTY. The 2026-08-25 stall emitted withheld events, then
    # stopped emitting them, and still never promoted. A detector keyed on
    # event absence stays silent through exactly that. This asserts the alarm
    # is derived from STATE, so it fires with or without a decline event.
    context "convergence is asserted from state, not from events" do
      it "alarms even when NO withheld event was ever emitted" do
        make_current(usable_version(number: 5))
        usable_version(number: 6, created_at: 3.hours.ago)

        expect(::System::FleetEvent.where(kind: "system.module_promotion_withheld")).to be_empty
        expect(sensor.sense.size).to eq(1)
      end

      it "still alarms when a withheld event EXISTS, carrying it only as annotation" do
        make_current(usable_version(number: 5))
        candidate = usable_version(number: 6, created_at: 3.hours.ago)
        create(:system_fleet_event,
               account: account,
               kind: "system.module_promotion_withheld",
               node_module_version_id: candidate.id,
               payload: { "reason" => "core-source provenance mismatch" })

        signals = sensor.sense

        expect(signals.size).to eq(1)
        expect(signals.first.payload["last_withheld_reason"]).to eq("core-source provenance mismatch")
      end
    end

    # promotion_state is a SEPARATE, non-actuating track. A version at
    # ladder-"live" that is not current_version_id is still a stall, and a
    # version that IS current is not a stall however its ladder row reads.
    context "actuation is current_version_id, never promotion_state" do
      it "alarms for a candidate already marked promotion_state live" do
        make_current(usable_version(number: 5))
        candidate = usable_version(number: 6, created_at: 3.hours.ago)
        candidate.update_columns(promotion_state: "live")

        expect(sensor.sense.size).to eq(1)
      end

      it "stays silent for a current version whose ladder row still says built" do
        current = usable_version(number: 5)
        current.update_columns(promotion_state: "built")
        make_current(current)

        expect(sensor.sense).to eq([])
      end
    end

    context "admission of the candidate" do
      it "ignores a newer version with no recorded digest" do
        make_current(usable_version(number: 5))
        create(:system_node_module_version,
               node_module: node_module, version_number: 6,
               artifacts: { "erofs" => { "size" => 32_768 } }, created_at: 3.hours.ago)

        expect(sensor.sense).to eq([])
      end

      it "ignores a newer version below the artifact size floor" do
        make_current(usable_version(number: 5))
        create(:system_node_module_version,
               node_module: node_module, version_number: 6,
               artifacts: { "erofs" => { "oci_digest" => "sha256:tiny", "size" => 4_096 } },
               created_at: 3.hours.ago)

        expect(sensor.sense).to eq([])
      end

      it "reports the NEWEST usable candidate, not merely the next one" do
        make_current(usable_version(number: 5))
        usable_version(number: 6, created_at: 3.hours.ago)
        newest = usable_version(number: 7, created_at: 3.hours.ago)

        expect(sensor.sense.first.payload["candidate_version_number"]).to eq(7)
        expect(sensor.sense.first.payload["candidate_version_id"]).to eq(newest.id)
      end

      it "alarms for a module that has never been promoted at all" do
        usable_version(number: 1, created_at: 3.hours.ago)

        signals = sensor.sense

        expect(signals.size).to eq(1)
        expect(signals.first.payload["current_version_id"]).to be_nil
      end
    end

    it "keys the fingerprint on the candidate so a newer build re-alarms" do
      make_current(usable_version(number: 5))
      six = usable_version(number: 6, created_at: 3.hours.ago)
      first = sensor.sense.first.fingerprint

      seven = usable_version(number: 7, created_at: 3.hours.ago)
      second = described_class.new(account: account).sense.first.fingerprint

      expect(first).to include(six.id)
      expect(second).to include(seven.id)
      expect(second).not_to eq(first)
    end

    it "does not leak across accounts" do
      make_current(usable_version(number: 5))
      usable_version(number: 6, created_at: 3.hours.ago)

      other = described_class.new(account: create(:account)).sense

      expect(other).to eq([])
    end
  end

  it "is registered in the fleet autonomy sensor list" do
    expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
  end
end
