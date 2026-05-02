# frozen_string_literal: true

module System
  module Fleet
    # Autonomy reconciler for the System extension fleet. Mirrors
    # Trading::OverseerAutonomyService verbatim — same gate_action!, same
    # dedup, same TTL, same ApprovalRequest shape — so the operator approval
    # UI surfaces fleet decisions identically to trading decisions.
    #
    # Reference: Golden Eclipse plan M7. The cross-cutting design property is
    # that nothing in this service hardcodes "fleet" semantics; only the
    # ADVANCEMENT_ACTIONS set, the source_type, and the chain lookup are
    # domain-specific. Everything else follows the trading pattern row-for-row.
    class FleetAutonomyService
      attr_reader :account, :agent, :role

      # Actions that represent fleet-wide advancement (live promotion,
      # fleet upgrade roll, region expansion). These get the longer TTL
      # (4h) so operators have meaningful review time.
      ADVANCEMENT_ACTIONS = %w[
        system.module_promote_to_live
        system.fleet_rolling_upgrade
        system.region_expansion
      ].freeze

      SOURCE_TYPE = "system_fleet"

      def initialize(account:, agent:, role: nil)
        @account = account
        @agent = agent
        @role = role
        @policy_service = ::Ai::InterventionPolicyService.new(account: account)
      end

      # Class-level entry point for the periodic reconcile tick. Finds the
      # fleet autonomy agent for the account, runs every sensor, routes
      # signals through the DecisionEngine, and records outcomes via the
      # LearningExtractor. Returns a structured tick summary.
      def self.tick!(account:)
        agent = account.ai_agents.find_by(agent_type: "monitor", name: "Fleet Autonomy")
        return { ok: false, reason: "Fleet Autonomy agent not seeded for account" } unless agent

        service = new(account: account, agent: agent)
        service.tick!
      end

      def tick!
        tick_correlation = "tick:#{SecureRandom.hex(8)}"
        ::System::Fleet::EventBroadcaster.emit!(
          account: account, kind: "fleet.tick_started", severity: :low,
          payload: { agent_id: agent.id }, source: "fleet_autonomy", correlation_id: tick_correlation
        )

        signals = collect_signals
        engine = DecisionEngine.new(autonomy_service: self)
        decisions = engine.decide_all(signals)
        LearningExtractor.record_tick!(account: account, decisions: decisions)

        # After decisions land, emit fleet-side stigmergic signals so trading
        # + other subsystems can perceive the current pressure state. Best-effort.
        ::System::Fleet::PressureEmitter.emit_for_account!(account: account) if defined?(::System::Fleet::PressureEmitter)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account, kind: "fleet.tick_complete", severity: :low,
          payload: {
            signal_count: signals.size,
            decision_count: decisions.size,
            by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size)
          },
          source: "fleet_autonomy", correlation_id: tick_correlation
        )

        {
          ok: true,
          signal_count: signals.size,
          decision_count: decisions.size,
          by_kind: decisions.group_by { |d| d[:signal_kind] }.transform_values(&:size),
          by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size),
          correlation_id: tick_correlation
        }
      end

      def collect_signals
        signals = []
        SENSORS.each do |sensor_class|
          signals.concat(sensor_class.new(account: account).sense)
        rescue StandardError => e
          Rails.logger.error("[FleetAutonomy] sensor #{sensor_class.name} failed: #{e.message}")
        end
        signals
      end

      SENSORS = [
        ::System::Fleet::Sensors::InstanceStatusSensor,
        ::System::Fleet::Sensors::ModuleDriftSensor,
        ::System::Fleet::Sensors::CertificateExpirySensor,
        ::System::Fleet::Sensors::ModulePromotionSensor,
        ::System::Fleet::Sensors::ConfigDriftSensor,
        ::System::Fleet::Sensors::SloViolationSensor,
        ::System::Fleet::Sensors::HoneypotAccessSensor,
        ::System::Fleet::Sensors::TradingPressureSensor
      ].freeze

      def permitted_actions
        @permitted_actions ||= ::Ai::InterventionPolicy
          .where(ai_agent_id: agent.id, scope: "agent", is_active: true)
          .pluck(:action_category)
      end

      def self.all_fleet_actions(account)
        ::Ai::InterventionPolicy
          .where(account: account, scope: "agent", is_active: true)
          .where("action_category LIKE 'system.%'")
          .distinct
          .pluck(:action_category)
      end

      def gate_action!(action_category, metadata: {}, reasoning: {}, temporal_context: {})
        unless permitted_actions.include?(action_category)
          Rails.logger.warn("[FleetAutonomy] Action '#{action_category}' not in agent '#{agent.name}' policies — blocked")
          return { decision: :blocked, reason: "not_permitted" }
        end

        # Per-module consent budget check — applied before policy resolution.
        # When the budget is exhausted, the action is forced through
        # require_approval regardless of policy. Module-less actions skip.
        consent_module_id = metadata&.dig("module_id") || metadata&.dig(:module_id) ||
                            metadata&.dig("payload", "module_id") || metadata&.dig(:payload, :module_id)
        consent = ::System::Fleet::ConsentBudgetService.check_and_consume!(module_id: consent_module_id)
        unless consent.allowed
          Rails.logger.info("[FleetAutonomy] Consent budget exhausted for #{action_category}: #{consent.reason}")
          # Force into require_approval pathway — operator must explicitly
          # extend the budget via Module Detail UI or by approving the request.
          request = create_pending_approval(
            action_category: action_category,
            metadata: metadata.merge("budget_exhaustion" => consent.reason),
            reasoning: reasoning,
            temporal_context: temporal_context
          )
          return { decision: :pending, gate: "consent_budget_exhausted",
                   decision_record: request, budget_reason: consent.reason }
        end

        result = @policy_service.resolve(action_category: action_category, agent: @agent)

        case result[:policy]
        when "auto_approve"
          { decision: :proceed, gate: "auto_approve" }
        when "notify_and_proceed"
          notify_action(action_category, metadata: metadata, reasoning: reasoning)
          { decision: :proceed, gate: "notify_and_proceed" }
        when "require_approval"
          request = create_pending_approval(
            action_category: action_category,
            metadata: metadata,
            reasoning: reasoning,
            temporal_context: temporal_context
          )
          { decision: :pending, gate: "require_approval", decision_record: request }
        when "block", "silent"
          { decision: :blocked, gate: result[:policy] }
        else
          { decision: :blocked, gate: "unknown_policy" }
        end
      end

      def policy_for(action_category)
        @policy_service.resolve(action_category: action_category, agent: @agent)
      end

      def all_policies
        permitted_actions.each_with_object({}) do |action, hash|
          hash[action] = policy_for(action)
        end
      end

      private

      def notify_action(action_category, metadata:, reasoning:)
        Rails.logger.info("[FleetAutonomy] Auto-execute: #{action_category} — #{reasoning[:summary]&.truncate(120)}")
      end

      def decision_ttl_for(action_category)
        ADVANCEMENT_ACTIONS.include?(action_category) ? 4.hours : 1.hour
      end

      # Dedup key resolution. Different fleet actions key off different
      # metadata fields — instance_id for instance-class actions, template_id
      # for template-class actions, module_id for promotion. Returns
      # ["request_data->'payload'->>'KEY' = ?", value] pairs to merge into
      # the WHERE clause.
      def dedup_key_for(action_category, metadata)
        case action_category
        when "system.instance_reprovision", "system.instance_reboot",
             "system.instance_terminate", "system.cert_rotate", "system.cert_revoke"
          key_value(metadata, "instance_id")
        when "system.module_promote_to_live", "system.module_assign"
          key_value(metadata, "module_id") || key_value(metadata, "module_version_id")
        when "system.fleet_rolling_upgrade", "system.region_expansion",
             "system.capacity_resize"
          key_value(metadata, "template_id")
        when "system.cve_remediate"
          key_value(metadata, "cve_id")
        end
      end

      def key_value(metadata, name)
        v = metadata&.dig(name) || metadata&.dig(name.to_sym)
        return nil if v.blank?
        [name, v.to_s]
      end

      def create_pending_approval(action_category:, metadata:, reasoning:, temporal_context:)
        return nil unless defined?(::Ai::ApprovalRequest)

        request_data = {
          "action_category" => action_category,
          "payload" => metadata.deep_stringify_keys,
          "reasoning" => reasoning.deep_stringify_keys,
          "temporal_context" => temporal_context.deep_stringify_keys,
          "agent_role" => @role
        }

        # Specific dedup based on the action's natural key (instance/template/module/cve).
        if (key = dedup_key_for(action_category, metadata))
          name, value = key
          existing = pending_fleet_approvals
            .where("request_data->>'action_category' = ?", action_category)
            .where("request_data->'payload'->>? = ?", name, value)
            .first
          if existing
            existing.update!(request_data: request_data,
                             description: reasoning[:summary] || reasoning["summary"])
            return existing
          end

          if recently_rejected_approval?(action_category,
              ["request_data->>'action_category' = ? AND request_data->'payload'->>? = ?",
               action_category, name, value])
            Rails.logger.info("[FleetAutonomy] Skipped #{action_category} for #{name}=#{value} — rejected within cooldown")
            return nil
          end
        end

        # Fallback: action-level cooldown for actions without natural dedup keys.
        if recently_rejected_approval?(action_category,
            ["request_data->>'action_category' = ?", action_category])
          Rails.logger.info("[FleetAutonomy] Skipped #{action_category} — rejected within cooldown")
          return nil
        end

        chain = fleet_approval_chain
        return nil unless chain

        chain.create_request!(
          source_type: SOURCE_TYPE,
          source_id: action_category,
          description: (reasoning[:summary] || reasoning["summary"] || action_category).to_s.truncate(500),
          request_data: request_data
        )
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] Failed to create approval request: #{e.message}")
        nil
      end

      def pending_fleet_approvals
        ::Ai::ApprovalRequest
          .pending
          .where(account: @account, source_type: SOURCE_TYPE)
          .where("expires_at IS NULL OR expires_at > ?", Time.current)
      end

      def recently_rejected_approval?(action_category, match_conditions)
        cooldown = decision_ttl_for(action_category)

        ::Ai::ApprovalRequest
          .rejected
          .where(account: @account, source_type: SOURCE_TYPE)
          .where("completed_at > ?", cooldown.ago)
          .where(match_conditions)
          .exists?
      end

      def fleet_approval_chain
        @fleet_approval_chain ||= ::Ai::ApprovalChain
          .where(account: @account, trigger_type: "autonomy_action", status: "active")
          .find_by("name ILIKE ?", "%fleet%") ||
          ::Ai::ApprovalChain.where(account: @account, trigger_type: "autonomy_action",
                                    status: "active").first
      end
    end
  end
end
