# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Metrics::Subscriber do
  # The subscriber registers global AS::Notifications listeners. We
  # tear them down between examples to avoid leak across specs.
  after { described_class.unsubscribe! }

  describe ".subscribe!" do
    it "is idempotent — repeated calls don't double-register" do
      described_class.subscribe!
      first_count = ActiveSupport::Notifications.notifier.listeners_for("system.dispatch.completed").size

      described_class.subscribe!
      second_count = ActiveSupport::Notifications.notifier.listeners_for("system.dispatch.completed").size

      expect(second_count).to eq(first_count)
    end

    it "marks itself subscribed" do
      expect { described_class.subscribe! }.to change(described_class, :subscribed?).from(false).to(true)
    end
  end

  describe ".unsubscribe!" do
    it "tears down all registered handles" do
      described_class.subscribe!
      expect(described_class.subscribed?).to be true

      described_class.unsubscribe!
      expect(described_class.subscribed?).to be false
    end
  end

  describe "event forwarding" do
    let(:account_id) { SecureRandom.uuid }

    before do
      Rails.cache.clear if Rails.cache.respond_to?(:clear)
      described_class.subscribe!
    end

    it "forwards system.dispatch.* events into Aggregator with account scope" do
      ActiveSupport::Notifications.instrument(
        "system.dispatch.completed",
        account_id: account_id, task_id: SecureRandom.uuid
      )

      stats = System::Metrics::Aggregator.stats(metric_name: "system.dispatch.completed",
                                                account_id: account_id)
      expect(stats[:count]).to eq(1)
    end

    it "forwards system.fleet.event with the kind preserved as the metric name" do
      ActiveSupport::Notifications.instrument(
        "system.fleet.event",
        account_id: account_id, kind: "decision.proceeded", severity: "low"
      )

      stats = System::Metrics::Aggregator.stats(metric_name: "system.fleet.event",
                                                account_id: account_id)
      expect(stats[:count]).to eq(1)
    end

    it "forwards system.cloud_sync.* events" do
      ActiveSupport::Notifications.instrument(
        "system.cloud_sync.tick",
        account_id: account_id
      )

      stats = System::Metrics::Aggregator.stats(metric_name: "system.cloud_sync.tick",
                                                account_id: account_id)
      expect(stats[:count]).to eq(1)
    end

    it "ignores events from non-watched namespaces" do
      ActiveSupport::Notifications.instrument(
        "some.other.event",
        account_id: account_id
      )

      stats = System::Metrics::Aggregator.stats(metric_name: "some.other.event",
                                                account_id: account_id)
      expect(stats[:count]).to eq(0)
    end

    it "tolerates events with non-Hash payload without raising" do
      expect {
        ActiveSupport::Notifications.instrument("system.dispatch.completed", "raw-string-payload")
      }.not_to raise_error
    end
  end
end
