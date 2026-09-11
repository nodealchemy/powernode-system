# frozen_string_literal: true

module System
  # Server-side reconciler for CI runner leases (campaign 019f5885 inc3). Driven
  # on a 60s tick by the worker (worker/app/jobs/system/ci_runner_lease_reconcile_job.rb
  # → POST worker_api/ci_runner_leases/advance) because the server runs no Sidekiq
  # and the worker is HTTP-only. All reconciliation logic lives here where the DB
  # and models are.
  #
  # Per active lease it correlates state against the Gitea workflow-run status and
  # (for builds) publish arrival, and drives the lease toward release + recycle.
  # It also reaps orphaned fleet-* Gitea runners whose backing instance is gone
  # (the pool's ready-TTL reaper terminates members without deregistering their
  # runner — see Fable P0-2).
  #
  # PURPOSE-AWARE (campaign 019f5885 inc9 Part B): a `module_build` lease
  # never runs gitea-act-runner (module-forge builders receive their work as
  # a `ci.module_build` System::Task via the normal agent task-lease loop,
  # not a Gitea Actions job), so it can NEVER correlate to a GitRunner —
  # #advance_leased/#advance_running's Gitea-workflow-run logic would leave
  # it stuck in `leased` forever. Such leases are routed to
  # #advance_module_build instead, which correlates on the lease's
  # `build_task_id` TASK state (acknowledged→busy, terminal→trigger
  # System::NativeModuleBuildOrchestrator.advance_for_task! then release)
  # rather than workflow_run_id.
  class CiRunnerLeaseSweepService
    # The sweep recycles and terminates runner instances, so it carries the
    # same two gates as every actuating reconciler (IMP-5f337c0f8e3e): the
    # kill switch outranks the dual-plane fence as the reported reason, and
    # on a standby plane the sweep does nothing — recycle-path idempotency
    # softened the dual-active blast radius, but reap/terminate is not
    # idempotent against a plane that no longer owns the fleet.
    include ::System::Autonomy::KillSwitchGuard
    include ::System::Autonomy::ControlPlaneGuard

    TERMINAL_RUN_STATUSES = %w[completed failed cancelled skipped].freeze

    def self.run!(account:)
      new(account: account).run!
    end

    attr_reader :account

    def initialize(account:)
      @account = account
      @svc = CiRunnerLeaseService.new(account: account)
      @summary = { advanced: 0, released: 0, flagged: 0, errored: 0, orphans_reaped: 0,
                   readvanced: 0, redispatched: 0 }
    end

    def run!
      return halted_tick_result if kill_switch_engaged?
      return standby_tick_result unless control_plane_active?

      CiRunnerLease.for_account(@account).active.find_each do |lease|
        advance(lease)
      rescue StandardError => e
        Rails.logger.error("[CiRunnerLeaseSweep] lease ##{lease.id} advance failed: #{e.message}")
        safe_fail(lease, e.message)
      end

      @summary[:orphans_reaped] = reap_orphans
      @summary[:readvanced]     = readvance_stalled_batches!
      @summary[:redispatched]   = redispatch_queued_batches!
      @summary
    end

    private

    # A native-build module that re-queued after a transient failure
    # (#attempt_retry! nils its lease_id + task_id) has NO active lease, so the
    # active-lease loop above never touches its batch again — nothing calls
    # #try_dispatch_queued! to hand it a fresh builder and it sits "queued"
    # forever (also the create-time "couldn't lease at that instant" case).
    # Re-dispatch every non-terminal native batch that still carries a
    # queued-but-unleased module so a freed builder picks the retry up.
    # NativeModuleBuildOrchestrator#dispatch! is capacity-bounded and only
    # leases for modules in state "queued", so a batch with nothing queued is a
    # cheap no-op and this can't over-dispatch past max_concurrent_builders.
    def redispatch_queued_batches!
      redispatched = 0
      non_terminal_batches.find_each do |batch|
          mods = (batch.metadata || {})["modules"] || {}
          next unless mods.values.any? { |e| e.is_a?(::Hash) && e["state"] == "queued" }

          ::System::NativeModuleBuildOrchestrator.dispatch!(batch: batch)
          redispatched += 1
        rescue StandardError => e
          Rails.logger.error("[CiRunnerLeaseSweep] re-dispatch batch ##{batch.id} failed: #{e.class}: #{e.message}")
        end
      redispatched
    end

    # LEASE-INDEPENDENT re-advance of a batch with a finished-but-unresolved
    # member (2026-09-06, batch 01a07446 / hub-frontend): a module whose Task
    # is terminal but whose entry is still "dispatched" was never signed or
    # recorded, and once its lease is gone (released by the backstop in
    # #advance_module_build, expired, released by hand, or the orchestrator's
    # own advance raised after releasing it) NOTHING in the active-lease loop
    # above ever touches its batch again — the batch parks in `publishing`
    # with a built, pushed artifact that no NodeModuleVersion points at.
    # NativeModuleBuildOrchestrator#advance! is idempotent for already-
    # resolved entries, so re-advancing such a batch does exactly the missing
    # sign + publish and nothing else.
    def readvance_stalled_batches!
      readvanced = 0
      non_terminal_batches.where(status: %w[dispatched awaiting_signature publishing]).find_each do |batch|
        next unless stalled_member?(batch)

        ::System::NativeModuleBuildOrchestrator.advance!(batch: batch)
        readvanced += 1
      rescue StandardError => e
        Rails.logger.error("[CiRunnerLeaseSweep] re-advance batch ##{batch.id} failed: #{e.class}: #{e.message}")
      end
      readvanced
    end

    def non_terminal_batches
      ::System::ModuleBuildBatch
        .where(account_id: @account.id, status: %w[planning dispatched awaiting_signature publishing])
    end

    # A "dispatched" entry whose tracked Task has already finished.
    def stalled_member?(batch)
      task_ids = module_entries(batch).select { |e| e["state"] == "dispatched" }.filter_map { |e| e["task_id"] }
      return false if task_ids.empty?

      ::System::Task.where(id: task_ids).any?(&:finished?)
    end

    def module_entries(batch)
      ((batch.metadata || {})["modules"] || {}).values.select { |e| e.is_a?(::Hash) }
    end

    def advance(lease)
      return advance_module_build(lease) if lease.purpose == "module_build" && lease.build_task_id.present?
      return advance_lint_discovery(lease) if lease.purpose == ::System::LintDiscoveryExecutor::PURPOSE &&
                                              lease.build_task_id.present?

      case lease.status
      when "leased"                 then advance_leased(lease)
      when "registered", "busy"     then advance_running(lease)
      when "releasing"              then release(lease, reason: "resume release")
      end
    end

    # --- lint_discovery (campaign 01a08c9b D1b) --------------------------------
    #
    # The lease ends when its ci.lint_discovery task finishes, or at its
    # deadline (expires_at, set by System::LintDiscoveryExecutor). Either way
    # every repository that never reported is recorded on the account as not
    # measured with a named reason, so a runner that went quiet can never read
    # as a clean sweep. The deadline is the bound on the linters: it replaces
    # D1's in-process timeout.
    def advance_lint_discovery(lease)
      task = ::System::Task.find_by(id: lease.build_task_id)
      reason =
        if task.nil? then "lint_task_missing"
        elsif task.finished? then "runner_did_not_report"
        elsif lease.expired? then "runner_deadline_passed"
        end
      return if reason.nil?

      record_unreported_repositories(lease, reason)
      # force: at the deadline the runner may still be linting, and recycling
      # it is the point.
      @svc.release!(lease, force: true)
      @summary[:released] += 1
      emit_event(lease, "system.ci_runner_lease_released", reason: "lint_discovery #{reason}")
    end

    def record_unreported_repositories(lease, reason)
      unreported = Array(lease.metadata["repository_ids"]) - Array(lease.metadata["reported_repository_ids"])
      return if unreported.empty?

      ::Ai::Improvement::DiscoveryRun.record!(
        account: lease.account,
        summary: {
          phase: "ingest", status: "not_measured", reason: reason, run_ref: lease.id,
          repository_ids: [], unreported_repository_ids: unreported,
          analyzers: ::Ai::Improvement::DiscoveryRunService::ANALYZERS, analyzers_degraded: [],
          findings: 0, offers_created: 0, offers_deduped: 0, offers_parked: 0
        }
      )
    end

    # --- module_build purpose-aware correlation (inc9 Part B) -----------------

    # Drives a module_build lease off its correlated ci.module_build Task
    # instead of a Gitea workflow run: registered while the task is
    # pending/scheduled, busy once the agent acknowledges (task -> running),
    # and — once the task reaches ANY terminal status — triggers the
    # orchestrator's advance! (sign + publish on success, retry-or-fail
    # otherwise). The ORCHESTRATOR releases the lease itself as part of
    # advance! (System::NativeModuleBuildOrchestrator#release_module_lease) —
    # this method's own `release` call below only fires as a BACKSTOP, when
    # the lease is somehow still active after advance! returns (orchestrator
    # unreachable, batch_id missing, its own release attempt raised, …), so a
    # finished task's lease is never permanently stranded. Either way,
    # release only ever happens once task.finished? is already true, so a
    # lease whose build might still be running is never torn down.
    def advance_module_build(lease)
      task = ::System::Task.find_by(id: lease.build_task_id)
      return expire_if_due(lease) if task.nil?

      if task.finished?
        trigger_orchestrator_advance(task)
        lease.reload
        return if lease.finished?

        return release(lease, reason: "module_build task #{task.id} #{task.status} (sweep backstop release)")
      end

      if task.running? && lease.registered? && lease.may_mark_busy?
        lease.mark_busy!
        @summary[:advanced] += 1
      end

      expire_if_due(lease)
    end

    # Several active module_build leases can correlate to tasks in the SAME
    # batch, and one advance! resolves every member Task that was already
    # terminal when it loaded the batch — so the dedupe here is keyed on THIS
    # task's resolution in the batch's persisted state, never on "the batch
    # was advanced this tick". The latter (the pre-2026-09-06 shape) skipped
    # a sibling lease whose task finished DURING the first advance's ~100 s
    # sign+publish: that advance had captured its terminal set before the
    # task finished, the skip left the entry "dispatched", the backstop
    # release below then dropped the lease, and no later tick ever advanced
    # the batch again (hub-frontend built + pushed, never recorded).
    def trigger_orchestrator_advance(task)
      batch_id = ::System::NativeModuleBuildOrchestrator.task_batch_id(task)
      return if batch_id.blank?
      return if task_resolved_in_batch?(batch_id, task)

      ::System::NativeModuleBuildOrchestrator.advance_for_task!(task)
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLeaseSweep] orchestrator advance for task ##{task.id} failed: #{e.message}")
    end

    # True when the batch's persisted state already carries this task's entry
    # in a terminal module state (nothing left for advance! to do for it), or
    # no longer tracks the task at all (a retry re-queued the module onto a
    # fresh Task; this one's outcome has been consumed). An unknown batch
    # is "unresolved" so advance_for_task! gets its normal not-found no-op.
    def task_resolved_in_batch?(batch_id, task)
      batch = ::System::ModuleBuildBatch.find_by(id: batch_id)
      return false unless batch

      entry = module_entries(batch).find { |e| e["task_id"] == task.id }
      return true if entry.nil?

      ::System::NativeModuleBuildOrchestrator::TERMINAL_MODULE_STATES.include?(entry["state"])
    end

    # Try once to correlate to the GitRunner row; expiry is the backstop if the
    # runner never surfaced.
    def advance_leased(lease)
      @svc.correlate!(lease)
      @summary[:advanced] += 1 if lease.registered?
      expire_if_due(lease)
    end

    def advance_running(lease)
      run = fetch_run(lease)
      if run
        if terminal_run?(run)
          # Run finished → the runner's work is done. Release, unless a build's
          # publish handshake hasn't landed yet (soft gate; expiry is backstop).
          return release(lease, reason: "run #{lease.workflow_run_id} #{run_status(run)}") if publish_confirmed?(lease, run)
        else
          mark_busy_if_needed(lease, run)
        end
      end
      expire_if_due(lease)
    end

    # Release (or flag, if the runner is live) — never tears down a busy runner.
    def release(lease, reason:)
      @svc.release!(lease)
      @summary[:released] += 1
      emit_event(lease, "system.ci_runner_lease_released", reason: reason)
    rescue CiRunnerLeaseService::RunnerBusyError
      flag_stale(lease, reason: "#{reason}; runner busy — not tearing down live work")
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLeaseSweep] release ##{lease.id} failed: #{e.message}")
    end

    def expire_if_due(lease)
      lease.reload
      return unless lease.active? && lease.expired?

      release(lease, reason: "lease expired")
    end

    def mark_busy_if_needed(lease, run)
      return unless lease.registered?
      return unless run_status(run) == "in_progress"
      return unless lease.may_mark_busy?

      lease.mark_busy!
      @summary[:advanced] += 1
    end

    # --- Gitea run correlation ------------------------------------------------

    def fetch_run(lease)
      return nil if lease.workflow_run_id.blank?

      owner, repo = split_repo(lease.workflow_run_repo)
      return nil if owner.blank? || repo.blank?

      credential = resolver.credential
      return nil unless credential&.can_be_used?

      client = ::Devops::Git::ApiClient.for(credential)
      return nil unless client.respond_to?(:get_workflow_run)

      client.get_workflow_run(owner, repo, lease.workflow_run_id)
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLeaseSweep] run fetch ##{lease.id} failed: #{e.message}")
      nil
    end

    def terminal_run?(run)
      TERMINAL_RUN_STATUSES.include?(run_status(run))
    end

    def run_status(run)
      (run[:status] || run["status"]).to_s
    end

    def run_succeeded?(run)
      (run[:conclusion] || run["conclusion"]).to_s == "success"
    end

    # Soft publish-arrival gate. For a *successful* build run, hold the release
    # until the publish callback has landed so we don't recycle the builder mid
    # publish-handshake. The run→publication correlation is only fully wired in
    # inc4 (which ties the lease to both the run and the artifact); until then
    # this is best-effort and the lease's expiry (default 2h) is the backstop.
    def publish_confirmed?(lease, run)
      return true unless lease.purpose.in?(%w[module_build disk_image_build])
      return true unless run_succeeded?(run)

      publish_arrived?(lease)
    rescue StandardError
      true
    end

    def publish_arrived?(lease)
      case lease.purpose
      when "disk_image_build"
        since = lease.leased_at || lease.created_at
        ::System::DiskImagePublication.where(account: @account).published_state
                                      .where(updated_at: since..).exists?
      else
        # module_build: NodeModuleVersion carries no source-sha link yet, so a
        # run→version correlation lands in inc4. Treat run-terminal as sufficient.
        true
      end
    end

    # --- Orphan reaping -------------------------------------------------------

    # Deregister fleet-* Gitea runners that are offline and unreferenced by any
    # active lease — their backing instance was terminated (by release recycle or
    # the pool's ready-TTL reaper) without deregistering the runner.
    def reap_orphans
      reaped = 0
      live_names = CiRunnerLease.for_account(@account).active.where.not(runner_name: nil).pluck(:runner_name).to_set

      @account.git_runners.where("name LIKE ?", "fleet-%").offline.find_each do |runner|
        next if live_names.include?(runner.name)
        next if runner.recently_active? # never reap a runner seen in the last 5 min

        result = ::Devops::RunnerLifecycleService.new(account: @account).delete_runner(runner)
        reaped += 1 unless result.is_a?(Hash) && result[:success] == false
      end
      reaped
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLeaseSweep] orphan reap failed: #{e.message}")
      reaped
    end

    # --- helpers --------------------------------------------------------------

    def flag_stale(lease, reason:)
      lease.update!(metadata: (lease.metadata || {}).merge(
        "stale_flagged_at" => Time.current.iso8601,
        "stale_reason" => reason
      ))
      emit_event(lease, "system.ci_runner_lease_stale", reason: reason, severity: :medium)
      @summary[:flagged] += 1
    end

    def safe_fail(lease, message)
      lease.fail!(message) if lease.may_fail?
      @summary[:errored] += 1
    rescue StandardError
      nil
    end

    def emit_event(lease, kind, reason: nil, severity: :low)
      ::System::Fleet::EventBroadcaster.emit!(
        account: @account,
        kind: kind,
        severity: severity,
        payload: { "lease_id" => lease.id, "runner_name" => lease.runner_name, "reason" => reason }.compact,
        source: "ci_runner_lease.sweep"
      )
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLeaseSweep] event emit failed: #{e.message}")
    end

    def split_repo(owner_repo)
      return [ nil, nil ] if owner_repo.blank?

      owner, repo = owner_repo.to_s.split("/", 2)
      [ owner, repo ]
    end

    def resolver
      @resolver ||= CiRunnerRegistrationResolver.new(account: @account)
    end
  end
end
