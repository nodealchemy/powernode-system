# frozen_string_literal: true

module System
  module CveOps
    # Autonomy tick service for the CVE Responder agent. Mirrors
    # System::Fleet::FleetAutonomyService shape — same DecisionEngine
    # collaboration, same gate_action! contract, same ApprovalRequest
    # creation — so the operator approval UI surfaces CVE decisions
    # identically to fleet decisions.
    #
    # Domain-specific bits:
    #   - SOURCE_TYPE = "system_cve_responder" so approvals don't merge
    #     into the fleet queue.
    #   - SENSORS list contains only CVE-driven sensors (CvePublishedSensor,
    #     CriticalUpgradeAvailableSensor).
    #   - cve_approval_chain matches ILIKE "%cve%" to pick up the 8h-
    #     timeout chain seeded by system_cve_responder_agent.rb.
    #   - dedup_key_for is restricted to CVE-side action categories.
    #
    # Duplicates a portion of FleetAutonomyService's gate machinery
    # intentionally during the 2026-05-10 agent-split rollout. A future
    # refactor can extract a shared AutonomyService base class once the
    # other domain agents (SDWAN, Disk Image, Runtime Manager) all use
    # the same shape.
    class CveResponderService
      attr_reader :account, :agent, :role

      ADVANCEMENT_ACTIONS = %w[
        system.cve_remediate
        system.cve_auto_remediate
        system.module_critical_upgrade_ready
      ].freeze

      SOURCE_TYPE = "system_cve_responder"

      SENSORS = [
        ::System::CveOps::Sensors::CvePublishedSensor,
        ::System::CveOps::Sensors::CriticalUpgradeAvailableSensor
      ].freeze

      def self.tick!(account:)
        agent = account.ai_agents.find_by(agent_type: "monitor", name: "CVE Responder")
        return { ok: false, reason: "CVE Responder agent not seeded for account" } unless agent

        new(account: account, agent: agent).tick!
      end

      def initialize(account:, agent:, role: nil)
        @account = account
        @agent = agent
        @role = role
        @policy_service = ::Ai::InterventionPolicyService.new(account: account)
      end

      def tick!
        tick_correlation = "tick:#{SecureRandom.hex(8)}"
        emit_event(kind: "cve_responder.tick_started", payload: { agent_id: agent.id }, correlation_id: tick_correlation)

        signals = collect_signals
        engine = ::System::Fleet::DecisionEngine.new(autonomy_service: self)
        decisions = engine.decide_all(signals)
        ::System::CveOps::LearningExtractor.record_tick!(account: account, decisions: decisions)
        emit_pressure!(decisions)

        emit_event(
          kind: "cve_responder.tick_complete",
          payload: {
            signal_count: signals.size,
            decision_count: decisions.size,
            by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size)
          },
          correlation_id: tick_correlation
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
          Rails.logger.error("[CveResponder] sensor #{sensor_class.name} failed: #{e.message}")
        end
        signals
      end

      def permitted_actions
        @permitted_actions ||= ::Ai::InterventionPolicy
          .where(ai_agent_id: agent.id, scope: "agent", is_active: true)
          .pluck(:action_category)
      end

      # Same shape as FleetAutonomyService#gate_action! so DecisionEngine
      # can call either interchangeably.
      def gate_action!(action_category, metadata: {}, reasoning: {}, temporal_context: {})
        unless permitted_actions.include?(action_category)
          Rails.logger.warn("[CveResponder] Action '#{action_category}' not in agent policies — blocked")
          return { decision: :blocked, reason: "not_permitted" }
        end

        result = @policy_service.resolve(
          action_category: action_category, agent: @agent
        )

        case result[:policy]
        when "auto_approve"
          dispatch_inline(action_category, metadata, reasoning)
          { decision: :proceed, gate: "auto_approve" }
        when "notify_and_proceed"
          notify_action(action_category, metadata: metadata, reasoning: reasoning)
          dispatch_inline(action_category, metadata, reasoning)
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

      private

      # Inline dispatch path for `proceed` decisions. Critical CVEs land
      # here via the notify_and_proceed policy; non-critical never reach
      # this branch (they go to require_approval and wait for an operator
      # to approve via the standard ApprovalRequest flow).
      #
      # Handles both signal payload shapes:
      #   - cve_critical_published: payload.cve_id (singular)
      #   - module_critical_upgrade_ready: payload.cve_ids (plural — same
      #     module may have multiple open exposures; orchestrate per-CVE)
      def dispatch_inline(action_category, metadata, reasoning)
        return unless action_category == "system.cve_remediate" ||
                      action_category == "system.module_critical_upgrade_ready"

        cve_ids = extract_cve_ids(metadata)
        return if cve_ids.empty?

        orchestrator = ::System::Ai::Skills::CveRemediationOrchestrationExecutor.new(
          account: account, agent: agent, user: nil
        )

        cve_ids.each do |cve_id|
          dispatch_single(orchestrator, cve_id, action_category, metadata)
        end
      rescue StandardError => e
        Rails.logger.error("[CveResponder] inline dispatch failed: #{e.class}: #{e.message}")
      end

      def dispatch_single(orchestrator, cve_id, action_category, metadata)
        result = orchestrator.execute(
          cve_id: cve_id,
          severity: metadata_value(metadata, "cve_severity") || metadata_value(metadata, "severity"),
          affected_module_ids: Array(metadata_value(metadata, "affected_module_ids")),
          exposure_ids: Array(metadata_value(metadata, "exposure_ids"))
        )

        Rails.logger.info(
          "[CveResponder] inline dispatch cve=#{cve_id} action=#{action_category} " \
          "ok=#{result[:success]} refreshes=#{Array(result.dig(:data, :refresh_dispatches)).size}"
        )

        emit_event(
          kind: "cve_responder.inline_dispatch",
          payload: {
            cve_id: cve_id,
            action_category: action_category,
            ok: result[:success] == true,
            refresh_count: Array(result.dig(:data, :refresh_dispatches)).size,
            rolling_upgrade_count: Array(result.dig(:data, :rolling_upgrade_plans)).size,
            exposures_remediating: result.dig(:data, :exposures_remediating)
          }
        )
      end

      # Normalizes the two payload shapes to a list of CVE ids. Returns
      # the union of singular cve_id and plural cve_ids fields so a payload
      # carrying both (defensive callers) doesn't drop either.
      def extract_cve_ids(metadata)
        ids = []
        singular = metadata_value(metadata, "cve_id")
        ids << singular if singular.present?
        plural = metadata_value(metadata, "cve_ids")
        ids.concat(Array(plural)) if plural.present?
        ids.uniq
      end

      def metadata_value(metadata, key)
        metadata&.dig(key) || metadata&.dig(key.to_sym) ||
          metadata&.dig("payload", key) || metadata&.dig(:payload, key.to_sym)
      end

      def notify_action(action_category, metadata:, reasoning:)
        Rails.logger.info(
          "[CveResponder] Auto-execute: #{action_category} — " \
          "#{reasoning[:summary]&.truncate(120) || reasoning['summary']&.truncate(120)}"
        )
      end

      def decision_ttl_for(action_category)
        ADVANCEMENT_ACTIONS.include?(action_category) ? 4.hours : 1.hour
      end

      def dedup_key_for(action_category, metadata)
        case action_category
        when "system.cve_remediate", "system.cve_auto_remediate"
          key_value(metadata, "cve_id")
        when "system.module_critical_upgrade_ready"
          key_value(metadata, "package_module_link_id") || key_value(metadata, "node_module_id")
        end
      end

      def key_value(metadata, name)
        v = metadata&.dig(name) || metadata&.dig(name.to_sym)
        return nil if v.blank?
        [ name, v.to_s ]
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

        if (key = dedup_key_for(action_category, metadata))
          name, value = key
          existing = pending_cve_approvals
            .where("request_data->>'action_category' = ?", action_category)
            .where("request_data->'payload'->>? = ?", name, value)
            .first
          if existing
            existing.update!(request_data: request_data,
                             description: (reasoning[:summary] || reasoning["summary"]).to_s.truncate(500))
            return existing
          end

          if recently_rejected_approval?(action_category,
              [ "request_data->>'action_category' = ? AND request_data->'payload'->>? = ?",
                action_category, name, value ])
            Rails.logger.info("[CveResponder] Skipped #{action_category} for #{name}=#{value} — rejected within cooldown")
            return nil
          end
        end

        if recently_rejected_approval?(action_category,
            [ "request_data->>'action_category' = ?", action_category ])
          Rails.logger.info("[CveResponder] Skipped #{action_category} — rejected within cooldown")
          return nil
        end

        chain = cve_approval_chain
        return nil unless chain

        chain.create_request!(
          source_type: SOURCE_TYPE,
          source_id: action_category,
          description: (reasoning[:summary] || reasoning["summary"] || action_category).to_s.truncate(500),
          request_data: request_data
        )
      rescue StandardError => e
        Rails.logger.error("[CveResponder] Failed to create approval request: #{e.message}")
        nil
      end

      def pending_cve_approvals
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

      def cve_approval_chain
        @cve_approval_chain ||= ::Ai::ApprovalChain
          .where(account: @account, trigger_type: "autonomy_action", status: "active")
          .where("name ILIKE ?", "%cve%")
          .first
      end

      def emit_event(kind:, payload:, correlation_id: nil)
        return unless defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: kind,
          severity: :low,
          payload: payload,
          source: "cve_responder",
          correlation_id: correlation_id
        )
      rescue StandardError => e
        Rails.logger.warn("[CveResponder] event emit failed: #{e.message}")
      end

      # Cross-domain stigmergic pressure. When the tick produced any
      # `:proceed` or `:pending` decisions for critical CVEs, emit a
      # `security.critical_cve_pressure` event so trading + fleet can
      # observe and (optionally) defer non-critical work.
      def emit_pressure!(decisions)
        critical_count = decisions.count do |d|
          d[:signal_kind] == "system.cve_critical_published" &&
            %i[proceed pending].include?(d[:decision])
        end
        return if critical_count.zero?

        emit_event(
          kind: "security.critical_cve_pressure",
          payload: { critical_decision_count: critical_count, agent_id: agent.id }
        )
      end
    end
  end
end
