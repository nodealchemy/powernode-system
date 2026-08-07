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
      # Control-plane fence — never reap/actuate on an instance owned by a
      # DIFFERENT control plane (imp 019f6d6b-63e5). Kept ALONGSIDE the existing
      # account scoping (belt-and-suspenders). Inert until a self-id is
      # configured (single-plane) and until #14 stamps owners.
      include ::System::Autonomy::ControlPlaneFence

      # RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
      # A DISTINCT fence from ControlPlaneFence above (see
      # SelfManagementFence's doc comment): this one answers "is the target
      # MY OWN hosting node", not "does another plane own it" — a plane can
      # legally own (per ControlPlaneFence) the very instance that hosts it,
      # and that is exactly the case INV-1 forbids. Also nil-safe/inert
      # until self_hosting_node_id is configured.
      include ::System::Autonomy::SelfManagementFence

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
      # Every binding with a skill MUST also declare:
      #   - input_mapper: lambda (signal → executor kwargs, or nil to skip).
      #     invoke_skill dispatches exclusively through the mapper — a skill
      #     without one raises instead of silently never running (audit
      #     F3-04: a class-name case statement previously left all four
      #     SDWAN executors unreachable).
      #   - side_effectful: true/false. Side-effectful executors only run
      #     for real when the resolved policy auto-executes (auto_approve /
      #     notify_and_proceed); under require_approval they run plan-only
      #     (dry_run: true, requires dry_run_supported: true) so the plan
      #     lands in the ApprovalRequest, and under block/silent they are
      #     skipped (audit F3-06: they previously ran BEFORE the gate,
      #     making operator policy overrides decorative).
      SIGNAL_BINDINGS = {
        "system.instance_silent" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.instance_reprovision",
          side_effectful: false, # drift report + remediation plan only
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        "system.module_drift" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.module_assign",
          side_effectful: false, # drift report + remediation plan only
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        # Campaign 019f6084 §2.4.3 (TemplateClosureDriftSensor). No skill —
        # the signal payload already carries the missing-module plan
        # (TemplateApprovalPolicy's classification travels with it), so
        # there's nothing an executor would add for the ApprovalRequest to
        # display. Blast radius is ALWAYS provisioned (the sensor only
        # fires for an instance that already exists on the template), so
        # `decide` forces require_approval off the signal's own
        # `requires_approval` flag rather than trusting the seeded policy —
        # see the force_policy branch below. Remediation
        # (apply_template_closure_drift) lives in REMEDIATION_APPLIERS.
        "system.template_closure_drift" => {
          skill: nil,
          action_category: "system.template_closure_apply"
        },
        # Boot-image drift (BootImageDriftSensor): a node booted a stale disk
        # image. Campaign 019f505f increment 4 — route to the drift-driven fleet
        # rollout executor, gated by system.node_boot_image_drift (require_approval:
        # a fleet-wide reboot rollout is high blast radius). side_effectful +
        # dry_run_supported means it runs PLAN-ONLY under the gate (canary-first
        # batch plan into the ApprovalRequest); the per-instance upgrade_boot_image
        # tasks are created only when the operator approves (execute_approved!).
        "system.boot_image_drift" => {
          skill: ::System::Ai::Skills::BootImageDriftRolloutExecutor,
          action_category: "system.node_boot_image_drift",
          side_effectful: true,
          dry_run_supported: true,
          input_mapper: ->(signal) { { instance_id: signal.dig(:payload, "instance_id") } }
        },
        # Provider-state drift (InstanceStateDriftSensor): the VM itself is
        # stopped/terminated while the model says running — distinct from
        # instance_silent (heartbeat staleness). Routes to the
        # instance_reboot gate (notify_and_proceed in the fleet seed) so the
        # drift is notified, deduped per instance_id, and visible to
        # operators instead of discarded as decision :skipped. No skill —
        # there is nothing to plan; the REMEDIATION_APPLIERS entry below
        # (converge_instance_state_drift) is the real remediation, applied
        # directly on :proceed.
        "system.instance_state_drifted" => {
          skill: nil,
          action_category: "system.instance_reboot"
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
          # Queues the real renewal sweep and has no dry_run mode — when the
          # policy doesn't auto-execute, the executor is skipped entirely.
          side_effectful: true,
          input_mapper: ->(signal) {
            { action: "cert_rotate", certificate_id: signal.dig(:payload, "certificate_id") }
          }
        },
        "system.module_promotion_ready" => {
          # skill: nil because there is no on-node task to dispatch — the
          # remediation is a model-side state transition, actuated by the
          # #apply_module_promotion entry in REMEDIATION_APPLIERS. The previous
          # comment here read "ModulePromotionService is invoked directly",
          # which was false: promote! had no call site anywhere in application
          # code, so every approved promotion returned "no applier".
          skill: nil,
          action_category: "system.module_promote_to_live"
        },
        "system.config_drift" => {
          skill: ::System::Ai::Skills::DriftRemediateExecutor,
          action_category: "system.module_assign",
          side_effectful: false, # drift report + remediation plan only
          # F3-09: ConfigDriftSensor emits per-assignment signals carrying
          # the node's running instance_ids (never a bare instance_id) —
          # resolve the first as the remediation target, or skip the
          # executor cleanly when the node has no running instances.
          input_mapper: ->(signal) {
            instance_id = signal.dig(:payload, "instance_id") ||
                          Array(signal.dig(:payload, "instance_ids")).first
            instance_id ? { instance_id: instance_id } : nil
          }
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
          side_effectful: true, # rotates the peer keypair
          dry_run_supported: true,
          input_mapper: ->(signal) { { peer_id: signal.dig(:payload, "peer_id") } }
        },
        "system.sdwan_hub_unreachable" => {
          skill: ::System::Ai::Skills::SdwanFailoverExecutor,
          action_category: "system.sdwan_failover",
          # Executor defaults to dry_run: true — returns the candidate-spoke
          # plan for the approval request; the operator promotes.
          side_effectful: false,
          input_mapper: ->(signal) { { network_id: signal.dig(:payload, "network_id") } }
        },
        # Slice 9f — iBGP session remediation, VIP failover, route-policy
        # audit. Session remediation auto-fires (notify_and_proceed) since
        # restarting FRR via systemctl is low blast radius. VIP failover
        # is approval-gated by default (it's a holder-promotion, visible).
        "system.sdwan_bgp_session_unhealthy" => {
          skill: ::System::Ai::Skills::SdwanBgpSessionRemediateExecutor,
          action_category: "system.sdwan_bgp_session_remediate",
          side_effectful: false, # executor defaults to dry_run: true (plan only)
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
          side_effectful: true, # promotes a failover holder
          dry_run_supported: true,
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
          side_effectful: false, # side-effect-free triage planner
          input_mapper: CVE_RESPONSE_INPUTS
        },
        "system.module_critical_upgrade_ready" => {
          skill: ::System::Ai::Skills::CveResponseExecutor,
          action_category: "system.module_critical_upgrade_ready",
          side_effectful: false, # side-effect-free triage planner
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
          side_effectful: true, # re-handshakes/degrades the peer
          dry_run_supported: true,
          input_mapper: ->(signal) {
            { federation_peer_id: signal.dig(:payload, "federation_peer_id"),
              reason: signal.dig(:payload, "reason") }
          }
        },
        # Audit F3-07 — kinds for the previously-unregistered sensors.
        # Expiring SDWAN membership credential → rotate the peer keypair
        # (same executor + auto-execute shape as sdwan_peer_drift).
        "system.sdwan_credential_expiring" => {
          skill: ::System::Ai::Skills::SdwanPeerRemediateExecutor,
          action_category: "system.sdwan_key_rotate",
          side_effectful: true, # rotates the peer keypair
          dry_run_supported: true,
          input_mapper: ->(signal) { { peer_id: signal.dig(:payload, "peer_id") } }
        },
        # A stalled refresh means the automated rotation path already
        # failed upstream — surface to operators, don't retry blindly.
        "system.sdwan_credential_refresh_stalled" => {
          skill: nil,
          action_category: "system.observation"
        },
        # Upstream package version drift → repository sync gate
        # (auto_approve in the fleet seed; dedup per package_repository_id).
        "system.package_drift_pressure" => {
          skill: nil,
          action_category: "system.package_repository.sync"
        },
        # Stale storage assignment → re-run reconciliation via the
        # remediation applier (REMEDIATION_APPLIERS) once the gate proceeds.
        "system.storage_assignment_drift" => {
          skill: nil,
          action_category: "system.storage_assignment_reconcile"
        },
        # GitOps drift (GitopsDriftSensor) → notify-only gate. No skill and no
        # REMEDIATION_APPLIER entry: the reconciler (System::Gitops::Reconciler,
        # driven by SystemGitopsSyncJob) is what opens the proposals and applies
        # auto_apply repos — the DecisionEngine's role here is purely to surface
        # the drift through the autonomy gate (notify_and_proceed in the fleet
        # seed) instead of dropping it as :skipped. Mirrors module_promotion_ready
        # / instance_state_drifted (skill: nil, applier-less notification gates).
        "system.gitops.drift_detected" => {
          skill: nil,
          action_category: "system.gitops_drift_remediate"
        },
        # DK3 — DiskImagePublicationFailureStreakSensor. No remediation
        # applier: a broken CI pipeline needs operator investigation, not
        # an automated retry. notify_and_proceed (seeded on Fleet Autonomy,
        # not Disk Image Manager, since the sensor fires from THIS agent's
        # tick) surfaces the streak instead of dropping it as :skipped for
        # lack of a binding — mirrors sdwan_credential_refresh_stalled
        # (an automated path already failed upstream; surface, don't retry).
        "system.disk_image_publication_failure_streak" => {
          skill: nil,
          action_category: "system.disk_image_publication_investigate"
        },
        # IMP-4019664a524b — CapabilityGapSensor. A `capability:<tag>`
        # requirement no module on the account can satisfy. The sensor has
        # always emitted; without an entry here every gap died in the
        # no-binding branch as decision :skipped, which is why the platform's
        # ONLY surfaced record of "a needed capability has no provider" never
        # reached anyone.
        #
        # ROUTE, DON'T REMEDIATE. Closing a gap means AUTHORING a module,
        # which must pass the human R1/R2/R3 reuse gate
        # (docs/runbooks/module-authoring.md Phase 0) — automation that made
        # module creation cheap would make module SPRAWL cheap. So: no skill
        # (nothing to plan; the payload already names the capability, the
        # constraint, and the requiring module) and deliberately NO
        # REMEDIATION_APPLIERS entry — approving the review is the operator
        # acknowledging the gap, and execute_approved! reports applied:false
        # "no applier" rather than pretending something converged.
        #
        # WHY require_approval AND NOT AN OBSERVATION. The two notify-only
        # shapes both mis-serve this signal: "system.observation" is
        # auto_approve and reaches no operator at all, while a
        # notify_and_proceed category would decide :proceed and hand
        # RemediationValidator a pending outcome for a fingerprint that only
        # clears when a human ships a module days later — scored ineffective
        # every settle window until the F3-11 streak manufactures a false
        # fleet.remediation_stuck escalation. :pending is never recorded by
        # record_proceeded!, so the require_approval gate keeps the gap out of
        # the validate arc without needing an exemption.
        #
        # advisory: true is the gate-side counterpart, and it is load-bearing
        # twice over (both were live defects). It exempts the decision from the
        # per-module consent budget — the sensor stamps the REQUIRING module's
        # id, so a standing gap re-deciding every dedup TTL would otherwise
        # drain that module's operator-set 24h ceiling with a no-op and push
        # its REAL remediations down the budget-exhausted branch. And it makes
        # the operator's answer DURABLE: dedup falls through to gate_action!'s
        # universal signal_fingerprint key (which the sensor already scopes per
        # module-and-requirement), but the ordinary dedup only matches while a
        # request is pending and only suppresses a rejection for a cooldown, so
        # an approved gap was re-minted every TTL forever. Advisory dedup
        # matches at any age — but ONLY a request an operator actually decided
        # (it requires an Ai::ApprovalDecision row), and an advisory request is
        # minted with no expiry so no chain timeout can settle it in the first
        # place. A gap therefore stands as ONE queue item until a person
        # answers; a machine timeout can neither bury it nor count as consent.
        #
        # The flag is declared, never inferred: skill-less + applier-less does
        # NOT imply advisory (cert_expiring, module_promotion_ready and the
        # project.* bindings all act through services outside this engine), so
        # deriving it would silently change consent semantics for them.
        "system.capability_gap" => {
          skill: nil,
          action_category: "system.capability_gap_review",
          advisory: true
        }
      }.freeze

      # TTL on cross-tick fingerprint dedup. Same fingerprint within this
      # window is skipped at the engine level (no skill invocation, no
      # ApprovalRequest) — meaningfully reduces approval-queue churn for
      # signals that re-emit on every reconcile tick (e.g., a silent
      # instance lasts more than 60s).
      DEDUP_TTL_SECONDS = (ENV["FLEET_DEDUP_TTL_SECONDS"] || 600).to_i

      # F1-12: a member silent past this threshold is presumed dead. The
      # InstanceStatusSensor re-emits system.instance_silent every tick for as
      # long as the instance stays running/starting with a stale heartbeat —
      # and because the signal routes to system.instance_reprovision
      # (require_approval), the gate never auto-proceeds, so the loop never
      # closes and each tick bleeds an instance_silent FleetEvent (plus a
      # decision event) forever. Once silence is this sustained we stop fighting
      # the gate: a *running* instance is transitioned to error (a
      # non-destructive status correction — NOT the reprovision) and a single
      # escalation event is emitted. After that the sensor's running/starting
      # scan no longer matches the instance, so the per-tick stream stops at the
      # source. 30 min matches InstanceStatusSensor#severity_for's :critical
      # tier (cutoff - 30.minutes).
      PRESUMED_DEAD_SILENCE_SECONDS = (ENV["FLEET_PRESUMED_DEAD_SECONDS"] || 30 * 60).to_i

      # F3-11: consecutive ineffective RemediationOutcomes for a fingerprint
      # before the engine stops re-proceeding the same futile remediation and
      # escalates to an operator instead. The validate arc's score finally has
      # a consumer: at the threshold, decide() emits a fleet.remediation_stuck
      # event and forces the gate to require_approval regardless of the
      # configured policy (auto_approve / notify_and_proceed would otherwise
      # re-run the proven-ineffective action every dedup-TTL forever).
      STUCK_STREAK_THRESHOLD = (ENV["FLEET_REMEDIATION_STUCK_STREAK"] || 3).to_i

      attr_reader :autonomy_service, :account

      def initialize(autonomy_service:)
        @autonomy_service = autonomy_service
        @account = autonomy_service.account
      end

      # Process a single signal — bind to skill, plan, gate, return decision.
      # Returns a decision hash with :gate, :decision, optional :skill_result.
      def decide(signal)
        signal = ::System::Fleet::Signal.from_hash(signal) unless signal.is_a?(::System::Fleet::Signal)

        # F1-12: terminal sustained-silence fail-safe. Runs BEFORE the raw
        # signal event below so the reaping tick emits the single
        # presumed-dead escalation INSTEAD of yet another instance_silent
        # event. Returns a decision (short-circuiting the gate) only when it
        # actually reaps; otherwise nil and the normal flow continues.
        if (reaped = reap_presumed_dead!(signal))
          return reaped
        end

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

        # F3-11: consume the validate arc's score. A fingerprint whose last N
        # validated remediations were ALL ineffective stops auto-proceeding —
        # re-running the same futile action is noise, not remediation. Skip
        # the (equally futile) skill re-plan, surface ONE remediation_stuck
        # event, and force the gate to require_approval so an operator
        # decides. ApprovalRequest dedup keeps this to one open approval.
        streak = ineffective_streak(signal)
        if streak >= STUCK_STREAK_THRESHOLD
          decision = escalate_stuck_remediation!(signal, binding, streak)
          ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
          return decision
        end

        skill_result = invoke_skill(binding, signal) if binding[:skill]

        gate_result = autonomy_service.gate_action!(
          binding[:action_category],
          metadata: skill_metadata_payload(signal, skill_result),
          reasoning: { summary: build_summary(signal, skill_result) },
          force_policy: force_policy_for(signal),
          advisory: advisory?(binding)
        )

        record_decision!(signal)

        decision = gate_result.merge(
          signal_kind: signal.kind,
          fingerprint: signal.fingerprint, # self-improvement: the validate-step match key
          action_category: binding[:action_category],
          skill_result: skill_result
        )
        decision[:remediation] = apply_remediation!(signal, skill_result) if gate_result[:decision] == :proceed
        ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
        decision
      end

      # Process a list of signals; returns the array of decisions.
      def decide_all(signals)
        Array(signals).map { |s| decide(s) }
      end

      # F3-01: the act arm of the require_approval lane. Reconstructs the
      # original signal from the approved request's stamped identity
      # (skill_metadata_payload) and replays it through the SAME execution
      # machinery as the proceed lane: side-effectful skills re-run in
      # execute mode (the human approval IS the policy decision, so no
      # dry_run downgrade), then apply_remediation! routes through
      # REMEDIATION_APPLIERS. Always returns a result hash — never raises —
      # so the caller can stamp request_data even for unexecutable requests.
      def execute_approved!(request)
        data = request.request_data.is_a?(Hash) ? request.request_data : {}
        payload = data["payload"].is_a?(Hash) ? data["payload"] : {}
        kind = payload["signal_kind"]
        if kind.blank?
          return { applied: false,
                   reason: "request_data missing signal_kind — pre-F3-01 request, cannot replay" }
        end

        signal = ::System::Fleet::Signal.from_hash(
          "kind" => kind,
          "severity" => payload["signal_severity"].presence || "medium",
          "payload" => payload.except("signal_kind", "signal_severity", "signal_fingerprint", "skill_plan"),
          # Signal requires a fingerprint; replays of requests stamped before
          # the fingerprint landed in skill_metadata_payload synthesize one
          # from the request identity (only used for logging/dedup display).
          "fingerprint" => payload["signal_fingerprint"].presence || "approved:#{request.id}"
        )

        binding = SIGNAL_BINDINGS[signal.kind]
        skill_result = nil
        if binding && binding[:skill] && binding[:side_effectful]
          inputs = binding.fetch(:input_mapper).call(signal)
          if inputs
            executor = binding[:skill].new(account: account, agent: autonomy_service.agent, user: nil)
            skill_result = executor.execute(**inputs)
          end
        end

        result = apply_remediation!(signal, skill_result)
        # Surface what the executor actually did in the execution stamp — for
        # skills whose work IS the dispatch (no REMEDIATION_APPLIERS entry, e.g.
        # the boot-image drift rollout), apply_remediation! reports "no applier",
        # so without this the audit trail loses which nodes were acted on.
        if skill_result.is_a?(Hash) && skill_result[:data].is_a?(Hash)
          result = result.merge(skill_data: skill_result[:data])
        end
        result
      rescue StandardError => e
        Rails.logger.error("[FleetDecisionEngine] approved execution failed for ApprovalRequest #{request.id}: #{e.class}: #{e.message}")
        { applied: false, reason: "#{e.class}: #{e.message}" }
      end

      private

      # A binding that surfaces a condition without ever actuating. Opt-in per
      # binding (never inferred — see the capability_gap entry); changes two
      # gate behaviors in FleetAutonomyService#gate_action!: no consent-budget
      # consumption, and a durable operator decision on the request.
      def advisory?(binding)
        binding[:advisory] == true
      end

      # Control-plane fence skip result — uniform applied:false for an actuate
      # path asked to act on an instance owned by another control plane.
      def foreign_control_plane_skip(instance)
        { applied: false, instance_id: instance.id,
          reason: "instance owned by another control plane — skipped (control-plane fence)" }
      end

      # RCP v2 INV-1 counterpart to foreign_control_plane_skip above — same
      # shape, distinct reason, distinct fence (SelfManagementFence).
      def self_managed_skip(instance)
        { applied: false, instance_id: instance.id,
          reason: "instance is this control plane's own hosting node — skipped (INV-1 self-management fence)" }
      end

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

      # F1-12: reap a running instance whose heartbeat has been silent past
      # PRESUMED_DEAD_SILENCE_SECONDS. Re-reads the LIVE instance (not the
      # signal's stale snapshot — it may have recovered between sense and
      # decide) and acts only on a currently-running instance with a present,
      # genuinely-old heartbeat:
      #   - a nil heartbeat (never enrolled) is left to the bootstrap/approval
      #     path — we don't presume-dead an instance that never reported.
      #   - a starting/stopping/etc. instance is mid-lifecycle, not running, so
      #     it is out of scope (acceptance is specifically running -> error).
      # Returns the decision hash on reap (caller short-circuits the gate), or
      # nil to let the normal sense -> decide -> act flow run.
      def reap_presumed_dead!(signal)
        return nil unless signal.kind == "system.instance_silent"

        instance_id = signal.payload.is_a?(Hash) ? signal.payload["instance_id"] : nil
        return nil if instance_id.blank?

        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: instance_id)
        return nil unless instance && instance.status == "running"
        # Control-plane fence: never reap a fleet member owned by another plane.
        return nil unless owned_by_this_control_plane?(instance)
        # RCP v2 INV-1: never reap this control plane's own hosting instance —
        # that decision must come from the consensus group, not this
        # reconciler's own tick.
        return nil if self_managed_target?(instance)

        heartbeat = instance.last_heartbeat_at
        return nil if heartbeat.nil?
        return nil if heartbeat > Time.current - PRESUMED_DEAD_SILENCE_SECONDS

        previous_status = instance.status
        silent_seconds = (Time.current - heartbeat).round
        instance.update!(status: "error")

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "system.instance_presumed_dead",
          severity: :critical,
          payload: {
            "instance_id" => instance.id,
            "node_id" => instance.node_id,
            "previous_status" => previous_status,
            "last_heartbeat_at" => heartbeat.iso8601,
            "silent_seconds" => silent_seconds,
            "threshold_seconds" => PRESUMED_DEAD_SILENCE_SECONDS
          },
          source: "decision_engine.presumed_dead"
        )

        {
          decision: :presumed_dead,
          reason: "instance #{instance.id} silent #{silent_seconds}s " \
                  "(>= #{PRESUMED_DEAD_SILENCE_SECONDS}s) — marked error, escalation emitted",
          signal_kind: signal.kind,
          action_category: "system.instance_presumed_dead",
          instance_id: instance.id,
          applied: true
        }
      end

      # F3-11: best-effort streak read — a feedback-loop hiccup must never
      # break the decide path (it would take ALL remediation down with it).
      def ineffective_streak(signal)
        ::System::Fleet::RemediationOutcome.ineffective_streak(
          account: account, fingerprint: signal.fingerprint
        )
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] ineffective-streak read failed: #{e.message}")
        0
      end

      # Campaign 019f6084 §2.4.3: system.template_closure_drift's blast
      # radius is TemplateApprovalPolicy's call, not the seeded
      # InterventionPolicy's — the sensor only ever fires for an instance
      # that already exists on the template (that's the drift condition),
      # so `provisioned_node_count` is never zero and the classification is
      # effectively always require_approval. Rather than duplicate that
      # reasoning here, trust the flag TemplateClosureDriftSensor already
      # computed via TemplateApprovalPolicy and force the gate with it —
      # same force_policy mechanism escalate_stuck_remediation! uses to
      # override a resolved policy that doesn't fit the moment. Every other
      # signal kind is unaffected (nil = let gate_action! resolve normally).
      def force_policy_for(signal)
        return nil unless signal.kind == "system.template_closure_drift"

        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        return nil unless payload["requires_approval"] || payload[:requires_approval]

        "require_approval"
      end

      # F3-11: the escalation lane. Emits the fleet.remediation_stuck event
      # (the operator-facing alert; bounded to once per DEDUP_TTL by the
      # engine's fingerprint dedup) and gates with a forced require_approval —
      # the resolved policy already proved itself ineffective N times.
      def escalate_stuck_remediation!(signal, binding, streak)
        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "fleet.remediation_stuck",
          severity: :high,
          payload: {
            "fingerprint" => signal.fingerprint,
            "signal_kind" => signal.kind,
            "action_category" => binding[:action_category],
            "ineffective_streak" => streak,
            "threshold" => STUCK_STREAK_THRESHOLD
          }.merge(signal.payload.is_a?(Hash) ? signal.payload.slice("instance_id", "node_id") : {}),
          source: "decision_engine.stuck_escalation",
          correlation_id: signal.fingerprint
        )

        gate_result = autonomy_service.gate_action!(
          binding[:action_category],
          metadata: skill_metadata_payload(signal, nil)
                      .merge("remediation_stuck_streak" => streak),
          reasoning: {
            summary: "Remediation stuck: #{signal.kind} (#{signal.fingerprint}) — " \
                     "#{streak} consecutive ineffective outcomes; operator decision required"
          },
          force_policy: "require_approval",
          # Unreachable for an advisory today (its outcomes are never recorded,
          # so the streak stays 0) — threaded anyway so the exemption can never
          # be lost by a future path that does reach here.
          advisory: advisory?(binding)
        )

        record_decision!(signal)

        gate_result.merge(
          signal_kind: signal.kind,
          fingerprint: signal.fingerprint,
          action_category: binding[:action_category],
          remediation_stuck: true,
          ineffective_streak: streak
        )
      end

      # Policies under which a side-effectful executor may perform its real
      # action pre-gate (the gate will resolve to the same policy and proceed).
      AUTO_EXECUTE_POLICIES = %w[auto_approve notify_and_proceed].freeze

      # Executor inputs come exclusively from the binding's input_mapper
      # (signal → kwargs, or nil to skip invocation). `fetch` raises on a
      # binding that declares a skill without a mapper or without a
      # side_effectful tag, so a mis-declared binding surfaces as an error
      # in the decision record instead of an executor that silently never
      # runs (F3-04) or one that acts before the gate (F3-06).
      def invoke_skill(binding, signal)
        skill_class = binding[:skill]
        return nil unless skill_class

        inputs = binding.fetch(:input_mapper).call(signal)
        return nil if inputs.nil?

        # F3-06: resolve the policy BEFORE invoking so require_approval and
        # block actually prevent the action instead of merely re-labelling
        # an action that already happened.
        if binding.fetch(:side_effectful)
          policy = autonomy_service.policy_for(binding[:action_category])&.dig(:policy)
          unless AUTO_EXECUTE_POLICIES.include?(policy)
            # Plan-only fallback: produce the dry_run plan for the approval
            # request when the executor supports it; otherwise skip.
            return nil unless policy == "require_approval" && binding[:dry_run_supported]
            inputs = inputs.merge(dry_run: true)
          end
        end

        executor = skill_class.new(account: account, agent: autonomy_service.agent, user: nil)
        executor.execute(**inputs)
      rescue StandardError => e
        Rails.logger.error("[FleetDecisionEngine] skill invocation failed: #{e.class}: #{e.message}")
        { success: false, error: e.message }
      end

      # F3-03: the act arm of sense → decide → act. A :proceed gate decision
      # must actually apply the remediation — before this existed, the
      # notify_and_proceed / auto_approve lanes only produced plans nothing
      # consumed, and every RemediationOutcome scored ineffective. Kinds
      # without an applier record applied: false on the decision (and the
      # decision event) so a proceed lane is never a SILENT no-op.
      # The reconcile task is the canonical apply path: ExecutionDispatcher
      # routes sync_modules / apply_config to the on-node runtime.
      REMEDIATION_APPLIERS = {
        "system.module_drift" => { command: "sync_modules" },
        "system.config_drift" => { command: "apply_config" },
        "system.storage_assignment_drift" => { method: :reconcile_storage_assignment },
        # F3-01: the instance_reprovision executor. A silent instance's agent
        # is unreachable, so on-node task commands cannot apply — the
        # remediation is a provider-side reboot via InstanceControlService.
        "system.instance_silent" => { method: :reboot_silent_instance },
        # IMP-555e29eeb4ab: provider-state drift (InstanceStateDriftSensor)
        # had no applier at all — every proceed recorded applied:false, so a
        # VM stopped/killed behind the platform's back stayed "running" in
        # the model forever. There is nothing to actuate here (the drift IS
        # the real state); the remediation is a model-side convergence to
        # the provider-reported status.
        "system.instance_state_drifted" => { method: :converge_instance_state_drift },
        # IMP-83471cc28e1a: honeypot quarantine (F3-08) routes through
        # system.instance_terminate but, like instance_silent, has no skill
        # and no on-node task to dispatch — the remediation IS the
        # provider-side terminate. Without this entry the approved gate's
        # apply_remediation! fell through to the "no applier" branch and the
        # compromised instance was never terminated despite the operator
        # approving the quarantine.
        "system.honeypot_access" => { method: :quarantine_honeypot_instance },
        # Campaign 019f6084 §2.4.3 — TemplateApplyService#apply! creates the
        # missing assignments; a cloud_init instance also gets a sync_modules
        # task (reuses dispatch_reconcile_task, same as system.module_drift).
        # A pivot instance's composed union is boot-time-fixed, so the task
        # is skipped in favor of a requires_reprovision flag — see
        # #apply_template_closure_drift.
        "system.template_closure_drift" => { method: :apply_template_closure_drift },
        # IMP-41eb6ddbc490: staging→blessed was fully built for detection and
        # gating and dead-ended here. ModulePromotionSensor found eligible
        # versions and the binding routed them through require_approval, but
        # ModulePromotionService.promote! had ZERO call sites in application
        # code and this constant had no entry — so an operator could approve a
        # promotion and apply_remediation! returned "no applier". Same class as
        # IMP-555e29eeb4ab and IMP-83471cc28e1a above, and the reason the
        # binding's "invoked directly" comment was wrong rather than merely
        # imprecise.
        "system.module_promotion_ready" => { method: :apply_module_promotion }
      }.freeze

      OPEN_TASK_STATUSES = %w[pending scheduled running].freeze

      def apply_remediation!(signal, skill_result)
        applier = REMEDIATION_APPLIERS[signal.kind]
        return { applied: false, reason: "no applier for #{signal.kind}" } unless applier

        if applier[:method]
          send(applier[:method], signal, skill_result)
        else
          dispatch_reconcile_task(signal, skill_result, command: applier[:command])
        end
      rescue StandardError => e
        Rails.logger.error("[FleetDecisionEngine] remediation apply failed: #{e.class}: #{e.message}")
        { applied: false, reason: e.message }
      end

      # F3-07: re-run reconciliation for an assignment the sensor flagged as
      # stale — the sensor itself is read-side and must not mutate.
      # F3-01 — provider-side reboot for an approved instance_reprovision.
      # Account-scoped lookup; returns the same applied/reason shape as the
      # other appliers so the decision/event/stamp paths stay uniform.
      #
      # IMP-f5f03a7e8d3b: the approval TTL (1h) outlives the F1-12
      # presumed-dead reap threshold (30 min — reap_presumed_dead! above), so
      # by the time an operator approves the instance is USUALLY already
      # flipped running -> error — the race is the norm, not an edge case.
      # NodeInstance's AASM :reboot event only transitions from :running, so
      # hardcoding action: "reboot" made the approved self-heal return
      # applied:false against exactly the state the reap itself produces,
      # stranding the instance for manual intervention every time. Pick the
      # AASM-legal action for the instance's CURRENT status instead: reboot
      # when still running, start when stopped/error (the self-heal intent —
      # bring it back — is the same; "start" is just the legal verb from a
      # not-currently-running row). :stopped is reachable here too if an
      # operator manually stopped the same instance_silent instance before
      # approving the pending reprovision request — "start" is still the
      # right call: the approval itself is the operator's decision to bring
      # it back. A :starting instance (never reached running) has no legal
      # forward transition from here at all; surfaced as applied:false with
      # a status-specific reason rather than a generic provider error.
      def reboot_silent_instance(signal, _skill_result)
        id = signal.payload.is_a?(Hash) ? (signal.payload["instance_id"] || signal.payload[:instance_id]) : nil
        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
        return { applied: false, reason: "instance not found: #{id.inspect}" } unless instance
        return foreign_control_plane_skip(instance) unless owned_by_this_control_plane?(instance)
        return self_managed_skip(instance) if self_managed_target?(instance)

        action = if instance.may_reboot?
                   "reboot"
        elsif instance.may_start?
                   "start"
        end
        unless action
          return { applied: false, instance_id: instance.id,
                   reason: "instance in #{instance.status} status — no self-heal action available, needs manual intervention" }
        end

        result = ::System::InstanceControlService.execute(instance: instance, action: action)
        if result.respond_to?(:success?)
          { applied: result.success?, action: action, instance_id: instance.id,
            reason: (result.respond_to?(:error) ? result.error : nil) }.compact
        else
          { applied: true, action: action, instance_id: instance.id }
        end
      end

      # IMP-555e29eeb4ab: maps InstanceStateDriftSensor's actual_status (the
      # provider-reported state) to the AASM event that reconciles the model
      # to match it. "terminated" uses `terminate` rather than the narrower
      # `mark_terminated` finalizer — mark_terminated only allows from
      # [terminated, stopped, running, error] (node_instance.rb), so an
      # instance that drifted into :stopping/:rebooting/etc. between sense
      # and this proceed (e.g. an operator issued a stop/reboot on the same
      # instance concurrently) would never converge. `terminate` is legal
      # from every non-terminal state (F4-02 — "once the provider destroys
      # the cloud resource, the DB row must always reach :terminated"),
      # which is exactly this case. stopped/error keep the narrower
      # finalizers since the sensor only ever senses from :running, which
      # both mark_stopped and mark_errored already cover.
      CONVERGENCE_EVENT_FOR_ACTUAL_STATUS = {
        "stopped" => :mark_stopped!,
        "terminated" => :terminate!,
        "error" => :mark_errored!
      }.freeze

      # IMP-555e29eeb4ab: the instance_state_drifted applier. Unlike
      # reboot_silent_instance, there is nothing to actuate — the provider
      # already transitioned the VM (or is itself reporting error) — so this
      # just replays the matching AASM finalizer event instead of calling
      # InstanceControlService, keeping the transition legal and audited
      # (System::LifecycleAuditable) like every other real status change.
      def converge_instance_state_drift(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        id = payload["instance_id"] || payload[:instance_id]
        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
        return { applied: false, reason: "instance not found: #{id.inspect}" } unless instance
        return foreign_control_plane_skip(instance) unless owned_by_this_control_plane?(instance)
        return self_managed_skip(instance) if self_managed_target?(instance)

        actual_status = (payload["actual_status"] || payload[:actual_status]).to_s
        event = CONVERGENCE_EVENT_FOR_ACTUAL_STATUS[actual_status]
        unless event
          return { applied: false, instance_id: instance.id,
                   reason: "no convergence mapping for actual_status=#{actual_status.inspect}" }
        end

        # Re-check the LIVE status, not the signal's (possibly stale)
        # snapshot — the sensor may have already re-synced, or an operator
        # may have acted manually, between sense and this proceed.
        if instance.status == actual_status
          return { applied: false, instance_id: instance.id, reason: "already converged to #{actual_status}" }
        end

        predicate = "may_#{event.to_s.delete_suffix('!')}?"
        unless instance.public_send(predicate)
          return { applied: false, instance_id: instance.id,
                   reason: "instance in #{instance.status} status — no legal transition to #{actual_status}" }
        end

        instance.public_send(event)
        { applied: true, instance_id: instance.id, converged_to: instance.status }
      end

      # IMP-83471cc28e1a: quarantine the compromised instance behind an
      # approved honeypot-access signal. HoneypotAccessSensor#signals_for can
      # emit a module-only signal (no hosting instance found at sense time)
      # when nothing currently runs the accessed canary — nothing to
      # terminate, so that's applied: false with a clear reason rather than
      # an error. Same applied/reason shape as the other appliers.
      # Actuates an approved staging→blessed promotion.
      #
      # RE-CHECKS THE STATE rather than trusting the signal. The approval gate
      # carries a TTL, so the version can move between the sensor firing and an
      # operator approving — and unlike the converge-style appliers above,
      # re-promoting is not a harmless no-op, it is an invalid transition. The
      # same reasoning the instance_reprovision applier documents about
      # approvals outliving the state they were raised for.
      #
      # Eligibility is NOT re-checked here on purpose: ModulePromotionService
      # #promote! re-evaluates PromotionCriteria itself for a blessed target,
      # so the approved promotion passes the same gate a direct promotion
      # would. Duplicating it here would let the two drift.
      def apply_module_promotion(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        id = payload["module_version_id"] || payload[:module_version_id]
        return { applied: false, reason: "no module_version_id in payload" } if id.blank?

        version = ::System::NodeModuleVersion
                  .joins(node_module: :account)
                  .where(accounts: { id: account.id })
                  .find_by(id: id)
        return { applied: false, reason: "module version not found: #{id.inspect}" } unless version

        unless version.promotion_state == "staging"
          return { applied: false,
                   reason: "version is #{version.promotion_state}, no longer staging — " \
                           "the approval outlived the state it was raised for" }
        end

        result = ::System::Fleet::ModulePromotionService.promote!(version: version, target_state: "blessed")
        {
          applied: result.ok?,
          action: "module_promote_to_live",
          module_version_id: version.id,
          promoted_to: (result.ok? ? "blessed" : nil),
          reason: result.error
        }.compact
      end

      def quarantine_honeypot_instance(signal, _skill_result)
        id = signal.payload.is_a?(Hash) ? (signal.payload["instance_id"] || signal.payload[:instance_id]) : nil
        return { applied: false, reason: "no instance to quarantine (module-only honeypot signal)" } if id.blank?

        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
        return { applied: false, reason: "instance not found: #{id.inspect}" } unless instance
        return foreign_control_plane_skip(instance) unless owned_by_this_control_plane?(instance)
        return self_managed_skip(instance) if self_managed_target?(instance)

        result = ::System::InstanceControlService.execute(instance: instance, action: "terminate")
        if result.respond_to?(:success?)
          { applied: result.success?, action: "terminate", instance_id: instance.id,
            reason: (result.respond_to?(:error) ? result.error : nil) }.compact
        else
          { applied: true, action: "terminate", instance_id: instance.id }
        end
      end

      def reconcile_storage_assignment(signal, _skill_result)
        id = signal.payload.is_a?(Hash) ? signal.payload["storage_assignment_id"] : nil
        assignment = ::System::StorageAssignment.where(account_id: account.id).find_by(id: id)
        return { applied: false, reason: "storage assignment not found" } unless assignment

        ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(assignment)
        { applied: true, storage_assignment_id: assignment.id }
      end

      # Campaign 019f6084 §2.4.3 — the approved arm of
      # TemplateClosureDriftSensor. Reuses TemplateApplyService (never
      # reimplements closure resolution) to materialize the assignments the
      # template's current closure is missing, then splits on boot
      # composition:
      #   - cloud_init instance: the on-node reconcile loop CAN remount the
      #     union live, so this reuses dispatch_reconcile_task — the SAME
      #     sync_modules apply path system.module_drift uses — to converge
      #     it now.
      #   - pivot instance (direct_kernel/uefi_disk): the composed union is
      #     boot-time-fixed (memory: live-module-refresh-no-remount-pivot —
      #     a live sync updates running_module_digests but never remounts
      #     the union), so queuing sync_modules would be a silent no-op.
      #     The assignments are still created (a future reboot/reprovision
      #     picks them up); the result is flagged requires_reprovision so
      #     nothing downstream mistakes this for a completed convergence.
      def apply_template_closure_drift(signal, skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        instance_id = payload["instance_id"] || payload[:instance_id]
        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: instance_id)
        return { applied: false, reason: "instance not found: #{instance_id.inspect}" } unless instance
        return foreign_control_plane_skip(instance) unless owned_by_this_control_plane?(instance)
        return self_managed_skip(instance) if self_managed_target?(instance)

        node = instance.node
        return { applied: false, reason: "instance has no node" } unless node

        apply_result = ::System::TemplateApplyService.new(node).apply!
        unless apply_result.ok?
          reason = Array(apply_result.errors).join("; ").presence || "template apply failed"
          return { applied: false, instance_id: instance.id, reason: reason }
        end

        created_module_ids = apply_result.created.map(&:node_module_id)

        if instance.pivot_boot?
          return {
            applied: true, instance_id: instance.id, node_id: node.id,
            assignments_created: created_module_ids, requires_reprovision: true,
            reason: "pivot-booted instance composes its module union at boot — assignments created; " \
                    "a rolling reprovision (reboot) is required for them to take effect"
          }
        end

        sync_result = dispatch_reconcile_task(signal, skill_result, command: "sync_modules")
        sync_result.merge(assignments_created: created_module_ids, requires_reprovision: false)
      end

      def dispatch_reconcile_task(signal, skill_result, command:)
        plan = skill_result.is_a?(Hash) ? skill_result[:data] : nil
        plan = plan.respond_to?(:with_indifferent_access) ? plan.with_indifferent_access : {}
        # The executor's disruption budget still gates auto-apply even when
        # the policy proceeds — a >max_disruption_pct plan needs an operator.
        return { applied: false, reason: "plan disruption exceeds auto-apply budget" } if plan[:requires_approval]

        # F3-09: config_drift payloads carry instance_ids (per-node running
        # set) rather than a single instance_id — accept either shape.
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        target_id = payload["instance_id"] || Array(payload["instance_ids"]).first
        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: target_id)
        return { applied: false, reason: "instance not found" } unless instance
        return foreign_control_plane_skip(instance) unless owned_by_this_control_plane?(instance)
        return self_managed_skip(instance) if self_managed_target?(instance)

        if ::System::Task.where(account: account, operable: instance,
                                command: command, status: OPEN_TASK_STATUSES).exists?
          return { applied: false, reason: "reconcile task already in flight" }
        end

        task = ::System::Task.create!(
          account: account, operable: instance, command: command, status: "pending",
          options: {
            "source" => "fleet_autonomy",
            "signal_kind" => signal.kind,
            "signal_fingerprint" => signal.fingerprint,
            "planned_actions" => plan[:planned_actions]
          }
        )
        { applied: true, task_id: task.id, command: command }
      end

      def skill_metadata_payload(signal, skill_result)
        base = signal.payload.is_a?(Hash) ? signal.payload.deep_stringify_keys : {}
        # F3-01: stamp the signal identity so an approved request can be
        # replayed later (execute_approved!) — request_data only stores the
        # action_category otherwise, and the applier table is signal-kind keyed.
        base = base.merge(
          "signal_kind" => signal.kind,
          "signal_severity" => signal.severity.to_s,
          "signal_fingerprint" => signal.fingerprint
        ).compact
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
