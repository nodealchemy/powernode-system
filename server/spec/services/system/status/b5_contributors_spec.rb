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
        expect_counts_withheld(result)
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

      it "an outage after a clear reading is not_measured, never ok, and the counts are withheld" do
        tick!
        store!(conditions_of(contributor))
        System::FleetEvent.where(account: account, kind: "fleet.tick_complete").delete_all

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect_counts_withheld(result)
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

    # Review L1: the outage and ratchet arms carried evidence with no source.
    it "names a source on every condition's evidence, in every arm" do
      readings = [ conditions_of(contributor) ]
      tick!
      access!(at: 1.hour.ago)
      readings << conditions_of(contributor)
      store!(readings.last)
      System::FleetEvent.where(account: account, kind: "fleet.tick_complete").delete_all
      readings << conditions_of(contributor)

      reasons = readings.flatten.map { |c| c["reason"] }
      expect(reasons).to include("NoFleetTick", "FeedUnavailable", "FleetTickFresh", "AccessedWithin24h",
                                 "HeldFromLastObservation")
      unsourced = readings.flatten.reject { |c| c["evidence"].is_a?(Hash) && c["evidence"]["source"].present? }
      expect(unsourced.map { |c| "#{c['type']}/#{c['reason']}" }).to be_empty
    end

    # Review M1: every read is account-scoped. Another account's tick, canary
    # access and stored alert sit beside this account's, so an unscoped read
    # reds here instead of passing on a one-account fixture.
    context "with another account's data present" do
      let(:other) { create(:account) }

      before do
        create(:system_fleet_event, account: other, kind: "fleet.tick_complete", emitted_at: 1.minute.ago,
                                    payload: { "failed_sensors" => [] })
        create(:system_fleet_event, account: other, kind: "system.honeypot_triggered", emitted_at: 1.hour.ago)
        tripped = contributor.conditions_for(described_class::Canary.new(account: other))
        expect(verdict(tripped)).to eq("down")
        Platform::ComponentStatus.create!(
          account_id: other.id, component_kind: described_class::KIND, component_ref: described_class::REF,
          display_name: "Honeypot canary", conditions: tripped, verdict: verdict(tripped)
        )
      end

      it "another account's tick is not this account's feed, and its stored alert is not held here" do
        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, feed)["reason"]).to eq("NoFleetTick")
        expect(condition(result, untouched)["reason"]).to eq("FeedUnavailable")
        expect_counts_withheld(result)
      end

      it "another account's canary access is not counted against this account's canary" do
        tick!

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("ok")
        expect(condition(result, untouched)["evidence"]).to include("count_24h" => 0, "count_7d" => 0,
                                                                  "last_access_at" => nil)
      end
    end
  end

  # ── dispatch_latency ─────────────────────────────────────────────────────
  # Review H1: this read Rails.cache counters nothing has written since the
  # server dispatch spine was retired, so it could only read ok. It now reads
  # the system_tasks rows the pipeline writes.
  describe System::Status::Contributors::DispatchLatencyContributor do
    let(:contributor) { described_class.new }
    let(:pickup) { described_class::PICKUP }
    let(:stuck) { described_class::STUCK }
    let(:window) { Platform::Status::SweepService.sweep_interval_seconds }
    let(:threshold) do
      System::Fleet::Sensors::InstanceStatusSensor.resolved_threshold("silent_threshold_seconds", account: account)
    end

    def task!(created_at:, owner: account, status: "pending", started_at: nil, scheduled_at: nil)
      create(:system_task, account: owner, status: status, created_at: created_at, started_at: started_at,
                           scheduled_at: scheduled_at)
    end

    def pipeline_conditions(owner) = contributor.conditions_for(described_class::Pipeline.new(account: owner))

    it "nothing picked up in the window: a MEASURED quiet window, ok, the percentiles nil — never 0" do
      task!(status: "complete", created_at: (window * 3).seconds.ago, started_at: (window * 2).seconds.ago)

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("ok")
      expect(condition(result, pickup)).to include("status" => true, "reason" => "QuietWindow")
      expect(condition(result, pickup)["evidence"]).to include("picked_up" => 0, "p50_seconds" => nil,
                                                               "p95_seconds" => nil, "window_seconds" => window)
    end

    it "tasks picked up in the window: p50 and p95 of started_at minus when each fell due" do
      started = 5.seconds.ago
      [ 2, 4, 6, 8, 10 ].each { |wait| task!(status: "running", created_at: started - wait.seconds, started_at: started) }
      # Created an hour ago but due 6s before it started: the wait runs from scheduled_at.
      task!(status: "running", created_at: 1.hour.ago, scheduled_at: started - 6.seconds, started_at: started)

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("ok")
      expect(condition(result, pickup)).to include("reason" => "Measured")
      expect(condition(result, pickup)["evidence"]).to include("picked_up" => 6, "p50_seconds" => 6.0,
                                                               "p95_seconds" => 9.5)
    end

    it "the window is the status sweep interval, from its SiteSetting" do
      SiteSetting.create!(key: Platform::Status::SweepService::SWEEP_INTERVAL_SETTING, value: "600",
                          setting_type: "integer")
      task!(status: "running", created_at: 330.seconds.ago, started_at: 300.seconds.ago)

      result = conditions_of(contributor)

      expect(condition(result, pickup)["evidence"]).to include("window_seconds" => 600, "picked_up" => 1,
                                                               "p50_seconds" => 30.0)
    end

    it "a pending task past the account's silent threshold: degraded, naming it and not a younger one" do
      old = task!(created_at: (threshold + 60).seconds.ago)
      task!(created_at: (threshold - 60).seconds.ago)

      result = conditions_of(contributor)
      evidence = condition(result, stuck)["evidence"]

      expect(verdict(result)).to eq("degraded")
      expect(condition(result, stuck)).to include("status" => false, "reason" => "PendingNotPickedUp")
      expect(evidence).to include("stuck_count" => 1, "threshold_seconds" => threshold)
      expect(evidence["oldest"].map { |t| t["id"] }).to eq([ old.id ])
    end

    it "a pending task inside the threshold is not stuck: ok" do
      task!(created_at: (threshold - 60).seconds.ago)

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("ok")
      expect(condition(result, stuck)).to include("status" => true, "reason" => "NoneStuck")
    end

    it "follows the account's tuned silent threshold rather than a constant of its own" do
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "instance_status",
                                             config: { "silent_threshold_seconds" => 24 * 3600 })
      task!(created_at: 2.hours.ago)

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("ok")
      expect(condition(result, stuck)["evidence"]).to include("threshold_seconds" => 24 * 3600, "stuck_count" => 0)
    end

    it "a task scheduled for later is not stuck before it falls due, and is once it has" do
      task!(created_at: 2.days.ago, scheduled_at: 1.hour.from_now)
      due = task!(created_at: 2.days.ago, scheduled_at: (threshold + 60).seconds.ago)

      evidence = condition(conditions_of(contributor), stuck)["evidence"]

      expect(evidence["stuck_count"]).to eq(1)
      expect(evidence["oldest"].map { |t| t["id"] }).to eq([ due.id ])
    end

    # The worker is offered scheduled rows once they fall due
    # (Internal::System::AccountsController#pending_tasks), so a due scheduled
    # task nobody starts is as stuck as a pending one.
    it "a scheduled task past due and not picked up is stuck, as a pending one is" do
      waiting = task!(status: "scheduled", created_at: 2.days.ago, scheduled_at: (threshold + 60).seconds.ago)
      task!(status: "scheduled", created_at: 2.days.ago, scheduled_at: 1.hour.from_now)

      result = conditions_of(contributor)
      evidence = condition(result, stuck)["evidence"]

      expect(verdict(result)).to eq("degraded")
      expect(evidence["stuck_count"]).to eq(1)
      expect(evidence["oldest"].map { |t| t["id"] }).to eq([ waiting.id ])
    end

    it "a failed read: not_measured naming QueryFailed, with no count or latency — never a quiet window" do
      allow(System::Task).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "PG::ConnectionBad: closed")

      result = conditions_of(contributor)

      expect(verdict(result)).to eq("not_measured")
      [ pickup, stuck ].each do |type|
        expect(condition(result, type)).to include("status" => "unknown", "reason" => "QueryFailed")
        expect(condition(result, type)["evidence"]).not_to include("picked_up", "p50_seconds", "stuck_count")
      end
    end

    it "reads only this account's tasks, while the same rows count for their own account" do
      other = create(:account)
      task!(owner: other, created_at: (threshold + 60).seconds.ago)
      task!(owner: other, status: "running", created_at: 20.seconds.ago, started_at: 10.seconds.ago)

      mine = conditions_of(contributor)
      theirs = pipeline_conditions(other)

      expect(verdict(mine)).to eq("ok")
      expect(condition(mine, pickup)["evidence"]).to include("picked_up" => 0)
      expect(condition(mine, stuck)["evidence"]).to include("stuck_count" => 0)
      expect(verdict(theirs)).to eq("degraded")
      expect(condition(theirs, pickup)["evidence"]).to include("picked_up" => 1)
    end

    it "names a source on every condition's evidence, the failure arm included" do
      readings = [ conditions_of(contributor) ]
      task!(created_at: (threshold + 60).seconds.ago)
      task!(status: "running", created_at: 20.seconds.ago, started_at: 10.seconds.ago)
      readings << conditions_of(contributor)
      allow(System::Task).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")
      readings << conditions_of(contributor)

      expect(readings.flatten.map { |c| c["reason"] })
        .to include("QuietWindow", "NoneStuck", "Measured", "PendingNotPickedUp", "QueryFailed")
      unsourced = readings.flatten.reject { |c| c["evidence"].is_a?(Hash) && c["evidence"]["source"].present? }
      expect(unsourced.map { |c| "#{c['type']}/#{c['reason']}" }).to be_empty
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

    # Review M1: another account's settled and stuck outcomes sit beside this
    # account's, so an unscoped summary reds here.
    context "with another account's outcomes present" do
      let(:other) { create(:account) }

      before do
        threshold.times do |i|
          acted_at = (2 + i).hours.ago
          System::Fleet::RemediationOutcome.create!(
            account: other, signal_kind: "system.module_drift", fingerprint: "fp-other-stuck", status: "ineffective",
            acted_at: acted_at, settle_until: acted_at + 10.minutes, validated_at: acted_at + 15.minutes
          )
        end
      end

      it "an account with no outcomes of its own: nothing settled and nothing stuck" do
        result = conditions_of(contributor)

        expect(verdict(result)).to eq("not_measured")
        expect(condition(result, described_class::EFFECTIVENESS)["evidence"]["effectiveness_rate"]).to be_nil
        expect(condition(result, described_class::STUCK)["reason"]).to eq("NoneStuck")
        expect(condition(result, described_class::STUCK)["evidence"]["fingerprints"]).to eq([])
      end

      it "rates only this account's settled outcomes" do
        outcome!(status: "effective")

        result = conditions_of(contributor)

        expect(verdict(result)).to eq("ok")
        expect(condition(result, described_class::EFFECTIVENESS)["evidence"]["effectiveness_rate"]).to eq(1.0)
      end
    end
  end
end
