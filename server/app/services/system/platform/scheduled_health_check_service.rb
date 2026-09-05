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
    #   - ATTRIBUTED: writes an Ai::AgentExecution row naming the agent that
    #     performed the check — the account's OWN System Concierge CLONE,
    #     resolved via Ai::Agent.resolve_concierge_for, which prefers the
    #     account's row but falls back to the GLOBAL canonical when no clone
    #     exists yet. That fallback is deliberately refused here: "a global
    #     canonical never executes" is the platform's ratified design, so an
    #     account with no materialised Concierge clone is simply skipped for
    #     this tick, rather than crediting the canonical or minting a clone as
    #     a side effect of a health check.
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
      # mis-configured account (no concierge clone, no resolvable provider or
      # creator) must not take down the sweep for every other account.
      def run_if_due!
        return { account_id: @account.id, ran: false, reason: "not_due" } unless due?

        agent = concierge_clone
        return { account_id: @account.id, ran: false, reason: "no_concierge_clone" } unless agent

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

      # The account's OWN concierge clone — never the global canonical
      # (account_id nil). resolve_concierge_for prefers the clone but falls
      # back to the canonical when none exists yet; that fallback is refused
      # here on purpose (see class comment).
      def concierge_clone
        agent = ::Ai::Agent.resolve_concierge_for(@account.id)
        agent if agent&.account_id.present?
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
