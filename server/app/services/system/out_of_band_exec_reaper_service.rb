# frozen_string_literal: true

module System
  # IMP-9ce0ed39c557 — sweeps Ai::DeferredOperation rows stuck `executing`
  # under system.instance.out_of_band_exec past the configured
  # timeout_seconds plus a margin. It NEVER re-runs the command: the
  # timeout that stranded the row already means the process that was
  # running it (this Rails process, or the worker that called into it) is
  # gone, and replaying an out-of-band shell command a second time with no
  # visibility into whether the first one completed is a correctness and
  # safety hazard the design explicitly refuses to take on. The row is
  # marked failed with error_message "executor lost" and an
  # Ai::ExecutionEvent records it, so the stranding is operator-visible
  # rather than a DeferredOperation silently parked in `executing` forever.
  #
  # Called on a schedule by OutOfBandExecReaperJob (worker) through
  # the worker_api HTTP door — mirrors System::Identity::ReaperService /
  # System::IdentityReaperJob exactly. No job classes live in server/app/jobs
  # (the worker/server boundary): this class does the actual DB work, a
  # worker_api controller exposes it, and the worker calls the controller.
  class OutOfBandExecReaperService
    # Grace beyond the configured timeout_seconds before a still-`executing`
    # row is declared lost rather than merely slow. Generous relative to the
    # runner's own deadline: the runner already kills the child at
    # timeout_seconds, so by the time this margin also elapses the executor
    # process itself — not just the command — must be gone (crashed, OOM-
    # killed, redeployed) for the row to still read `executing`.
    MARGIN_SECONDS = 60

    LOST_MESSAGE = "executor lost"

    Result = Struct.new(:ok?, :failed_count, :ran_at, keyword_init: true)

    def self.run!
      new.run!
    end

    def run!
      Result.new(ok?: true, failed_count: fail_stuck_operations, ran_at: Time.current)
    end

    private

    # Keyed on updated_at, NOT executed_at (review finding, IMP-9ce0ed39c557):
    # Ai::DeferredOperation#start_execution transitions approved -> executing
    # with no `before` block at all (unlike #complete / #fail, which both set
    # executed_at) — see deferred_operation.rb's aasm block. A row genuinely
    # stuck executing therefore has executed_at NULL forever, and
    # `executed_at < threshold` is never true for it: this reaper matched
    # nothing on real data. updated_at IS touched by that transition (AASM's
    # default persistence is an ordinary #save!, which stamps it like any
    # other write), and nothing else legitimately touches the row while it
    # stays `executing` — the only transitions OUT of that state are
    # #complete!/#fail!, which is exactly the case this reaper exists for.
    def fail_stuck_operations
      threshold = (timeout_seconds + MARGIN_SECONDS).seconds.ago

      candidates = ::Ai::DeferredOperation
                     .where(status: "executing", action_category: ::System::OutOfBandExecService::ACTION_CATEGORY)
                     .where("updated_at < ?", threshold)

      count = 0
      candidates.find_each do |op|
        # Row lock (review finding): without it, two reaper sweeps racing
        # (an overlapping worker retry, or two workers) can both pass
        # #may_fail? on the same row before either writes, and the second
        # #fail! either raises (AASM whiny_transitions) or silently no-ops —
        # either way a double-fail attempt on one row. Re-checks may_fail?
        # under the lock so a row another process already closed in the
        # meantime is skipped rather than raising.
        op.with_lock do
          next unless op.may_fail?

          op.fail!(LOST_MESSAGE)
          record_execution_event!(op)
          count += 1
        end
      end
      count
    end

    def record_execution_event!(op)
      ::Ai::Introspection::ExecutionEventRecorder.record(
        source: op,
        event_type: "out_of_band_exec_reaped",
        status: "failed",
        error: StandardError.new(LOST_MESSAGE),
        metadata: { reaper: self.class.name, margin_seconds: MARGIN_SECONDS }
      )
    end

    # Review finding C2-2 — calls the ONE shared, clamped implementation
    # (System::OutOfBandExecService.configured_timeout_seconds) instead of
    # duplicating it. The duplicate this replaced silently missed the
    # MAX_TIMEOUT_SECONDS clamp for a full review round (R2-3) — a shared
    # method is what actually prevents that drift, not a second copy kept
    # manually in sync.
    def timeout_seconds
      ::System::OutOfBandExecService.configured_timeout_seconds
    end
  end
end
