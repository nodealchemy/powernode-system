# frozen_string_literal: true

require "rails_helper"

# The outcome oracle for the task janitor.
#
# SystemTaskReaperJob reported "reap cycle complete, 0, 0" — success — every
# hour for five weeks while 33 tasks piled up behind it, because its query was
# scoped on a column that is NULL on every node. Nothing distinguished "the
# janitor sees nothing" from "the fleet is clean", since every available signal
# was a self-report by the mechanism under suspicion.
#
# Three claims this file pins hardest:
#
#   1. IT FIRES ON THE OUTCOME, NOT THE MECHANISM. The sensor never reads the
#      reaper's status, counters, or last-run time — only whether tasks are
#      still sitting. So it catches an empty scope, a stopped worker, a broken
#      seam, and regressions nobody has imagined yet, identically.
#   2. ITS THRESHOLD IS INDEPENDENT of the reaper's. A bound that always agrees
#      with the thing it audits can never disagree with it.
#   3. THE LANE REACHES A PERSON. A sensor wired into an unregistered lane is
#      the same inert-declaration defect it exists to expose, so the wiring
#      block is as load-bearing as the sensing.
RSpec.describe System::Fleet::Sensors::StuckTaskBacklogSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def task!(status: "pending", command: "sync_modules", age:, started_ago: nil, acct: nil)
    t = create(:system_task, account: acct || account, operable: node,
                             command: command, status: status)
    t.update_columns(
      created_at: age.ago,
      started_at: started_ago ? started_ago.ago : nil
    )
    t
  end

  describe "firing" do
    it "is silent when nothing is stuck" do
      task!(age: 1.hour)
      task!(status: "running", age: 2.hours, started_ago: 30.minutes)

      expect(signals).to eq([])
    end

    it "fires once a task sits past the threshold" do
      task!(age: 80.hours)

      expect(signals.size).to eq(1)
      expect(signals.first[:kind]).to eq("system.task_backlog_stuck")
      expect(signals.first[:payload]["stuck_count"]).to eq(1)
    end

    # The original incident's exact shape: a large, weeks-old backlog.
    it "reports count, oldest age and a breakdown for a real backlog" do
      15.times { task!(age: 30.days, command: "sync_modules") }
      14.times { task!(age: 20.days, command: "apply_config") }

      payload = signals.first[:payload]
      expect(payload["stuck_count"]).to eq(29)
      expect(payload["oldest_age_hours"]).to be >= (30 * 24)
      expect(payload["by_command"]).to eq({ "sync_modules" => 15, "apply_config" => 14 })
      expect(payload["by_status"]).to eq({ "pending" => 29 })
      expect(payload["sample"].size).to eq(described_class::SAMPLE_LIMIT)
    end

    it "emits ONE signal for the whole backlog, not one per task" do
      5.times { task!(age: 30.days) }

      expect(signals.size).to eq(1)
    end

    # A fingerprint that moved with the backlog size would mint a fresh signal
    # every tick and bury the operator, and could never be deduped as a
    # standing condition.
    it "keeps the fingerprint stable as the backlog grows" do
      task!(age: 30.days)
      first = described_class.new(account: account).sense.first[:fingerprint]
      3.times { task!(age: 29.days) }
      second = described_class.new(account: account).sense.first[:fingerprint]

      expect(second).to eq(first)
    end
  end

  describe "running tasks are measured from when they STARTED" do
    # A task can legitimately sit queued a while before a worker claims it;
    # charging that wait against the running clock would flag healthy work.
    it "ignores a long-queued task that started recently" do
      task!(status: "running", age: 30.days, started_ago: 5.minutes)

      expect(signals).to eq([])
    end

    it "fires on a task that has been running past the threshold" do
      task!(status: "running", age: 40.days, started_ago: 35.days)

      expect(signals.first[:payload]["by_status"]).to eq({ "running" => 1 })
    end

    # A row claiming to be running with no start time is itself broken and must
    # not become INVISIBLE by having no clock to measure.
    it "falls back to created_at when a running task has no started_at" do
      task!(status: "running", age: 30.days, started_ago: nil)

      expect(signals.size).to eq(1)
    end
  end

  describe "severity" do
    it "is medium for a freshly-stuck task" do
      task!(age: 80.hours)
      expect(signals.first[:severity]).to eq(:medium)
    end

    it "escalates to high after a week" do
      task!(age: 8.days)
      expect(signals.first[:severity]).to eq(:high)
    end

    it "escalates to critical after two weeks" do
      task!(age: 15.days)
      expect(signals.first[:severity]).to eq(:critical)
    end

    # Volume alone is structural: dozens of aged rows is a janitor that is not
    # running at all, which is what the incident looked like.
    it "escalates to critical on volume even when each row is only just stuck" do
      described_class::CRITICAL_COUNT.times { task!(age: 80.hours) }
      expect(signals.first[:severity]).to eq(:critical)
    end
  end

  describe "terminal states are never counted" do
    %w[complete failed aborted cancelled].each do |terminal|
      it "ignores #{terminal} tasks however old" do
        t = task!(age: 60.days)
        t.update_columns(status: terminal)

        expect(signals).to eq([])
      end
    end
  end

  describe "tenancy" do
    it "never counts another account's tasks" do
      other = create(:account)
      task!(age: 30.days, acct: other)

      expect(signals).to eq([])
    end
  end

  describe "the threshold is independent of the reaper's policy" do
    # If this ever becomes a copy of SystemTaskReaperJob::UNRUNNABLE_THRESHOLD,
    # the alarm moves whenever the policy is tuned and can never disagree with
    # the thing it audits.
    it "sits strictly above the 48h the reaper closes unrunnable tasks at" do
      expect(described_class::DEFAULT_STUCK_AFTER_SECONDS).to be > 48 * 3600
    end

    it "is operator-tunable without a deploy" do
      task!(age: 10.hours)
      expect(signals).to eq([])

      stub_const("ENV", ENV.to_hash.merge("SYSTEM_TASK_BACKLOG_STUCK_SECONDS" => "3600"))
      expect(described_class.new(account: account).sense.size).to eq(1)
    end
  end

  # ── The lane must reach a person ───────────────────────────────────────────
  describe "wiring" do
    it "is registered in the fleet sense pass" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "routes to a notify-level investigate category with no applier" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.task_backlog_stuck"]

      expect(binding).to be_present
      expect(binding[:action_category]).to eq("system.task_backlog_investigate")
      # There is no auto-remediation for "the janitor is inert" and there can
      # be none — the causes are code and configuration.
      expect(binding[:skill]).to be_nil
    end

    # NOT system.observation: the seed maps that to auto_approve, which files
    # the signal for a dashboard and reaches NO operator — which would make
    # this sensor itself inert.
    it "seeds the gate policy on the agent that runs the sense pass" do
      # Read the DECLARATION, not the seed text. These policy sets moved out
      # of fleet_autonomy_agent.rb into System::Governance::PolicyDeclarations
      # so the boot reconciler can assert them against a RUNNING database;
      # the seed now consumes that constant. Grepping the seed file for a
      # literal therefore tested a string that no longer exists there, while
      # the property it cares about — this category is gated on the agent
      # whose tick runs the sense pass — moved with the constant.
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES)
        .to include("system.task_backlog_investigate" => "notify_and_proceed")
    end

    # Without this the standing fingerprint of a still-broken janitor scores
    # ineffective every settle window and fakes a remediation_stuck alarm.
    it "declares the category non-remediating" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.task_backlog_investigate")
    end
  end
end
