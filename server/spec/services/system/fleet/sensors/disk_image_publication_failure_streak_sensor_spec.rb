# frozen_string_literal: true

require "rails_helper"

# DK3 of the disk-image-CI restoration. Pure read-side sensor: a platform's
# most-recent N (non-retired/non-purged) publications ALL failed → signal.
RSpec.describe System::Fleet::Sensors::DiskImagePublicationFailureStreakSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:sensor)   { described_class.new(account: account) }

  def publication!(status:, days_ago:)
    create(:system_disk_image_publication, status: status,
           account: account, node_platform: platform).tap do |pub|
      pub.update_columns(created_at: days_ago.days.ago)
    end
  end

  it "emits a failure_streak signal when the most recent 3 (default threshold) all failed" do
    publication!(status: "failed", days_ago: 3)
    publication!(status: "failed", days_ago: 2)
    newest = publication!(status: "failed", days_ago: 1)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    s = signals.first
    expect(s.kind).to eq("system.disk_image_publication_failure_streak")
    expect(s.severity).to eq(:high)
    expect(s.payload["node_platform_id"]).to eq(platform.id)
    expect(s.payload["consecutive_failures"]).to eq(3)
    expect(s.payload["last_publication_id"]).to eq(newest.id)
    expect(s.fingerprint).to eq("disk_image_failure_streak:#{platform.id}")
  end

  it "does not emit when fewer than the threshold publications exist" do
    publication!(status: "failed", days_ago: 2)
    publication!(status: "failed", days_ago: 1)

    expect(sensor.sense).to be_empty
  end

  it "does not emit when a published build breaks the streak" do
    publication!(status: "failed", days_ago: 3)
    publication!(status: "published", days_ago: 2)
    publication!(status: "failed", days_ago: 1)

    expect(sensor.sense).to be_empty
  end

  it "excludes retired/purged rows from the recent window instead of treating them as a break" do
    publication!(status: "failed", days_ago: 5)   # falls into the top-3 once retired is skipped
    publication!(status: "retired", days_ago: 4)   # excluded — neither counted nor a streak-breaker
    publication!(status: "failed", days_ago: 3)
    publication!(status: "failed", days_ago: 2)
    newest = publication!(status: "failed", days_ago: 1)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.payload["consecutive_failures"]).to eq(3)
    expect(signals.first.payload["last_publication_id"]).to eq(newest.id)
  end

  it "does not emit for a platform with no failures" do
    publication!(status: "published", days_ago: 1)

    expect(sensor.sense).to be_empty
  end

  it "respects a configurable threshold from Account#settings" do
    account.update!(settings: { "disk_image_failure_streak_threshold" => 2 })
    publication!(status: "failed", days_ago: 2)
    publication!(status: "failed", days_ago: 1)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.payload["consecutive_failures"]).to eq(2)
  end
end

# The other half of DK3: the sensor must actually run in the tick and route
# somewhere instead of being silently dropped as :skipped.
RSpec.describe "DK3 disk-image failure-streak sensor wiring" do
  it "registers the sensor in FleetAutonomyService::SENSORS" do
    expect(System::Fleet::FleetAutonomyService::SENSORS).to include(
      System::Fleet::Sensors::DiskImagePublicationFailureStreakSensor
    )
  end

  it "binds the signal kind to the disk_image_publication_investigate gate" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.disk_image_publication_failure_streak"]

    expect(binding).to be_present
    expect(binding[:action_category]).to eq("system.disk_image_publication_investigate")
  end
end
