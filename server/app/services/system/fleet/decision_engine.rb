# frozen_string_literal: true

module System
  module Fleet
    # Routes signals from sensors to skills + actions. Each signal kind is
    # bound to (a) a skill that produces a plan and (b) an action_category
    # that goes through FleetAutonomyService#gate_action!. The engine has
    # no policy logic of its own — that lives in InterventionPolicy rows.
    #
    # Reference: Golden Eclipse plan M7 — DecisionEngine. The shape mirrors
    # Trading::Overseer::DecisionExecutionService but stays much smaller:
    # we only need to thread (signal → skill → gate → execute-or-record)
    # for v0; the trading service has additional flow control we don't yet
    # need (concurrency caps, role-based dispatch).
    class DecisionEngine
      # Maps a CVE signal payload to CveResponseExecutor inputs — a
      # side-effect-free triage whose plan lands in approval request
      # metadata for operator review. The CveResponderService handles the
      # actual dispatch separately at gate-time so invocation stays pure
      # (in line with the "DecisionEngine.invoke_skill produces a plan,
      # doesn't act" contract).
      #
      # Handles two signal payload shapes:
      #   - cve_critical_published: payload.cve_id (singular)
      #   - module_critical_upgrade_ready: payload.cve_ids (plural — same
      #     module may carry multiple open exposures; triage the first as
      #     a representative plan for the approval/notification).
      #
      # Returns nil (skip invocation) when there is nothing actionable.
      CVE_RESPONSE_INPUTS = lambda do |signal|
        payload = signal.payload || {}
        cve_id = payload["cve_id"].presence || Array(payload["cve_ids"]).first
        next nil if cve_id.blank?

        # Pull affected_packages from the signal payload (CvePublishedSensor
        # includes them) or fall back to the persisted Cve row.
        affected = Array(payload["affected_packages"]).map { |n| { name: n.to_s } }
        if affected.empty? && defined?(::System::Cve)
          cve = ::System::Cve.find_by(cve_id: cve_id)
          affected = cve&.normalized_affected_packages.to_a
        end
        next nil if affected.empty?

        {
          cve_id: cve_id,
          severity: payload["cve_severity"] || signal.severity.to_s,
          affected_packages: affected,
          summary: payload["cve_summary"]
        }
      end

      # signal.kind → {skill: <System::Ai::Skills class>, action_category: "system...."}
      #
      # Every binding with a skill MUST also declare an input_mapper lambda
      # (signal → executor kwargs, or nil to skip invocation). invoke_skill
      # dispatches exclusively through the mapper — a skill without one
      # raises instead of silently never running (audit F3-04: a class-name
      # case statement previously left all four SDWAN executors unreachable).
      SIGNAL_BINDINGS = {
        "system.instance_silent" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.instance_reprovision",
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        "system.module_drift" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.module_assign",
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        "system.cert_expiring" => {
          skill: nil, # cert rotation is handled directly via NodeCertificate#rotate
          action_category: "system.cert_rotate"
        },
        # Platform ACME cert expiry (CertExpirySensor) → platform_maintenance
        # cert_rotate. The executor's cert_rotate is fire-and-forget (queues
        # the async renewal sweep), so invoke_skill fires it on the
        # notify_and_proceed path — mirroring how CVE bindings invoke their
        # executor.
        "system.acme_cert_expiring" => {
          skill: ::System::Ai::Skills::PlatformMaintenanceExecutor,
          action_category: "system.acme_cert_rotate",
          input_mapper: ->(signal) {
            { action: "cert_rotate", certificate_id: signal.dig(:payload, "certificate_id") }
          }
        },
        "system.module_promotion_ready" => {
          skill: nil, # ModulePromotionService is invoked directly
          action_category: "system.module_promote_to_live"
        },
        "system.config_drift" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.module_assign",
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        "system.slo_violation" => {
          skill: nil, # SLO violations route to rolling_upgrade *plan* via the executor; engine doesn't need to invoke it inline
          action_category: "system.module_assign"
        },
        "system.honeypot_access" => {
          skill: nil, # quarantine via gate (instance_terminate require_approval)
          action_category: "system.instance_terminate"
        },
        "system.trading_pressure_observed" => {
          # Trading pressure is informational — no autonomy action; the binding
          # exists so the signal isn't classified as "skipped" and dashboard
          # can filter for it. Used by gate_action! to throttle non-critical
          # actions when trading load is high.
          skill: nil,
          action_category: "system.observation"
        },
        # Slice 5 + 5.5 of the SDWAN plan. peer_drift gets the auto-execute
        # path (notify_and_proceed → SdwanPeerRemediateExecutor rotates the
        # keypair). hub_unreachable stays plan-only (require_approval →
        # SdwanFailoverExecutor returns candidate spokes; operator promotes).
        "system.sdwan_peer_drift" => {
          skill: ::System::Ai::Skills::SdwanPeerRemediateExecutor,
          action_category: "system.sdwan_peer_remediate",
          input_mapper: ->(signal) { { peer_id: signal.dig(:payload, "peer_id") } }
        },
        "system.sdwan_hub_unreachable" => {
          skill: ::System::Ai::Skills::SdwanFailoverExecutor,
          action_category: "system.sdwan_failover",
          # Executor defaults to dry_run: true — returns the candidate-spoke
          # plan for the approval request; the operator promotes.
          input_mapper: ->(signal) { { network_id: signal.dig(:payload, "network_id") } }
        },
        # Slice 9f — iBGP session remediation, VIP failover, route-policy
        # audit. Session remediation auto-fires (notify_and_proceed) since
        # restarting FRR via systemctl is low blast radius. VIP failover
        # is approval-gated by default (it's a holder-promotion, visible).
        "system.sdwan_bgp_session_unhealthy" => {
          skill: ::System::Ai::Skills::SdwanBgpSessionRemediateExecutor,
          action_category: "system.sdwan_bgp_session_remediate",
          input_mapper: ->(signal) {
            { bgp_session_id: signal.dig(:payload, "bgp_session_id"),
              peer_id: signal.dig(:payload, "peer_id"),
              neighbor_address: signal.dig(:payload, "neighbor_address") }
          }
        },
        "system.sdwan_bgp_session_stale" => {
          # Stale = no observation. Notification only; no auto-action.
          skill: nil,
          action_category: "system.observation"
        },
        "system.sdwan_vip_unreachable" => {
          skill: ::System::Ai::Skills::SdwanVipFailoverExecutor,
          action_category: "system.sdwan_vip_failover",
          input_mapper: ->(signal) { { virtual_ip_id: signal.dig(:payload, "virtual_ip_id") } }
        },
        # M2 of the AI-driven provisioning conversation — adaptive evolution.
        # Skills are intentionally `nil` because adaptation is multi-step:
        # the engine creates a pending approval whose payload triggers
        # AdaptationProposerService (in the parent platform), which composes
        # a diff plan composed of one or more provisioning_skill steps.
        # Routing is to the `project.adapt` / `project.cost_control` action
        # categories — operator policies decide whether to auto-approve
        # (notify_and_proceed) or block via require_approval.
        "system.project_slo_violation" => {
          skill: nil,
          action_category: "project.adapt"
        },
        "system.project_drift" => {
          skill: nil,
          action_category: "project.adapt"
        },
        "system.project_cost_breach" => {
          skill: nil,
          action_category: "project.cost_control"
        },
        # CVE Responder bindings (2026-05-11 wiring completion). The
        # binding's skill is CveResponseExecutor — a side-effect-free
        # triage planner whose output lands in the approval request's
        # metadata for require_approval flows. The actual orchestrator
        # (CveRemediationOrchestrationExecutor) runs separately at
        # gate-time via CveResponderService#dispatch_inline for
        # notify_and_proceed, keeping invoke_skill side-effect-free.
        "system.cve_critical_published" => {
          skill: ::System::Ai::Skills::CveResponseExecutor,
          action_category: "system.cve_remediate",
          input_mapper: CVE_RESPONSE_INPUTS
        },
        "system.module_critical_upgrade_ready" => {
          skill: ::System::Ai::Skills::CveResponseExecutor,
          action_category: "system.module_critical_upgrade_ready",
          input_mapper: CVE_RESPONSE_INPUTS
        },
        # Phase 3c — federation peer liveness. The FederationPeerLivenessSensor
        # emits one kind for both failure classes (stale heartbeat + cert
        # expiry); the FederationPeerRemediateExecutor branches on
        # payload.reason. The executor re-handshakes/degrades (heartbeat) or
        # alerts (cert) and emits a FleetEvent — it's the real remediation,
        # so invoke_skill fires it on the notify_and_proceed path (mirroring
        # how the SDWAN peer-remediate binding auto-fires its executor).
        "system.federation_peer_liveness" => {
          skill: ::System::Ai::Skills::FederationPeerRemediateExecutor,
          action_category: "system.federation_peer_remediate",
          input_mapper: ->(signal) {
            { federation_peer_id: signal.dig(:payload, "federation_peer_id"),
              reason: signal.dig(:payload, "reason") }
          }
        }
      }.freeze

      # TTL on cross-tick fingerprint dedup. Same fingerprint within this
      # window is skipped at the engine level (no skill invocation, no
      # ApprovalRequest) — meaningfully reduces approval-queue churn for
      # signals that re-emit on every reconcile tick (e.g., a silent
      # instance lasts more than 60s).
      DEDUP_TTL_SECONDS = (ENV["FLEET_DEDUP_TTL_SECONDS"] || 600).to_i

      attr_reader :autonomy_service, :account

      def initialize(autonomy_service:)
        @autonomy_service = autonomy_service
        @account = autonomy_service.account
      end

      # Process a single signal — bind to skill, plan, gate, return decision.
      # Returns a decision hash with :gate, :decision, optional :skill_result.
      def decide(signal)
        signal = ::System::Fleet::Signal.from_hash(signal) unless signal.is_a?(::System::Fleet::Signal)

        # Observability: emit the signal as an event before any routing
        # logic runs. This way dashboards see the raw signal volume even
        # when DecisionEngine bails (no binding / deduped).
        ::System::Fleet::EventBroadcaster.emit_signal!(
          account: account, signal: signal, source: "decision_engine.signal_received"
        )

        binding = SIGNAL_BINDINGS[signal.kind]
        unless binding
          decision = { decision: :skipped, reason: "no binding for kind=#{signal.kind}", signal_kind: signal.kind }
          ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
          return decision
        end

        if recently_decided?(signal)
          decision = {
            decision: :deduped,
            reason: "fingerprint #{signal.fingerprint} decided within last #{DEDUP_TTL_SECONDS}s",
            signal_kind: signal.kind
          }
          ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
          return decision
        end

        skill_result = invoke_skill(binding, signal) if binding[:skill]

        gate_result = autonomy_service.gate_action!(
          binding[:action_category],
          metadata: skill_metadata_payload(signal, skill_result),
          reasoning: { summary: build_summary(signal, skill_result) }
        )

        record_decision!(signal)

        decision = gate_result.merge(
          signal_kind: signal.kind,
          fingerprint: signal.fingerprint, # self-improvement: the validate-step match key
          action_category: binding[:action_category],
          skill_result: skill_result
        )
        ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
        decision
      end

      # Process a list of signals; returns the array of decisions.
      def decide_all(signals)
        Array(signals).map { |s| decide(s) }
      end

      private

      def recently_decided?(signal)
        return false unless Rails.cache.respond_to?(:exist?)

        Rails.cache.exist?(dedup_key(signal))
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] dedup check failed: #{e.message}")
        false
      end

      def record_decision!(signal)
        return unless Rails.cache.respond_to?(:write)

        Rails.cache.write(
          dedup_key(signal),
          Time.current.to_i.to_s,
          expires_in: DEDUP_TTL_SECONDS
        )
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] dedup record failed: #{e.message}")
      end

      def dedup_key(signal)
        "fleet:decided:#{account.id}:#{signal.kind}:#{signal.fingerprint}"
      end

      # Executor inputs come exclusively from the binding's input_mapper
      # (signal → kwargs, or nil to skip invocation). `fetch` raises on a
      # binding that declares a skill without a mapper, so a mis-declared
      # binding surfaces as an error in the decision record instead of an
      # executor that silently never runs.
      def invoke_skill(binding, signal)
        skill_class = binding[:skill]
        return nil unless skill_class

        inputs = binding.fetch(:input_mapper).call(signal)
        return nil if inputs.nil?

        executor = skill_class.new(account: account, agent: autonomy_service.agent, user: nil)
        executor.execute(**inputs)
      rescue StandardError => e
        Rails.logger.error("[FleetDecisionEngine] skill invocation failed: #{e.class}: #{e.message}")
        { success: false, error: e.message }
      end

      def skill_metadata_payload(signal, skill_result)
        base = signal.payload.is_a?(Hash) ? signal.payload.deep_stringify_keys : {}
        if skill_result.is_a?(Hash) && skill_result[:data].is_a?(Hash)
          base.merge("skill_plan" => skill_result[:data])
        else
          base
        end
      end

      def build_summary(signal, skill_result)
        parts = [ "Fleet signal #{signal.kind} (severity=#{signal.severity})" ]
        if signal.payload.is_a?(Hash)
          if signal.payload["instance_id"]
            parts << "instance=#{signal.payload['instance_id']}"
          elsif signal.payload["module_version_id"]
            parts << "version=#{signal.payload['module_version_id']}"
          elsif signal.payload["certificate_id"]
            parts << "cert=#{signal.payload['certificate_id']}"
          end
        end
        if skill_result.is_a?(Hash) && skill_result[:data].is_a?(Hash) && skill_result[:data][:disruption_pct]
          parts << "disruption=#{skill_result[:data][:disruption_pct]}%"
        end
        parts.join(" — ")
      end
    end
  end
end
