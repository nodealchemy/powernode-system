# frozen_string_literal: true

module System
  # Improvement discovery's executor (campaign 01a08c9b D1b), registered under
  # the core behaviour-provider key :lint_discovery_executor.
  #
  # Core (Ai::Improvement::DiscoveryRunService) hands it one account's
  # repositories per tick. It leases ONE runner from THAT account's own pool
  # and sends a ci.lint_discovery System::Task to that exact NodeInstance. The
  # agent pulls each repository's read credential over its own mTLS identity
  # from the lease-gated config/ci_lint_context endpoint, lints each repository
  # with the repository's own bundle, and posts the raw output to the
  # lease-gated config/ci_lint_result endpoint, which hands it to core
  # DiscoveryRunService#ingest!. The sweep releases the lease when the task
  # finishes, or at the lease's deadline, and records every repository that
  # never reported as not measured.
  #
  # Why not a Gitea workflow: every act runner registers with the same global
  # label, so a job dispatched to a label can start on any tenant's runner, and
  # workflow inputs are stored unmasked. Neither may carry a tenant's code or
  # credential.
  #
  # Rulings it carries:
  #   (b) the tenant's own pool only: the pool is looked up inside the account,
  #       and with none the unit is skipped with a named reason;
  #   (c) one lease per account per tick, and never a second while one is live.
  class LintDiscoveryExecutor
    PURPOSE = "lint_discovery"
    COMMAND = "ci.lint_discovery"

    # Raised when the leased runner's agent is not reporting, so an on-node task
    # would be queued for a node that will never pull it (IMP-fb05226e89cb).
    # Not a dispatch failure: dispatch! turns it into a named skip and releases
    # the lease, so the next tick can try a live member.
    DeadTargetError = Class.new(StandardError)

    # The pool NAME is operator configuration; the pool is always the account's
    # own. No default: an install that has not chosen a builder pool runs no
    # discovery, and says so.
    POOL_SETTING = "system.lint_discovery.pool_name"

    # The lease's deadline, which replaces D1's in-process linter timeout. A
    # runner that has not reported every repository by then is recorded as not
    # measured, and its lease is released (CiRunnerLeaseSweepService).
    DEADLINE_SETTING = "system.lint_discovery.deadline_seconds"
    DEFAULT_DEADLINE_SECONDS = 3600

    # Where the runner puts each repository's workdir. Unset, the agent
    # resolves a disk-backed default itself (the node's persistent mount, else
    # /var/lib) and refuses one on a RAM-backed filesystem.
    WORKDIR_BASE_SETTING = "system.lint_discovery.workdir_base"

    # The runner refuses any base outside these (its check is authoritative).
    # The setting is checked when written too (D1b security R1), so a bad
    # value is refused by name instead of failing every lint task.
    WORKDIR_BASE_PREFIXES = %w[/persist/ /srv/ /var/lib/].freeze

    def self.workdir_base
      ::SiteSetting.get(WORKDIR_BASE_SETTING).presence
    end

    # nil when `value` is an acceptable workdir base, else why it is not.
    def self.workdir_base_problem(value)
      path = value.to_s
      clean = path.start_with?("/") && !path.match?(/[[:cntrl:]]/) && Pathname.new(path).cleanpath.to_s == path
      return nil if clean && WORKDIR_BASE_PREFIXES.any? { |prefix| path.start_with?(prefix) }

      "must be a clean absolute path strictly below one of #{WORKDIR_BASE_PREFIXES.join(', ')} " \
        "(the runner refuses anything else)"
    end

    def self.dispatch!(account:, repositories:)
      new(account: account).dispatch!(repositories)
    end

    def self.deadline_seconds
      configured = ::SiteSetting.get(DEADLINE_SETTING).to_i
      configured.positive? ? configured : DEFAULT_DEADLINE_SECONDS
    end

    def initialize(account:)
      @account = account
    end

    # @return [Hash] the core executor contract: status "dispatched" |
    #   "skipped" | "failed", reason:, run_ref: (the lease id), repositories:
    def dispatch!(repositories)
      pool_name = ::SiteSetting.get(POOL_SETTING).presence
      return skipped("no_ci_runner_pool_configured") if pool_name.nil?

      pool = ::System::InstancePool.for_account(@account).find_by(name: pool_name)
      return skipped("no_ci_runner_pool") if pool.nil?

      return skipped("discovery_already_running") if active_lease?

      rows, runnable = partition(repositories)
      return skipped("no_analyzable_repository", rows) if runnable.empty?

      lease = lease!(pool)
      return skipped("no_ready_runner", rows) if lease.nil?

      task = create_task!(lease, runnable)
      lease.update!(
        build_task_id: task.id,
        expires_at: Time.current + self.class.deadline_seconds,
        metadata: lease.metadata.merge(
          "repository_ids" => runnable.map(&:id),
          "reported_repository_ids" => []
        )
      )
      { status: "dispatched", run_ref: lease.id, repositories: rows }
    rescue DeadTargetError => e
      release_stranded(lease) if lease
      Rails.logger.info("[LintDiscovery] runner agent not live for account #{@account.id}: #{e.message}")
      skipped("runner_agent_not_live", rows)
    rescue StandardError => e
      release_stranded(lease) if lease
      # The class only: core writes this to an audit row.
      Rails.logger.error("[LintDiscovery] dispatch failed for account #{@account.id}: #{e.class}")
      { status: "failed", reason: e.class.name, repositories: rows }.compact
    end

    private

    def active_lease?
      ::System::CiRunnerLease.for_account(@account).active.where(purpose: PURPOSE).exists?
    end

    # A repository with no usable credential cannot be cloned on the runner.
    def partition(repositories)
      rows = []
      runnable = []
      repositories.each do |repo|
        if repo.credential&.can_be_used?
          runnable << repo
          rows << { id: repo.id, status: "dispatched" }
        else
          rows << { id: repo.id, status: "skipped", reason: "no_repository_credential" }
        end
      end
      [ rows, runnable ]
    end

    def lease!(pool)
      ::System::CiRunnerLeaseService.lease!(account: @account, pool_id: pool.id, purpose: PURPOSE,
                                             correlate_timeout: 0)
    rescue ::System::CiRunnerLeaseService::LeaseError => e
      Rails.logger.info("[LintDiscovery] no runner for account #{@account.id} (#{e.class})")
      nil
    end

    # The task names the repositories and nothing else. A credential is never
    # in a task: the agent pulls it from the lease-gated context endpoint.
    #
    # An on-node task is PULLED, so the agent has to be reporting for it to run
    # at all. InstancePoolService#acquire! already refuses a member whose
    # #on_node_dispatch_refusal answers, but that is liveness at CLAIM time and
    # the lease outlives the claim — so this consults the predicate itself and
    # fails closed, rather than holding a runner while queueing work nothing
    # will pull. The census (on_node_task_producer_census_spec) reads this
    # consult as this producer's :gated evidence.
    def create_task!(lease, repositories)
      refusal = lease.node_instance.on_node_dispatch_refusal
      raise DeadTargetError, refusal if refusal

      ::System::Task.create!(
        account: @account,
        operable: lease.node_instance,
        command: COMMAND,
        status: "pending",
        options: { "run_ref" => lease.id, "repository_ids" => repositories.map(&:id) }
      )
    end

    def release_stranded(lease)
      ::System::CiRunnerLeaseService.release!(account: @account, lease: lease, force: true)
    rescue StandardError => e
      Rails.logger.warn("[LintDiscovery] release after a failed dispatch failed: #{e.class}")
    end

    def skipped(reason, rows = nil)
      { status: "skipped", reason: reason, repositories: rows }.compact
    end
  end
end
