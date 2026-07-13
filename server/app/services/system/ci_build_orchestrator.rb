# frozen_string_literal: true

module System
  # Thin orchestrator (campaign 019f5885 inc4 — dual-run seam + build
  # orchestrator) that ties the inc3 lease primitive (CiRunnerLeaseService) to
  # a module build: lease an ephemeral fleet runner → dispatch the build
  # pinned to that runner's label (ModuleBuildDispatchService's opt-in
  # runner_label: input) → best-effort correlate the Gitea workflow run the
  # dispatch created → attach the run id to the lease so the inc3 sweep
  # (CiRunnerLeaseSweepService) releases + recycles the runner once that run
  # reaches a terminal status.
  #
  # Mirrors System::BootImage::UpgradeDispatcher's shape: a thin `.dispatch!`
  # class method + a Result struct, one seam every caller goes through.
  #
  # Dual-run: the static ubuntu-24.04 path stays the default everywhere else
  # (ModuleBuildDispatchService.dispatch_build! with no runner_label) — this
  # orchestrator IS the opt-in fleet path; nothing routes through it unless a
  # caller explicitly asks to lease first.
  class CiBuildOrchestrator
    Result = Struct.new(:ok?, :lease, :run_id, :dispatch_id, :correlated, :error, keyword_init: true)

    # Bounded best-effort retry for correlating the dispatched build to the
    # Gitea workflow run it created (Gitea's workflow_dispatch POST is
    # fire-and-forget — no run id in the response). Operator-overridable via
    # SiteSetting, same pattern as CiRunnerLeaseService's own correlate
    # timeout — never a bare hardcoded cap.
    DEFAULT_RUN_CORRELATE_TIMEOUT_SEC = 20
    RUN_CORRELATE_INTERVAL_SEC        = 2

    def self.dispatch!(account:, node_module:, pool_name: nil, pool_id: nil, ref: "main",
                        correlate_timeout: nil, dispatch_marker: nil)
      new(account: account, node_module: node_module, pool_name: pool_name, pool_id: pool_id,
          ref: ref, correlate_timeout: correlate_timeout, dispatch_marker: dispatch_marker).dispatch!
    end

    def initialize(account:, node_module:, pool_name: nil, pool_id: nil, ref: "main",
                   correlate_timeout: nil, dispatch_marker: nil)
      @account = account
      @node_module = node_module
      @pool_name = pool_name
      @pool_id = pool_id
      @ref = ref
      @correlate_timeout = correlate_timeout
      # Reserved for callers that want to disambiguate concurrent dispatches
      # against the same module/ref beyond the timestamp gate below (not
      # required for correlation itself — the dispatch timestamp + event +
      # ref triad is sufficient in the common case).
      @dispatch_marker = dispatch_marker
    end

    def dispatch!
      lease = ::System::CiRunnerLeaseService.lease!(
        account: @account, pool_name: @pool_name, pool_id: @pool_id,
        purpose: "module_build", correlate_timeout: @correlate_timeout
      )

      runner_label = Array(lease.runner_labels).first
      # Floor to whole seconds: Gitea's run created_at has only second
      # granularity, so comparing it against a sub-second Time.current could
      # false-negative a genuine same-second match (floor is monotonic, so
      # this floor can only ever make the >= check in find_matching_run_id
      # MORE permissive, never admit a run from before the real dispatch).
      dispatch_started_at = Time.current.change(usec: 0)

      result = ::System::ModuleBuildDispatchService.dispatch_build!(
        node_module: @node_module, ref: @ref, runner_label: runner_label
      )

      unless result.ok?
        release_stranded_lease(lease)
        return Result.new(ok?: false, lease: lease, dispatch_id: result.dispatch_id, error: result.error)
      end

      owner, repo = split_repo(@node_module.gitea_repo_full_name)
      run_id = correlate_run(owner: owner, repo: repo, dispatch_started_at: dispatch_started_at)

      if run_id
        lease.update!(workflow_run_id: run_id, workflow_run_repo: "#{owner}/#{repo}")
      end

      Result.new(
        ok?: true, lease: lease, run_id: run_id, dispatch_id: result.dispatch_id,
        correlated: run_id.present?
      )
    end

    private

    # A failed dispatch means the leased runner never got any work — never
    # strand it waiting out its full TTL. force: true because at this point
    # the runner (if even registered yet) cannot be busy with THIS build.
    def release_stranded_lease(lease)
      ::System::CiRunnerLeaseService.release!(account: @account, lease: lease, force: true)
    rescue StandardError => e
      Rails.logger.warn("[CiBuildOrchestrator] release after failed dispatch failed: #{e.message}")
    end

    def split_repo(full_name)
      return [ nil, nil ] if full_name.blank?

      full_name.to_s.split("/", 2)
    end

    # Best-effort: Gitea's workflow_dispatch POST returns no run id (see
    # ModuleBuildDispatchService::GiteaDispatchAdapter), so the created run is
    # found by listing the repo's recent runs and matching on
    # (workflow_dispatch event, this ref, created no earlier than the
    # dispatch). Never raises — a correlation miss just leaves
    # workflow_run_id nil; the lease's own TTL/sweep still reclaims it.
    def correlate_run(owner:, repo:, dispatch_started_at:)
      return nil if owner.blank? || repo.blank?

      credential = resolver.credential
      return nil unless credential&.can_be_used?

      client = ::Devops::Git::ApiClient.for(credential)
      return nil unless client.respond_to?(:list_workflow_runs)

      deadline = monotonic + run_correlate_timeout
      loop do
        run_id = find_matching_run_id(client, owner, repo, dispatch_started_at)
        return run_id if run_id

        break if monotonic >= deadline

        sleep(RUN_CORRELATE_INTERVAL_SEC)
      end

      nil
    rescue StandardError => e
      Rails.logger.warn("[CiBuildOrchestrator] run correlation failed: #{e.message}")
      nil
    end

    def find_matching_run_id(client, owner, repo, dispatch_started_at)
      runs = Array(client.list_workflow_runs(owner, repo))
      candidates = runs.select do |r|
        created_at = run_created_at(r)
        run_field(r, "event") == "workflow_dispatch" &&
          run_field(r, "head_branch") == @ref &&
          created_at.present? && created_at >= dispatch_started_at
      end
      newest = candidates.max_by { |r| run_created_at(r) }
      newest && run_field(newest, "id")
    end

    def run_field(run, key)
      run[key.to_sym].nil? ? run[key.to_s] : run[key.to_sym]
    end

    def run_created_at(run)
      raw = run_field(run, "created_at")
      return nil if raw.blank?
      return raw if raw.is_a?(Time)

      Time.zone.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def resolver
      @resolver ||= ::System::CiRunnerRegistrationResolver.new(account: @account)
    end

    def run_correlate_timeout
      (::SiteSetting.get("system.ci_builder.run_correlate_timeout_seconds").presence || DEFAULT_RUN_CORRELATE_TIMEOUT_SEC).to_i
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
