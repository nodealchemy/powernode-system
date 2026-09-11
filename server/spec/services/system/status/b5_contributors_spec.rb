# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b B5: the honeypot, dispatch_latency and
# remediation_effectiveness contributors, from the three fleet tiles' data.
#
# The increment's oracle: a feed that is down reads not_measured, never ok and
# never ok with a count of 0. Each contributor gets both arms, and every
# not_measured example below also asserts the counts are ABSENT, so a mutant
# that reads nil as 0 fails here instead of passing as a quiet, healthy reading.
RSpec.describe "B5 status contributors" do
  let(:account) { create(:account) }

  def conditions_of(contributor)
    record = nil
    contributor.each_component(account) { |r| record = r }
    contributor.conditions_for(record)
  end

  def condition(conditions, type) = conditions.find { |c| c["type"] == type }

  def verdict(conditions) = Platform::Status::Condition.verdict_for_set(conditions)

  def b5_kinds
    {
      "honeypot" => System::Status::Contributors::HoneypotContributor,
      "dispatch_latency" => System::Status::Contributors::DispatchLatencyContributor,
      "remediation_effectiveness" => System::Status::Contributors::RemediationEffectivenessContributor
    }
  end

  describe "the set as a whole" do
    it "is picked up by the registrar with no edit to it" do
      expect(System::Status::Contributors.kinds).to include(*b5_kinds.keys)
    end

    it "declares each KIND, account scoping, a string icon and no core escalation, with one component per account" do
      b5_kinds.each do |kind, klass|
        contributor = klass.new
        components = []
        contributor.each_component(account) { |r| components << r }

        expect(contributor.kind).to eq(kind)
        expect(contributor.account_scoped?).to be(true)
        expect(contributor.escalates?).to be(false)
        expect(contributor.presentation["icon"]).to be_a(String)
        expect(components.size).to eq(1)
      end
    end
  end

  # ── honeypot ──────────────────────────────────────────────────────────────
  describe System::Status::Contributors::HoneypotContributor do
    let(:contributor) { described_class.new }
    let(:feed) { described_class::FEED }
    let(:untouched) { described_class::UNTOUCHED }

    def tick!(at: 1.minute.ago, payload: { "failed_sensors" => [] })
      create(:system_fleet_event, account: account, kind: "fleet.tick_complete", emitted_at: at, payload: payload)
    end

    def access!(at:)
      create(:system_fleet_event, account: account, kind: "system.honeypot_triggered", emitted_at: at)
    end

    def store!(conditions)
      Platform::ComponentStatus.create!(
        account_id: account.id, component_kind: described_class::KIND, component_ref: described_class::REF,
        display_name: "Honeypot canary", conditions: conditions, verdict: verdict(conditions)
      )
    end

    def expect_counts_withheld(conditions)
      evidence = condition(conditions, untouched)["evidence"]
      expect(evidence).not_to include("count_24h", "count_7d")
      expect(evidence["counts_withheld"]).to be(true)
    end

    context "when the feed is down" do
      it "no fleet tick ever recorded: not_measured naming NoFleetTick, counts withheld — never ok with 0" do
        access!(at: 2.days.ago)

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, feed)["reason"]).to eq("NoFleetTick")
        expect_counts_withheld(result)
      end

      it "the newest tick is stale by the probe's own tick_staleness_seconds: not_measured naming FleetTickStale" do
        tick!(at: (System::Platform::CompositeHealthProbe::DEFAULT_TICK_STALENESS_SECONDS + 60).seconds.ago)

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, feed)["reason"]).to eq("FleetTickStale")
        expect(condition(result, feed)["evidence"]["staleness_threshold_seconds"])
          .to eq(System::Platform::CompositeHealthProbe::DEFAULT_TICK_STALENESS_SECONDS)
        expect_counts_withheld(result)
      end

      it "the newest tick reports HoneypotAccessSensor failed: not_measured naming HoneypotSensorFailed, even with access data present" do
        access!(at: 1.hour.ago)
        tick!(payload: { "failed_sensors" => [ "HoneypotAccessSensor" ] })

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, feed)["reason"]).to eq("HoneypotSensorFailed")
        expect_counts_withheld(result)
      end

      it "a tick that predates failed_sensors cannot say the sensor ran: not_measured naming SensorReportAbsent" do
        tick!(payload: { "signal_count" => 0 })

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, feed)["reason"]).to eq("SensorReportAbsent")
      end
    end

    context "when the feed is up" do
      before { tick! }

      it "no access: ok, with MEASURED zero counts" do
        result = conditions_of(contributor)

        expect(verdict(result)).to eq("ok")
        expect(condition(result, untouched)["evidence"]).to include("count_24h" => 0, "count_7d" => 0, "last_access_at" => nil)
      end

      it "an access within 7 days but not 24 hours: degraded, the tile's warning" do
        access!(at: 2.days.ago)

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("degraded")
        expect(condition(result, untouched)).to include("reason" => "AccessedWithin7d")
        expect(condition(result, untouched)["evidence"]).to include("count_24h" => 0, "count_7d" => 1)
      end

      it "an access within 24 hours: down, the tile's alert, with the last access time" do
        at = 1.hour.ago
        access!(at: at)

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("down")
        expect(condition(result, untouched)["evidence"]).to include("count_24h" => 1, "count_7d" => 1,
                                                                  "last_access_at" => at.iso8601)
      end
    end

    describe "the ratchet" do
      it "an outage never LOWERS an observed alert: a canary stored as tripped stays down, counts withheld" do
        tick!
        access!(at: 1.hour.ago)
        store!(conditions_of(contributor))
        System::FleetEvent.where(account: account, kind: "fleet.tick_complete").delete_all

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("down")
        expect(condition(result, untouched)).to include("reason" => "HeldFromLastObservation", "severity" => "down")
        expect_counts_withheld(result)
      end

      it "an outage after a clear reading is not_measured, never ok" do
        tick!
        store!(conditions_of(contributor))
        System::FleetEvent.where(account: account, kind: "fleet.tick_complete").delete_all

        expect(verdict(conditions_of(contributor))).to eq("not_measured")
      end

      it "unavailable_since keeps the START of the outage, from the stored transition time" do
        went_down = 3.hours.ago.iso8601
        stored = conditions_of(contributor).map do |c|
          c["type"] == feed ? c.merge("last_transition_at" => went_down) : c
        end
        store!(stored)

        result = conditions_of(contributor)

        expect(condition(result, feed)["evidence"]["unavailable_since"]).to eq(went_down)
      end
    end
  end

  # ── dispatch_latency ─────────────────────────────────────────────────────
  describe System::Status::Contributors::DispatchLatencyContributor do
    let(:contributor) { described_class.new }
    let(:failures) { described_class::FAILURES }

    before { Rails.cache.clear }

    def record!(name, times, owner: account)
      times.times { System::Metrics::Aggregator.record(metric_name: name, account_id: owner.id) }
    end

    it "a cache that fails the round trip: not_measured naming CacheUnavailable, counts withheld — never a quiet window" do
      allow(Rails.cache).to receive(:write).and_raise(StandardError, "connection refused")

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("not_measured")
      expect(condition(result, described_class::CACHE)["reason"]).to eq("CacheUnavailable")
      expect(condition(result, failures)["evidence"]).not_to include("counts", "failure_percent")
    end

    it "a cache that silently loses the write (reads back nothing): not_measured" do
      allow(Rails.cache).to receive(:read).and_return(nil)

      expect(verdict(conditions_of(contributor))).to eq("not_measured")
    end

    it "a working cache with no counters: a MEASURED quiet window, ok, with zero counts" do
      result = conditions_of(contributor)

      expect(verdict(result)).to eq("ok")
      expect(condition(result, failures)["reason"]).to eq("QuietWindow")
      expect(condition(result, failures)["evidence"]["counts"]).to include("system.dispatch.completed" => 0,
                                                                          "system.dispatch.failed" => 0)
    end

    it "failures above the tile's 5%: degraded, citing the threshold" do
      record!("system.dispatch.completed", 18)
      record!("system.dispatch.failed", 2)

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("degraded")
      expect(condition(result, failures)["evidence"]).to include("failure_percent" => 10.0, "threshold_percent" => 5)
    end

    it "exactly 5% is not above the tile's `> 5`: ok" do
      record!("system.dispatch.completed", 19)
      record!("system.dispatch.failed", 1)

      expect(verdict(conditions_of(contributor))).to eq("ok")
    end

    it "reads only this account's counters, as MetricsController#index does" do
      record!("system.dispatch.failed", 5, owner: create(:account))
      record!("system.dispatch.completed", 5)

      expect(verdict(conditions_of(contributor))).to eq("ok")
    end
  end

  # ── remediation_effectiveness ────────────────────────────────────────────
  describe System::Status::Contributors::RemediationEffectivenessContributor do
    let(:contributor) { described_class.new }
    let(:threshold) { System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD }

    def outcome!(status:, fingerprint: "fp-#{SecureRandom.hex(4)}", acted_at: 1.day.ago)
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.module_drift", fingerprint: fingerprint, status: status,
        acted_at: acted_at, settle_until: acted_at + 10.minutes,
        validated_at: status == "pending" ? nil : acted_at + 15.minutes
      )
    end

    it "nothing settled: not_measured naming NothingSettled, the rate nil — never 0%" do
      outcome!(status: "pending")

      result = conditions_of(contributor)
      effectiveness = condition(result, described_class::EFFECTIVENESS)

      expect(verdict(result)).to eq("not_measured")
      expect(effectiveness["reason"]).to eq("NothingSettled")
      expect(effectiveness["evidence"]["effectiveness_rate"]).to be_nil
    end

    it "settled outcomes: the measured rate, the same one the endpoint's summary computes" do
      3.times { outcome!(status: "effective") }
      outcome!(status: "ineffective")

      result = conditions_of(contributor)
      effectiveness = condition(result, described_class::EFFECTIVENESS)

      expect(verdict(result)).to eq("ok")
      expect(effectiveness["evidence"]["effectiveness_rate"]).to eq(0.75)
      expect(effectiveness["evidence"]["effectiveness_rate"])
        .to eq(System::Fleet::RemediationOutcomeSummary.call(account: account)[:totals][:effectiveness_rate])
    end

    it "a fingerprint at the engine's stuck streak: degraded, naming it" do
      threshold.times { |i| outcome!(status: "ineffective", fingerprint: "fp-stuck", acted_at: (2 + i).hours.ago) }

      result = conditions_of(contributor)
      stuck = condition(result, described_class::STUCK)

      expect(verdict(result)).to eq("degraded")
      expect(stuck["reason"]).to eq("RemediationStuck")
      expect(stuck["evidence"]["fingerprints"].map { |f| f["fingerprint"] }).to eq([ "fp-stuck" ])
    end
  end
end
