# frozen_string_literal: true

require "rails_helper"

# IMP-a294e9db40ea — a stuck streak pinned for the life of its fingerprint.
#
# DecisionEngine#decide returns before the gate once a fingerprint's ineffective
# streak reaches the threshold, and only a proceeded decision records an
# outcome, so nothing could ever write the `effective` row that lifts it. For
# the kinds the engine can safely retry the streak now counts only outcomes
# inside RemediationOutcome::STUCK_STREAK_WINDOW. This pins the shared
# definition (.stuck_streak) and that every surface reporting "stuck" uses it.
RSpec.describe System::Fleet::RemediationOutcome, ".stuck_streak" do
  let(:account) { create(:account) }
  let(:window) { described_class::STUCK_STREAK_WINDOW.seconds }
  let(:threshold) { System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD }

  def outcome!(fingerprint, status, validated_ago:, kind: "system.config_drift")
    described_class.create!(
      account: account, signal_kind: kind, fingerprint: fingerprint, status: status,
      acted_at: Time.current - validated_ago - 15.minutes, settle_until: Time.current - validated_ago - 5.minutes,
      validated_at: Time.current - validated_ago
    )
  end

  def ineffective!(fingerprint, count, ago:, kind: "system.config_drift")
    count.times { |i| outcome!(fingerprint, "ineffective", validated_ago: ago + i.minutes, kind: kind) }
  end

  it "is the windowed count for a retryable kind and ignores outcomes older than the window" do
    ineffective!("config_drift:w-1", threshold, ago: window + 1.hour)

    expect(described_class.stuck_streak(account: account, fingerprint: "config_drift:w-1")).to eq(0)
    expect(described_class.ineffective_streak(account: account, fingerprint: "config_drift:w-1")).to eq(threshold)
  end

  it "counts the rows inside the window and stops at the window edge" do
    ineffective!("config_drift:w-2", 2, ago: 1.hour)
    ineffective!("config_drift:w-2", 5, ago: window + 2.hours)

    expect(described_class.stuck_streak(account: account, fingerprint: "config_drift:w-2")).to eq(2)
  end

  it "does not let an effective row older than the window mask recent failures" do
    outcome!("config_drift:w-3", "effective", validated_ago: window + 3.hours)
    ineffective!("config_drift:w-3", threshold, ago: 1.hour)

    expect(described_class.stuck_streak(account: account, fingerprint: "config_drift:w-3")).to eq(threshold)
  end

  it "stays the lifetime count for a kind the engine does not retry" do
    ineffective!("instance_silent:i-1", threshold, ago: window + 30.days, kind: "system.instance_silent")

    expect(described_class.stuck_streak(account: account, fingerprint: "instance_silent:i-1")).to eq(threshold)
  end

  it "finds the kind from the fingerprint's newest outcome when the caller has none" do
    ineffective!("config_drift:w-4", threshold, ago: window + 1.hour)

    expect(described_class.stuck_streak(account: account, fingerprint: "config_drift:w-4", signal_kind: nil)).to eq(0)
    expect(described_class.stuck_streak(account: account, fingerprint: "config_drift:w-4",
                                        signal_kind: "system.instance_silent")).to eq(threshold)
  end

  it "ships a window that cannot be configured to zero" do
    expect(described_class::STUCK_STREAK_WINDOW).to be >= 1.hour.to_i
  end

  describe "the surfaces that report stuck agree with the engine" do
    it "lists an aged-out streak as not stuck, and a current one as stuck" do
      ineffective!("config_drift:old", threshold, ago: window + 1.hour)
      ineffective!("config_drift:new", threshold, ago: 1.hour)

      listed = System::Fleet::RemediationOutcomeSummary.call(account: account, window_days: 90)[:stuck][:fingerprints]
                                                       .map { |f| f[:fingerprint] }

      expect(listed).to eq([ "config_drift:new" ])
    end

    it "gives the component-status source the same answer" do
      ineffective!("config_drift:old", threshold, ago: window + 1.hour)
      ineffective!("config_drift:new", threshold, ago: 1.hour)
      source = System::Status::FleetSignalSource.new

      expect(source.send(:stuck?, account, "config_drift:old")).to be false
      expect(source.send(:stuck?, account, "config_drift:new")).to be true
    end
  end

  it "leaves InstanceUnrecoverableSensor's reboot-exhaustion read on the lifetime count" do
    source = Rails.root.join("..", "extensions", "system", "server", "app", "services", "system", "fleet",
                             "sensors", "instance_unrecoverable_sensor.rb")
    skip "extension source not at the expected path" unless source.exist?

    expect(source.read).to include("ineffective_streak(").and(satisfy { |text| !text.include?("stuck_streak(") })
  end
end
