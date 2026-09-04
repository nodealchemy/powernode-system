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
      # Emergency kill-switch is authoritative across every reconciler — a halt
      # must stop CVE remediation too, not just the AI execution jobs.
      include ::System::Autonomy::KillSwitchGuard
      include ::System::Autonomy::ControlPlaneGuard
      # Supplies the shared unpermitted-action refusal (and GATE_POLICY_MISSING)
      # that tells a routed-but-unseeded lane from an ordinary refusal.
      include ::System::Autonomy::RoutedLaneGuard

      attr_reader :account, :agent, :role

      ADVANCEMENT_ACTIONS = %w[
        system.cve_remediate
        system.cve_auto_remediate
        system.module_critical_upgrade_ready
      ].freeze

      SOURCE_TYPE = "system_cve_responder"

      # Both sensors read exposures by state (`open` / `unresolved`), so a
      # `suspected` row — a keyword-only match with no version evidence
      # (IMP-7bba0413c36a) — reaches neither this tick's decisions nor its
      # inline dispatch nor #escalate_aged_exposures!. The auto lanes act on
      # evidence, not on a name collision.
      SENSORS = [
        ::System::CveOps::Sensors::CvePublishedSensor,
        ::System::CveOps::Sensors::CriticalUpgradeAvailableSensor
      ].freeze

      def self.tick!(account:, control_plane_reading: nil)
        # HIER-P2I: the account's clone of the seeded CVE Responder canonical
        # (System::Governance::AgentResolver), never the global row — a
        # canonical never executes.
        agent = ::System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "cve-responder")
                                                    &.tap { |a| a.resolving_account = account }
        return { ok: false, reason: "CVE Responder agent not seeded for account" } unless agent

        new(account: account, agent: agent).tick!(control_plane_reading: control_plane_reading)
      end

      def initialize(account:, agent:, role: nil)
        @account = account
        @agent = agent
        @role = role
        @policy_service = ::Ai::InterventionPolicyService.new(account: account)
      end

      def tick!(control_plane_reading: nil)
        # Authoritative kill-switch check FIRST — an engaged emergency halt
        # no-ops the entire reconcile (no sensing, deciding, or inline CVE
        # dispatch) before any state is touched.
        return halted_tick_result if kill_switch_engaged?

        # Dual-plane fence SECOND: on the standby plane the tick must do
        # nothing — the active plane owns actuation (ControlPlaneRole is the
        # split-brain gate; inert unless the coordinator SiteSetting arms it).
        # A caller-carried pass-scoped reading is honored; freshness is still
        # enforced on it inside active?.
        return standby_tick_result unless control_plane_active?(reading: control_plane_reading)

        tick_correlation = "tick:#{SecureRandom.hex(8)}"
        emit_event(kind: "cve_responder.tick_started", payload: { agent_id: agent.id }, correlation_id: tick_correlation)

        signals = collect_signals
        engine = ::System::Fleet::DecisionEngine.new(autonomy_service: self)
        decisions = engine.decide_all(signals)
        ::System::CveOps::LearningExtractor.record_tick!(account: account, decisions: decisions)
        emit_pressure!(decisions)
        aged_out_count = escalate_aged_exposures!

        emit_event(
          kind: "cve_responder.tick_complete",
          payload: {
            signal_count: signals.size,
            decision_count: decisions.size,
            by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size),
            aged_out_count: aged_out_count
          },
          correlation_id: tick_correlation
        )

        {
          ok: true,
          signal_count: signals.size,
          decision_count: decisions.size,
          by_kind: decisions.group_by { |d| d[:signal_kind] }.transform_values(&:size),
          by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size),
          aged_out_count: aged_out_count,
          correlation_id: tick_correlation
        }
      end

      def collect_signals
        signals = []
        SENSORS.each do |sensor_class|
          signals.concat(sensor_instance(sensor_class).sense)
        rescue StandardError => e
          Rails.logger.error("[CveResponder] sensor #{sensor_class.name} failed: #{e.message}")
        end
        signals
      end

      # ONE instance per sensor class per tick — this service is constructed
      # per tick, like #permitted_actions' memo.
      #
      # IMP-60717919d4a0: sensors memoize their resolved configuration for the
      # life of one instance precisely so a sense pass cannot straddle a
      # mid-tick config change (BaseSensor#threshold,
      # CvePublishedSensor#detection_lookback). Constructing a second
      # CvePublishedSensor later in the same tick to ask it for the detection
      # window re-read that config and defeated the guarantee: a change landing
      # between the two reads left a gap (window widened) or an overlap
      # (narrowed) between the fresh lane and the aged lane, which are
      # complements of ONE window.
      def sensor_instance(sensor_class)
        @sensor_instances ||= {}
        @sensor_instances[sensor_class] ||= sensor_class.new(account: account)
      end

      # Scoped to THIS account. CVE Responder is seeded as a GLOBAL agent
      # (account_id nil, one shared row — AgentSetupHelpers
      # #find_or_initialize_global_agent) while its POLICY rows are per-account,
      # so every tenant's rows hang off the same ai_agent_id. Without the
      # account filter this pre-gate answered from every tenant at once.
      #
      # That is not merely an over-broad list: the pre-gate is the
      # block/no-block discriminator, so a foreign row turned this account's
      # GATE_POLICY_MISSING refusal into a live approval request on a CVE lane
      # it never seeded — and skipped the RoutedLaneGuard alarm entirely, since
      # the seam only runs on the unpermitted arm. An alarm another tenant's row
      # can silence reads as coverage while providing none.
      #
      # IMP-b400ec1a2df8: the SAME twin-drift this service's gate_action! was
      # just repaired for. FleetAutonomyService#permitted_actions gained this
      # filter; the interchangeable CVE twin was missed both times.
      def permitted_actions
        @permitted_actions ||= ::Ai::InterventionPolicy
          .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
          .pluck(:action_category)
      end

      # Same shape as FleetAutonomyService#gate_action! so DecisionEngine can
      # call either interchangeably — which means it must accept EVERY kwarg
      # #decide passes, not just the ones this service acts on. It previously
      # accepted neither, so a bound CVE signal raised ArgumentError out of an
      # unrescued decide_all and took the whole tick down (the controller's
      # rescue reported it as a bland ok:false).
      #
      # force_policy is honored: it is the F3-11 stuck-remediation override,
      # and a proven-ineffective CVE remediation must stop auto-proceeding here
      # exactly as it does on the fleet side. advisory is accepted and
      # deliberately inert: it exempts a decision from the per-module consent
      # budget and makes its approval durable, and this service has neither a
      # consent budget nor any advisory binding.
      def gate_action!(action_category, metadata: {}, reasoning: {}, temporal_context: {},
                       force_policy: nil, advisory: false)
        # IMP-b400ec1a2df8: this arm used to be a private copy that only ever
        # emitted a silent `not_permitted`, so the routed/unseeded split
        # IMP-5a450411d873 added reached the fleet gate and missed this one —
        # leaving critical-CVE remediation dead-and-quiet on any install whose
        # system_cve_responder_agent seed rows never landed. It now takes the
        # SAME arm as every other gate (System::Autonomy::RoutedLaneGuard).
        unless permitted_actions.include?(action_category)
          return refuse_unpermitted_action(action_category)
        end

        result = if force_policy
          { policy: force_policy, source: "decision_engine_override" }
        else
          @policy_service.resolve(action_category: action_category, agent: @agent)
        end

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

      # IMP-01a025b3: the CVE half of the DecisionEngine's collaborator
      # contract. The engine's stuck-remediation lane consults this before
      # escalating, so a service that misses it raises NoMethodError out of an
      # unrescued decide_all and takes the whole CVE tick down — this service
      # is the OTHER `autonomy_service` DecisionEngine is constructed with
      # (see CveResponderService#tick!).
      #
      # Semantics mirror FleetAutonomyService#open_operator_request? against
      # THIS service's own request store (SOURCE_TYPE, #dedup_key_for,
      # #decision_ttl_for): "open" = re-gating would produce no new
      # operator-facing artifact, so the caller can go quiet without losing the
      # operator's only actionable row. Fails open, for the same reason.
      def open_operator_request?(action_category, metadata: {})
        return false unless defined?(::Ai::ApprovalRequest)

        if (key = dedup_key_for(action_category, metadata))
          name, value = key
          return true if pending_cve_approvals
            .where("request_data->>'action_category' = ?", action_category)
            .where("request_data->'payload'->>? = ?", name, value)
            .exists?

          return true if recently_rejected_approval?(action_category,
              [ "request_data->>'action_category' = ? AND request_data->'payload'->>? = ?",
               action_category, name, value ])
        end

        recently_rejected_approval?(action_category,
          [ "request_data->>'action_category' = ?", action_category ])
      rescue StandardError => e
        Rails.logger.error("[CveResponder] open-request check failed for #{action_category} " \
                           "(failing open — escalation will re-fire): #{e.class}: #{e.message}")
        false
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

        # Mid-tick re-check with a FRESH observation (IMP-6ea384a0ee79):
        # inline critical remediation runs multi-minute, far past any
        # reading's 5-30s freshness window, so the tick-entry verdict is
        # stale by definition here. This is the carry-and-recheck contract
        # ControlPlaneRole documents for irreversible actions — a plane that
        # lost election mid-tick must not keep dispatching. Deliberately a
        # fresh read (never the carried pass reading).
        unless control_plane_active?
          Rails.logger.warn(
            "[CveResponder] inline dispatch withheld — control plane no longer active " \
            "(mid-tick re-check; cves=#{cve_ids.join(',')})"
          )
          return
        end

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

        ok = result[:success] == true
        skipped_reason = result.dig(:data, :skipped_reason)
        # IMP-60717919d4a0 — the orchestrator's failure message names the
        # module, the candidate version and the legal next promotion rung
        # (IMP-9b8d774298d5), and this is its ONLY production caller: a log
        # line that said `ok=false` and an event with no error field threw
        # all of that away. Bounded and redacted on the way into a persisted,
        # broadcast payload for the same reason BaseSkillExecutor#audit_text
        # bounds its own copy — the text may relay a provider SDK's or an HTTP
        # client's message, not only platform-authored prose.
        error_text = ok ? nil : bounded_error_text(result[:error])

        Rails.logger.info(
          "[CveResponder] inline dispatch cve=#{cve_id} action=#{action_category} " \
          "ok=#{ok} refreshes=#{Array(result.dig(:data, :refresh_dispatches)).size}" \
          "#{" skipped_reason=#{skipped_reason}" if skipped_reason.present?}" \
          "#{" error=#{error_text}" if error_text.present?}"
        )

        emit_event(
          kind: "cve_responder.inline_dispatch",
          # A dispatch that did not work is not routine telemetry — an operator
          # filtering the low band would never see it (same band choice as
          # BaseSkillExecutor#audit_log_finish).
          severity: ok ? :low : :medium,
          # Same correlation walk as the decision this dispatch belongs to:
          # DecisionEngine stamps the signal fingerprint on the metadata, and
          # the sensor's key is deterministic, so the fallback lands in the
          # same chain when a caller carried none.
          correlation_id: metadata_value(metadata, "signal_fingerprint").presence || "cve_pub:#{cve_id}",
          payload: {
            cve_id: cve_id,
            action_category: action_category,
            ok: ok,
            error: error_text,
            skipped_reason: skipped_reason,
            remediation_dispatched: result.dig(:data, :remediation_dispatched),
            refresh_count: Array(result.dig(:data, :refresh_dispatches)).size,
            rolling_upgrade_count: Array(result.dig(:data, :rolling_upgrade_plans)).size,
            exposures_remediating: result.dig(:data, :exposures_remediating)
          }.compact
        )
      end

      # Redact FIRST, then bound: a secret straddling the cut must be gone from
      # the bounded copy, not left as its leading bytes. nil in, nil out so
      # `.compact` drops the key.
      #
      # This is a COPY of BaseSkillExecutor#audit_text's body, not a call to
      # it: that method is private on a class this lane may not edit, so the
      # rule now has two homes and they must be kept in step. The bound itself
      # IS shared (BaseSkillExecutor::AUDIT_TEXT_LIMIT). Unifying them —
      # a module-level `bound_audit_text` on BaseSkillExecutor, or a small
      # System::AuditText helper both call — needs an edit to that file and is
      # recorded as follow-up work.
      def bounded_error_text(value)
        return nil if value.blank?

        text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
        limit = ::System::Ai::Skills::BaseSkillExecutor::AUDIT_TEXT_LIMIT
        sliced = text[0, limit * 4]
        if text.length > limit * 4
          # Drop the token the slice cut in half — but only while enough text
          # survives to fill the bound. A machine-generated body (minified
          # JSON, a base64 blob) can be ONE unbroken run for the whole slice,
          # and stripping that left an EMPTY reason on exactly the failures
          # most likely to be long (the IMP-675ed7763230 regression, fixed in
          # #audit_text and carried here by SWEEP-2026-09-03).
          stripped = sliced.sub(/\S+\z/, "")
          sliced = stripped if stripped.length >= limit
        end
        ::System::ShellOutputSanitizer.redact_text(sliced).truncate(limit)
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

      # IMP-0de0a6b4db59 — the surviving half of APO-2d (IMP-25949cfd28fd).
      # The fleet twin's #notify_action gained a durable, broadcast FleetEvent;
      # this arm was out of that lane and stayed one Rails.logger line, so a
      # security-domain notify_and_proceed reached no operator surface at all.
      #
      # What the emit buys, precisely: the two KIND-AGNOSTIC FleetEvent reads
      # — system_recent_signals and system_inspect_correlation (SystemFleetTool)
      # — plus the account's SystemFleetChannel broadcast. NOT the approval UI:
      # notify_and_proceed mints no Ai::ApprovalRequest (only the
      # require_approval arm above does), so this lane reaches no approval
      # queue on either side of the twin. Nothing keys on NOTIFY_EVENT_KIND
      # today — the shared kind is what makes the two lanes queryable as ONE
      # once something does; source stays "cve_responder" so they remain
      # tellable apart. The log line is kept.
      def notify_action(action_category, metadata:, reasoning:)
        summary = reasoning[:summary] || reasoning["summary"]
        Rails.logger.info(
          "[CveResponder] Auto-execute: #{action_category} — #{summary&.to_s&.truncate(120)}"
        )

        md = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}

        # Correlate on the signal fingerprint when the caller carried one
        # (DecisionEngine#skill_metadata_payload stamps it — "cve_pub:<cve_id>"
        # / "crit_upgrade:<link>:<version>" for this lane's sensors — and
        # EventBroadcaster#emit_decision! keys its decision events off the same
        # value), so the notification lands in the SAME correlation walk as the
        # decision it belongs to rather than in a chain of its own.
        correlation = md["signal_fingerprint"].presence || "notify:#{SecureRandom.hex(8)}"

        # Resource refs ride in the payload: EventBroadcaster maps these keys
        # onto the FleetEvent ref columns. `cve_id` here is the CVE identifier
        # string ("CVE-…"), not the row UUID the ref column holds — the uuid
        # cast leaves the column nil and the identifier stays in the payload,
        # exactly as #dispatch_single's inline_dispatch event already does.
        refs = md.slice("node_id", "instance_id", "module_id", "module_version_id",
                        "certificate_id", "cve_id").compact

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: ::System::Fleet::FleetAutonomyService::NOTIFY_EVENT_KIND,
          # medium, not low: an operator chose notify_and_proceed BECAUSE they
          # want to be told. Low severity is the routine-telemetry band.
          severity: :medium,
          source: "cve_responder",
          correlation_id: correlation,
          # This lane's signals name the module as `node_module_id` (the
          # column name), which the payload-derived mapping does not read —
          # pass it as the explicit ref so the event is filterable per module.
          node_module_id: md["node_module_id"].presence,
          payload: refs.merge(
            "action_category" => action_category,
            "gate" => "notify_and_proceed",
            # Bounded on the way into a persisted, broadcast payload for the
            # same reason BaseSkillExecutor bounds its error text: a summary is
            # free-form, caller-supplied, and now leaves the reconciler host.
            # The untruncated value stays on the log line above.
            "summary" => summary&.to_s&.truncate(::System::Fleet::FleetAutonomyService::NOTIFY_SUMMARY_LIMIT),
            # The plural shape module_critical_upgrade_ready carries, and the
            # module list both sensors carry — what the operator needs to act.
            "cve_ids" => md["cve_ids"],
            "affected_module_ids" => md["affected_module_ids"],
            "signal_kind" => md["signal_kind"],
            "signal_fingerprint" => md["signal_fingerprint"],
            "agent_id" => agent&.id
          ).compact
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
        # See fleet_autonomy_service#fleet_approval_chain — Ai::ApprovalChain
        # is a business-only model; soft-fail in core mode.
        return nil unless defined?(::Ai::ApprovalChain)
        @cve_approval_chain ||= ::Ai::ApprovalChain
          .where(account: @account, trigger_type: "autonomy_action", status: "active")
          .where("name ILIKE ?", "%cve%")
          .first
      end

      # IMP-60717919d4a0 — the standing alarm for exposures CvePublishedSensor
      # no longer sees. That sensor is a fresh-detection lane bounded by its
      # window; an exposure still `open` past it would otherwise never be
      # mentioned again. Runs against the sensor's OWN resolved window so the
      # two lanes are complementary by construction (fresh → decisions; aged →
      # one durable FleetEvent per CVE per window). Never takes the tick down:
      # the decisions above are already made, and a failure here is logged at
      # error so it is not silent.
      def escalate_aged_exposures!
        lookback = sensor_instance(::System::CveOps::Sensors::CvePublishedSensor).detection_lookback
        ::System::CveOps::AgedExposureEscalator.new(account: account, lookback: lookback).escalate!
      rescue StandardError => e
        Rails.logger.error("[CveResponder] aged-exposure escalation failed: #{e.class}: #{e.message}")
        0
      end

      def emit_event(kind:, payload:, correlation_id: nil, severity: :low)
        return unless defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: kind,
          severity: severity,
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
