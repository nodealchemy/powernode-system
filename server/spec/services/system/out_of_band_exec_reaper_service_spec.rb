# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — the reaper sweep for DeferredOperations stuck
# `executing` under system.instance.out_of_band_exec past timeout+margin.
# NEVER re-runs the command — it only fails the row and records that it did.
#
# Built through the REAL AASM lifecycle (approve! then start_execution!),
# never `update_columns(executed_at: ...)`. That matters here specifically:
# a review finding caught that #start_execution has no `before` block at
# all (unlike #complete/#fail, which both set executed_at) — a genuinely
# stuck row therefore has executed_at NULL forever, and any fixture that
# fakes a non-nil executed_at would pass while the real code path,
# never populating it, went unreaped. Staleness here is real elapsed wall
# time since start_execution! (travel_to), read off updated_at.
RSpec.describe System::OutOfBandExecReaperService do
  let(:account) { create(:account) }

  def gated_operation
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: ::System::OutOfBandExecService::ACTION_CATEGORY,
      executor_class: "StubExecutor",
      params: { instance_id: SecureRandom.uuid, command: "uptime" }
    )
  end

  # Drives the row through pending -> approved -> executing for real, at
  # `started_at` (moves the clock there first, so updated_at lands there
  # too), then returns to `now` — the caller runs the reaper from "now",
  # `elapsed` wall-clock seconds after the row actually started.
  def start_executing(started_at: Time.current)
    op = gated_operation
    travel_to(started_at) do
      op.approve!
      op.start_execution!
    end
    op.reload
  end

  before do
    stub_const("StubExecutor", Class.new do
      def self.execute(_params, deferred_operation:)
        raise "the reaper must never invoke the executor"
      end
    end)
  end

  describe "run!" do
    it "fails an operation stuck executing past timeout+margin, even though executed_at is NULL" do
      op = start_executing(started_at: 10.minutes.ago)
      expect(op.executed_at).to be_nil # the exact condition the real bug hid behind

      result = described_class.run!

      expect(result.ok?).to be true
      expect(result.failed_count).to eq(1)
      expect(op.reload.status).to eq("failed")
      expect(op.error_message).to eq("executor lost")
    end

    it "writes an Ai::ExecutionEvent for the reaped operation" do
      op = start_executing(started_at: 10.minutes.ago)

      described_class.run!

      event = ::Ai::ExecutionEvent.find_by(source_type: "Ai::DeferredOperation", source_id: op.id)
      expect(event).to be_present
      expect(event.status).to eq("failed")
      expect(event.error_message).to eq("executor lost")
    end

    it "never invokes the executor — it only fails the row" do
      start_executing(started_at: 10.minutes.ago)

      expect { described_class.run! }.not_to raise_error
    end

    it "leaves a recently-started executing operation alone (still within timeout+margin)" do
      op = start_executing(started_at: 5.seconds.ago)

      result = described_class.run!

      expect(result.failed_count).to eq(0)
      expect(op.reload.status).to eq("executing")
    end

    it "ignores operations under a different action_category" do
      op = ::Ai::DeferredOperation.create!(
        account: account, action_category: "system.task.ssh_command",
        executor_class: "StubExecutor", params: {}
      )
      travel_to(10.minutes.ago) do
        op.approve!
        op.start_execution!
      end

      result = described_class.run!

      expect(result.failed_count).to eq(0)
      expect(op.reload.status).to eq("executing")
    end

    it "ignores operations already terminal (completed/failed/rejected)" do
      completed = start_executing(started_at: 10.minutes.ago)
      completed.complete!({})
      failed = start_executing(started_at: 10.minutes.ago)
      failed.fail!("some other reason")

      result = described_class.run!

      expect(result.failed_count).to eq(0)
      expect(completed.reload.status).to eq("completed")
      expect(failed.reload.status).to eq("failed")
      expect(failed.reload.error_message).to eq("some other reason")
    end

    it "respects the configured timeout_seconds when computing the stuck threshold" do
      ::SiteSetting.set(::System::OutOfBandExecService::TIMEOUT_SETTING_KEY, "5", setting_type: "integer")
      # 5s timeout + the reaper's margin: 90s ago is well past it.
      op = start_executing(started_at: 90.seconds.ago)

      result = described_class.run!

      expect(result.failed_count).to eq(1)
      expect(op.reload.status).to eq("failed")
    end

    # Review finding R2-3 — the reaper duplicates (rather than calls)
    # OutOfBandExecService's own private #timeout_seconds and must apply the
    # SAME MAX_TIMEOUT_SECONDS ceiling. Without it, an operator-set value
    # above the ceiling would make BoundedCommandRunner honor only 300s while
    # this reaper kept waiting on the full (unclamped) configured value
    # before ever considering a row stale — a row genuinely abandoned at
    # ~300s would sit unreaped far longer than the runner's own bound.
    it "clamps an above-ceiling configured timeout_seconds to MAX_TIMEOUT_SECONDS + margin, not the unclamped value" do
      ::SiteSetting.set(::System::OutOfBandExecService::TIMEOUT_SETTING_KEY, "999999", setting_type: "integer")
      clamped_threshold = ::System::OutOfBandExecService::MAX_TIMEOUT_SECONDS + described_class::MARGIN_SECONDS
      # Past the CLAMPED threshold (300 + 60 = 360s), nowhere near the
      # unclamped 999999s one — reaped only if the clamp is actually applied.
      op = start_executing(started_at: (clamped_threshold + 10).seconds.ago)

      result = described_class.run!

      expect(result.failed_count).to eq(1)
      expect(op.reload.status).to eq("failed")
    end

    it "reaps more than one stuck operation in a single run" do
      op1 = start_executing(started_at: 10.minutes.ago)
      op2 = start_executing(started_at: 20.minutes.ago)

      result = described_class.run!

      expect(result.failed_count).to eq(2)
      expect(op1.reload.status).to eq("failed")
      expect(op2.reload.status).to eq("failed")
    end

    # Row-lock regression guard (review finding): a true cross-process race
    # is impractical to assert deterministically against a transactional-
    # fixture spec DB (a second thread gets a different pooled connection
    # and would not see this test's own uncommitted fixture rows at all).
    # This pins the mechanism instead: #may_fail? and #fail! run INSIDE
    # #with_lock's critical section for every candidate, which is what
    # closes the window two overlapping sweeps would otherwise race in
    # (both reading `executing` before either writes).
    it "acquires a row lock before failing the stuck row" do
      start_executing(started_at: 10.minutes.ago)

      expect_any_instance_of(::Ai::DeferredOperation).to receive(:with_lock).and_call_original

      op = described_class.run!
      expect(op.failed_count).to eq(1)
    end
  end
end
