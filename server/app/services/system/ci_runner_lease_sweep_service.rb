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
  class CiRunnerLeaseSweepService
    TERMINAL_RUN_STATUSES = %w[completed failed cancelled skipped].freeze

    def self.run!(account:)
      new(account: account).run!
    end

    def initialize(account:)
      @account = account
      @svc = CiRunnerLeaseService.new(account: account)
      @summary = { advanced: 0, released: 0, flagged: 0, errored: 0, orphans_reaped: 0 }
    end

    def run!
      CiRunnerLease.for_account(@account).active.find_each do |lease|
        advance(lease)
      rescue StandardError => e
        Rails.logger.error("[CiRunnerLeaseSweep] lease ##{lease.id} advance failed: #{e.message}")
        safe_fail(lease, e.message)
      end

      @summary[:orphans_reaped] = reap_orphans
      @summary
    end

    private

    def advance(lease)
      case lease.status
      when "leased"                 then advance_leased(lease)
      when "registered", "busy"     then advance_running(lease)
      when "releasing"              then release(lease, reason: "resume release")
      end
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
      return unless defined?(::System::Fleet::EventBroadcaster)

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
