# frozen_string_literal: true

module System
  module Platform
    # THE scheduled, attributed, persisted platform-health duty.
    #
    # Campaign 01a07025 increment 3 (agent duties). The operator asked for
    # agents "responsible for regularly checking the health of the various
    # components." System::Platform::CompositeHealthProbe already answers
    # that correctly (offer 01a07024-d980), and
    # System::Ai::Skills::PlatformMaintenanceExecutor already exposes it as
    # the `health_check` action — but the increment-3 investigation found
    # neither is ever invoked on a schedule: the executor's health_check
    # branch has no sensor binding in DecisionEngine::SIGNAL_BINDINGS and no
    # cron, and the dashboard's own path
    # (Api::V1::System::Platform::HealthController#show) deliberately calls
    # `.call`, not `.call_and_persist!`, because it is a per-viewer 30s poll.
    # So the capability existed, worked, and had never once run unattended.
    #
    # THIS SERVICE closes exactly that gap, and only that gap. Filed
    # separately (not fixed here — out of scope for this increment): the
    # unrelated duty-cycle plane (Ai::Autonomy::DutyCycleService#execute_cycle
    # has zero callers anywhere; Ai::Autonomy::ClosureDriverService is
    # cron-wired but gated by a SiteSetting no seed ever sets, and even
    # enabled its eligibility query requires an Ai::AgentGoal nothing creates).
    #
    #   - SCHEDULED: ticked by SystemPlatformHealthSweepJob (worker cron), but
    #     the cadence that decides whether a given tick DOES anything is read
    #     from the `#{INTERVAL_SETTING}` SiteSetting, not baked into the cron
    #     frequency — "no hardcoded intervals" is a standing repo rule
    #     (feedback-no-hardcoded-budgets-configurable). DEFAULT_INTERVAL_MINUTES
    #     is the fallback when the setting is unset, never the only value. The
    #     cron itself ticks more often than the default interval purely so a
    #     narrowed setting takes effect promptly (see sidekiq_system.yml); this
    #     service is what decides whether a tick is a no-op.
    #   - ATTRIBUTED: writes an Ai::AgentExecution row naming the agent this
    #     executor is ACTUALLY BOUND TO — discovered through
    #     System::Ai::Skills::SkillBindings itself (the same registry
    #     SkillBindingsReconciler materialises into Ai::AgentSkill rows),
    #     never through a second, independent resolver.
    #
    #     An earlier version of this service called
    #     Ai::Agent.resolve_concierge_for, which resolves the account's
    #     `is_concierge`-flagged agent — Powernode Assistant, a CORE agent
    #     with no relationship to this executor at all. The executor
    #     `binds_to "concierge"`, and SkillBindings::AGENT_ALIASES maps that
    #     token to the source_key "system-concierge" (the system extension's
    #     own concierge canonical, mid-rename to a different display name and
    #     slug as of this writing — see the source_key comment below for why
    #     that rename cannot break this). Two different lookups, two
    #     different agents, one attribution row that would have named the
    #     wrong one — the exact duplication the front-door consolidation
    #     campaign exists to remove, caught here as a live mis-attribution.
    #
    #     So the resolution is now: ask SkillBindings which source_key(s)
    #     PlatformMaintenanceExecutor is registered against (never hardcoded
    #     here — a future `binds_to` change cannot silently re-point this),
    #     resolve the GLOBAL canonical by that source_key (never slug, never
    #     display name — both are mid-rename; source_key is "explicitly set
    #     and derived from nothing", the one identifier a rename cannot
    #     touch), then ask Ai::Agents::AccountPrincipalResolver.existing —
    #     the platform's ONE resolver of "which row acts for canonical X in
    #     account Y" — for the account's clone, READ-ONLY (never minting).
    #     No clone yet is simply skipped for this tick, rather than crediting
    #     the canonical or minting one as a side effect of a health check:
    #     "a global canonical never executes" is the platform's ratified
    #     design.
    #
    #     This is the piece missing everywhere else, too, not just here: every
    #     autonomous fleet-tick remediation already writes an agent_id into a
    #     System::FleetEvent PAYLOAD field
    #     (System::Ai::Skills::BaseSkillExecutor#emit_audit_event!), but
    #     nothing writes the Ai::AgentExecution row that actually counts as
    #     "this agent did work" for trust scoring, cost tracking, or an
    #     execution-history view. This service adds that row for THIS one
    #     duty. It does not touch BaseSkillExecutor or
    #     System::Fleet::DecisionEngine — both out of scope for this
    #     increment, and the fleet services tree is a different lane's.
    #   - PERSISTED: invokes PlatformMaintenanceExecutor's `health_check`
    #     action exactly as a human chat request would, which calls
    #     CompositeHealthProbe#call_and_persist! — the SAME not_measured
    #     discipline that class already carries is untouched by this service;
    #     nothing here re-implements or approximates a subsystem check, so it
    #     survives being called by a scheduler exactly as it survives being
    #     called by a person.
    #
    # NOT expensive: `gated: true` (this scheduler's own decision to run a
    # deterministic, read-only probe on cadence IS the decision — the same
    # precedent BaseSkillExecutor's own docs name for the db/seeds/smoke_test_*
    # scripts) skips approval-gate resolution entirely, and neither
    # health_check nor CompositeHealthProbe ever resolves or calls an
    # Ai::Provider — this can never become a model-cost line.
    class ScheduledHealthCheckService
      INTERVAL_SETTING = "system.platform_health_check_interval_minutes"
      DEFAULT_INTERVAL_MINUTES = 15
      EXECUTION_KIND = "scheduled_health_check"

      def self.run_due_accounts!(accounts)
        accounts.map { |account| new(account: account).run_if_due! }
      end

      def initialize(account:)
        @account = account
      end

      # Runs the check if due, else a documented no-op. Never raises: one
      # mis-configured account (no clone of the bound agent yet, no
      # resolvable provider or creator) must not take down the sweep for
      # every other account.
      def run_if_due!
        return { account_id: @account.id, ran: false, reason: "not_due" } unless due?

        agent = bound_agent_clone
        return { account_id: @account.id, ran: false, reason: "no_bound_agent_clone" } unless agent

        run_and_attribute!(agent)
      rescue StandardError => e
        Rails.logger.error("[ScheduledHealthCheck] account=#{@account.id} failed: #{e.class}: #{e.message}")
        { account_id: @account.id, ran: false, reason: "error", error: e.message }
      end

      private

      def interval_minutes
        configured = ::SiteSetting.get(INTERVAL_SETTING)
        configured.present? && configured.to_i.positive? ? configured.to_i : DEFAULT_INTERVAL_MINUTES
      end

      # Safe on a fleet where nothing is configured: an account with no prior
      # snapshot is simply due (nil last-run reads as "run it").
      def due?
        last = ::System::PlatformHealthSnapshot.for_account(@account).recent.first&.captured_at
        last.nil? || last <= interval_minutes.minutes.ago
      end

      # The GLOBAL canonical PlatformMaintenanceExecutor is actually
      # registered against, resolved through the SAME registry
      # SkillBindingsReconciler reads — never a hardcoded source_key, never
      # the executor's `binds_to` label re-derived by hand, so this cannot
      # drift from the reconciler's own answer to "who owns this skill".
      def bound_canonical
        # The bare constant reference forces Rails to autoload
        # PlatformMaintenanceExecutor NOW if it has not been loaded yet in
        # this process — which is what runs its `binds_to` class-body line
        # and registers it with SkillBindings. Referencing the constant only
        # inside the `.find` block below would autoload it too late: `.all`
        # would already have returned its (registration-less) snapshot by
        # the time the block ran.
        executor_class = ::System::Ai::Skills::PlatformMaintenanceExecutor
        registration = ::System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == executor_class }
        return nil unless registration

        agent_keys = registration[:agents]
        # A skill bound to more than one agent has no single owner to credit
        # — refuse to guess rather than pick the first key silently.
        return nil unless agent_keys.size == 1

        ::Ai::Agent.global.find_by(source_key: agent_keys.first)
      end

      # The account's EXISTING clone of the bound canonical — never the
      # canonical itself (a global agent never executes), and never minted
      # here: AccountPrincipalResolver.existing is the read-only twin of the
      # minting `acting`/`for`, exactly because a health check must not have
      # the side effect of creating an agent.
      def bound_agent_clone
        canonical = bound_canonical
        return nil unless canonical

        ::Ai::Agents::AccountPrincipalResolver.existing(canonical, account: @account)
      end

      def run_and_attribute!(agent)
        started_at = Time.current
        executor = ::System::Ai::Skills::PlatformMaintenanceExecutor.new(account: @account, agent: agent, user: nil)
        result = executor.execute(gated: true, action: "health_check")
        completed_at = Time.current

        # health_check wraps the probe result a second layer deep:
        # success(action:, data: probe_result, recommendations:) itself
        # returns { success:, data: { action:, data: probe_result, ... } }.
        probe_result = result.dig(:data, :data) || {}

        record_execution!(agent, result, probe_result, started_at, completed_at)

        { account_id: @account.id, ran: true, agent_id: agent.id,
          success: result[:success], overall: probe_result[:overall] }
      end

      # Mirrors Ai::Autonomy::DutyCycleService#record_action's shape (same
      # provider/user fallback chain, same "an attribution failure must never
      # sink the check itself" posture) — the closest existing precedent for
      # crediting an agent-attributed action outside the chat path.
      def record_execution!(agent, result, probe_result, started_at, completed_at)
        ::Ai::AgentExecution.create!(
          account_id: @account.id,
          ai_agent_id: agent.id,
          ai_provider_id: agent.using_account(@account).resolved_provider&.id || agent.ai_provider_id,
          user_id: agent.creator_id,
          execution_id: SecureRandom.uuid,
          status: result[:success] ? "completed" : "failed",
          execution_context: { "kind" => EXECUTION_KIND },
          input_parameters: { "action" => "health_check", "source" => EXECUTION_KIND },
          output_data: { "overall" => probe_result[:overall], "snapshot_id" => probe_result[:snapshot_id] }.compact,
          started_at: started_at,
          completed_at: completed_at,
          duration_ms: ((completed_at - started_at) * 1000).round
        )
      rescue StandardError => e
        Rails.logger.warn("[ScheduledHealthCheck] failed to record attribution for agent #{agent.id}: #{e.message}")
      end
    end
  end
end
