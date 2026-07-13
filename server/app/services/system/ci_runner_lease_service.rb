# frozen_string_literal: true

module System
  # inc3 lease orchestration (campaign 019f5885). See System::CiRunnerLease for
  # the bookkeeping-not-isolation semantics.
  #
  #   lease!   : acquire a warm builder from a pool → correlate it to the Gitea
  #              GitRunner it self-registered → return the (registered) lease.
  #   release! : deregister the runner from Gitea → recycle the pooled instance
  #              (terminate + backfill) so no state/credential bleeds.
  #
  # Raises typed LeaseError subclasses; the MCP handler maps them to error_result.
  class CiRunnerLeaseService
    class LeaseError < StandardError; end
    class RunnerBusyError < LeaseError; end
    class PoolUnavailableError < LeaseError; end

    # api_scope symbol (:repo|:org|:admin) → Devops::GitRunner.runner_scope string.
    API_SCOPE_TO_RUNNER_SCOPE = { repo: "repository", org: "organization", admin: "enterprise" }.freeze

    DEFAULT_LEASE_TTL_SECONDS     = 2 * 60 * 60 # 2h — pre-inc4 this is the only auto-release, so keep it short
    DEFAULT_CORRELATE_TIMEOUT_SEC = 20
    CORRELATE_INTERVAL_SEC        = 2

    def self.lease!(account:, **kwargs)
      new(account: account).lease!(**kwargs)
    end

    def self.release!(account:, lease:, force: false)
      new(account: account).release!(lease, force: force)
    end

    def self.ensure_standing_capacity!(account:, **kwargs)
      new(account: account).ensure_standing_capacity!(**kwargs)
    end

    def initialize(account:)
      @account = account
    end

    # Acquire a warm builder, create the lease, and (bounded) correlate it to
    # its GitRunner row. Leaves the lease in `leased` if the runner hasn't
    # surfaced within the timeout — the sweep keeps advancing it.
    def lease!(pool_name: nil, pool_id: nil, purpose: "generic", labels: nil,
               workflow_run_id: nil, workflow_run_repo: nil, correlate_timeout: nil)
      resolver = CiRunnerRegistrationResolver.new(account: @account)

      instance = acquire_instance(pool_name: pool_name, pool_id: pool_id)

      lease = build_lease(instance, resolver, purpose: purpose, labels: labels,
                                              workflow_run_id: workflow_run_id,
                                              workflow_run_repo: workflow_run_repo)

      correlate!(lease, resolver, timeout: correlate_timeout || default_correlate_timeout)
      lease
    end

    # Correlate a `leased` lease to its GitRunner row and `register!` it. Bounded
    # by `timeout` seconds (0 = single attempt). Safe to call repeatedly (the
    # sweep does); a no-op once the lease has left `leased`.
    def correlate!(lease, resolver = nil, timeout: 0)
      return lease unless lease.leased?

      resolver ||= CiRunnerRegistrationResolver.new(account: @account)
      deadline = monotonic + timeout.to_i

      loop do
        runner = find_runner(lease.runner_name)
        unless runner
          sync_scope_runners(resolver)
          runner = find_runner(lease.runner_name)
        end

        if runner
          lease.register!(runner)
          return lease
        end

        break if monotonic >= deadline

        sleep(CORRELATE_INTERVAL_SEC)
      end

      lease
    end

    # Deregister the runner + recycle the pooled instance. Refuses a busy runner
    # unless force: true (never kill live work — mirrors the pool's flag-not-kill
    # doctrine). Idempotent on a finished lease.
    def release!(lease, force: false)
      return lease if lease.finished?

      runner = current_runner(lease)
      if runner&.busy? && !force
        raise RunnerBusyError,
              "runner '#{lease.runner_name}' is busy; pass force: true to release a running build"
      end

      lease.begin_release! if lease.may_begin_release?
      deregister_runner(lease, runner)
      recycle_instance(lease)
      lease.complete_release! if lease.may_complete_release?
      lease
    rescue AASM::InvalidTransition => e
      raise LeaseError, "lease ##{lease.id} not releasable from #{lease.status}: #{e.message}"
    end

    # Read/report-only in inc3 (Fable P1): only nudges the pool target when the
    # standing-capacity SiteSetting is explicitly present, so it never fights
    # operator pool edits or InstancePoolReplenisherJob. Full posture is inc7.
    def ensure_standing_capacity!(pool_name:, arch: "amd64")
      pool = find_pool(pool_name)
      configured = ::SiteSetting.get("system.ci_builder.standing_capacity.#{arch}").presence&.to_i

      report = {
        pool: pool&.name,
        pool_found: !pool.nil?,
        arch: arch,
        configured_standing_capacity: configured,
        current_target_size: pool&.target_size,
        ready_count: pool&.ready_count,
        active_leases: CiRunnerLease.for_account(@account).active.count
      }

      if configured && pool && pool.target_size != configured
        pool.update!(target_size: configured)
        report[:adjusted_target_size] = configured
      end

      report
    end

    private

    def acquire_instance(pool_name:, pool_id:)
      InstancePoolService.acquire!(account: @account, pool_name: pool_name, pool_id: pool_id)
    rescue InstancePoolService::PoolError => e
      raise PoolUnavailableError, e.message
    end

    def build_lease(instance, resolver, purpose:, labels:, workflow_run_id:, workflow_run_repo:)
      CiRunnerLease.create!(
        account: @account,
        node_instance: instance,
        instance_pool: instance.instance_pool,
        status: "leased",
        runner_name: CiRunnerRegistrationResolver.runner_name(instance),
        # BUG FIX (spec-discovered): CiRunnerLease::SCOPES is short-form
        # (repo/org/admin) — API_SCOPE_TO_RUNNER_SCOPE maps to the LONG-form
        # Devops::GitRunner scope strings (repository/organization/enterprise),
        # which never satisfy this model's own inclusion validation. That
        # mapping is for #sync_scope_runners' GitRunner.sync_from_provider
        # call below, not this column — store the resolver's own scope
        # string directly, which already matches CiRunnerLease::SCOPES.
        runner_scope: resolver.scope.to_s,
        runner_labels: Array(labels).presence || [ resolver.label ],
        git_owner: resolver.owner,
        git_repo: resolver.repo,
        purpose: purpose,
        ephemeral: resolver.ephemeral?,
        workflow_run_id: workflow_run_id,
        workflow_run_repo: workflow_run_repo,
        leased_at: Time.current,
        expires_at: Time.current + lease_ttl_seconds
      )
    rescue StandardError => e
      # Never strand a claimed pool member if lease bookkeeping fails.
      return_instance(instance)
      raise LeaseError, "failed to create lease: #{e.message}"
    end

    def deregister_runner(lease, runner)
      return unless runner

      result = ::Devops::RunnerLifecycleService.new(account: @account).delete_runner(runner)
      return unless result.is_a?(Hash) && result[:success] == false

      Rails.logger.warn("[CiRunnerLease##{lease.id}] delete_runner failed: #{result[:error]}")
    end

    def recycle_instance(lease)
      instance = lease.node_instance
      pool = lease.instance_pool
      return unless instance && pool

      instance.reload
      # Caller owns the claimed-state guard (InstancePoolService#release! doesn't
      # re-check): only recycle a still-claimed member, else it's already draining
      # or gone.
      return unless instance.pool_claimed?

      InstancePoolService.release!(instance: instance, pool: pool)
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLease##{lease.id}] pool recycle failed: #{e.message}")
    end

    def return_instance(instance)
      return unless instance&.instance_pool

      instance.reload
      InstancePoolService.release!(instance: instance, pool: instance.instance_pool) if instance.pool_claimed?
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLease] failed to return stranded instance #{instance&.id}: #{e.message}")
    end

    def current_runner(lease)
      return nil if lease.git_runner_id.blank?

      @account.git_runners.find_by(id: lease.git_runner_id)
    end

    def find_runner(name)
      return nil if name.blank?

      @account.git_runners.where(name: name).order(Arel.sql("last_seen_at DESC NULLS LAST")).first
    end

    # Targeted single-scope sync (Fable P1: NOT sync_runners, which walks admin +
    # every repo and skips :org). One Gitea list call for the configured scope.
    def sync_scope_runners(resolver)
      credential = resolver.credential
      return unless credential&.can_be_used?

      client = ::Devops::Git::ApiClient.for(credential)
      return unless client.supports_runners?

      api_scope = resolver.scope
      result = client.list_runners(resolver.owner, resolver.repo, scope: api_scope)
      runners = extract_runners_list(result)
      return unless runners.is_a?(Array)

      model_scope = API_SCOPE_TO_RUNNER_SCOPE[api_scope] || "organization"
      runners.each do |rd|
        data = rd.is_a?(Hash) ? rd.stringify_keys : rd
        ::Devops::GitRunner.sync_from_provider(credential, data, scope: model_scope, repository: nil)
      end
    rescue StandardError => e
      Rails.logger.warn("[CiRunnerLease] scope sync (#{resolver.scope}) failed: #{e.message}")
    end

    # GitHub wraps runners in {runners:}; Gitea/GitLab return a bare array.
    def extract_runners_list(result)
      case result
      when Hash then result[:runners] || result["runners"] || []
      when Array then result
      else []
      end
    end

    def find_pool(pool_name)
      return nil if pool_name.blank?

      ::System::InstancePool.where(account: @account).find_by(name: pool_name)
    end

    def lease_ttl_seconds
      (::SiteSetting.get("system.ci_builder.lease_ttl_seconds").presence || DEFAULT_LEASE_TTL_SECONDS).to_i
    end

    def default_correlate_timeout
      (::SiteSetting.get("system.ci_builder.correlate_timeout_seconds").presence || DEFAULT_CORRELATE_TIMEOUT_SEC).to_i
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
