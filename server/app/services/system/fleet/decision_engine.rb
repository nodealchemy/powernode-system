# frozen_string_literal: true

module System
  module Fleet
    # Routes signals from sensors to skills + actions. Each signal kind is
    # bound to (a) a skill that produces a plan and (b) an action_category
    # that goes through FleetAutonomyService#gate_action!. The engine has
    # no policy logic of its own — that lives in InterventionPolicy rows.
    #
    # Reference: Golden Eclipse plan M7 — DecisionEngine. Follows the
    # platform's decision-execution shape but stays much smaller: we only
    # need to thread (signal → skill → gate → execute-or-record) for v0,
    # without the additional flow control richer domains use (concurrency
    # caps, role-based dispatch).
    class DecisionEngine
      # Control-plane fence — never reap/actuate on an instance owned by a
      # DIFFERENT control plane (imp 019f6d6b-63e5). Kept ALONGSIDE the existing
      # account scoping (belt-and-suspenders). Inert until a self-id is
      # configured (single-plane) and until #14 stamps owners.
      include ::System::Autonomy::ControlPlaneFence

      # This engine ROUTES: SIGNAL_BINDINGS maps a signal kind onto an
      # action_category that both gate_action! call sites hand to the gate.
      # Declaring that makes the routing enumerable, so RoutedLaneGuard reads
      # the union of every router rather than this one alone
      # (IMP-7a6c9a70e050). `routed_action_categories` below is the declaration.
      extend ::System::Autonomy::ActionCategoryRouter

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
        # IMP-e2f53e87d090 (APO-2b) — InstanceUnrecoverableSensor. The
        # DISASTER-RECOVERY counterpart to system.instance_silent above.
        #
        # instance_silent means "the agent stopped phoning home" and its
        # applier (#reboot_silent_instance) answers with a reboot/start. Three
        # conditions produced that same signal and that same reboot even though
        # a reboot can never fix them: the VM is terminated/error at the
        # provider, the host's every provider connection is unusable, or the
        # platform has already rebooted it and the validate arc scored those
        # outcomes ineffective. DR's answer to all three is REPLACE, so it gets
        # its own kind and its own operator-tunable category
        # (system.instance_replace, seeded require_approval) rather than
        # widening what the reboot lane means.
        #
        # skill: nil — there is nothing an executor would add. The sensor's
        # payload already carries the classified reason, which is the whole
        # content of the operator decision.
        #
        # NO APPLIER, DELIBERATELY, and this is the one thing not to "fix" by
        # analogy with the appliers below. Replacing an instance is a
        # destructive multi-step provision (terminate, re-provision from the
        # template/pool, re-attach storage and addresses) that no service on
        # this side performs today; wiring a partial one here would make an
        # approved replace look actuated while leaving the fleet short an
        # instance. The category is therefore DECLARED in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES so the
        # equality oracle in proceed_lane_actuation_spec sees a silent lane
        # that says it is silent, and so a retune away from require_approval
        # cannot mint pending outcomes that score ineffective every settle
        # window into a false fleet.remediation_stuck.
        "system.instance_unrecoverable" => {
          skill: nil,
          action_category: "system.instance_replace"
        },
        # Node mTLS cert nearing expiry (CertificateExpirySensor).
        #
        # IMP-43e94c9d46d4: this comment used to say cert rotation was handled
        # directly by a rotate method on NodeCertificate. No such method has
        # ever existed — the model defines due_for_rotation?, revoke! and the
        # predicates, and nothing else. The lane had no applier either, so every
        # proceed returned "no applier" while the comment asserted the opposite.
        #
        # skill: nil stays. The remediation is model-side (see
        # #rotate_node_certificate in REMEDIATION_APPLIERS) and there is
        # deliberately no executor: re-issuing a node cert requires a CSR the
        # AGENT generates, because the private key never leaves the node. The
        # platform cannot mint a usable cert on its own, and the applier says
        # so rather than pretending it converged.
        "system.cert_expiring" => {
          skill: nil,
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
        # IMP-cd2ecc3a7a7a — ModulePromotionBacklogSensor, the STALL
        # counterpart to the ready signal above. Notify-level with skill: nil
        # under its own dedicated category, the StuckTaskBacklogSensor /
        # SdwanOvnDeploymentHealthSensor shape.
        #
        # WHY NO APPLIER, AND WHY ONE MUST NOT BE ADDED. This kind means "a
        # newer usable version exists and the fleet is still running the old
        # one, past the lag budget". The remedy is to repoint
        # NodeModule#current_version_id — which is exactly what some gate,
        # some broken publish chain, or a deliberate operator hold has not
        # done. An applier here would promote an artifact past whatever
        # refused it, autonomously, on the strength of a timer. The sensor's
        # own header records why the refusal cannot be read back: on
        # 2026-08-25 the gate stopped emitting withheld events entirely and
        # still never promoted. So this lane reports, and a person decides.
        #
        # DO NOT collapse to system.observation. The fleet seed maps that to
        # auto_approve, which takes gate_action!'s bare :proceed arm; the
        # dedicated category is seeded notify_and_proceed, which is a
        # separately tunable operator-facing policy row (the Autonomy modal
        # registry derives from PolicyDeclarations::FLEET_AUTONOMY_POLICIES, so
        # the seeded category is what makes this lane retunable at all).
        # Collapsing it would fold a standing stall into the same silent
        # auto-approved bucket as routine observations while the binding and
        # doc guards both went green — the precise failure mode this sensor was
        # built to catch, reproduced one layer up. (Be accurate about the
        # notify half: notify_and_proceed's extra step is
        # FleetAutonomyService#notify_action, which today is a Rails.logger
        # line, not an operator notification. The tunable policy row is the
        # load-bearing difference, not a page.)
        #
        # Listed in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES:
        # a stall stands until a person acts, so its fingerprint would
        # otherwise score ineffective every settle window and trip a false
        # fleet.remediation_stuck escalation for a lane that never acted.
        #
        # advisory: true — DECLARED, and load-bearing here in a way it is NOT
        # for StuckTaskBacklogSensor / SdwanOvnDeploymentHealthSensor. Those
        # put no module_id in their payloads, so gate_action!'s
        # consent_module_id is blank and ConsentBudgetService#check_and_consume!
        # short-circuits. (The engine states that explicitly, though on a
        # third notify-only block rather than these two: the
        # SdwanServiceHealthSensor pair below calls advisory "inert here at
        # best" for exactly this reason. Cited where it actually lives — the
        # StuckTaskBacklog and OVN bindings carry no such note.)
        # This sensor DOES stamp module_id (the stalled module's own id), and
        # skill_metadata_payload passes the payload straight through as gate
        # metadata. Without the flag a standing stall would re-decide every
        # DEDUP_TTL_SECONDS (600s → ~144×/day) and drain that module's
        # operator-set 24h consent ceiling with a no-op, pushing the module's
        # REAL remediations down the budget-exhausted branch. That is verbatim
        # the live defect recorded on the capability_gap binding below, whose
        # shape this shares: module-stamped, standing, and applier-less. The
        # flag's other effect (a durable operator decision on the request) is
        # inert on this lane: create_pending_approval is reached only from the
        # require_approval arm and from the budget-exhausted arm (itself inside
        # `unless advisory`), and force_policy_for escalates one kind only —
        # system.template_closure_drift — so nothing can route this kind there.
        "system.module_promotion_stalled" => {
          skill: nil,
          action_category: "system.module_promotion_investigate",
          advisory: true
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
          # can filter for it. Observe-only: nothing consumes it to throttle
          # or defer actions (the planned consume-side throttle was never
          # wired and was deleted — IMP-86be386ac485).
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
        # IMP-2f34679b6b73 — SdwanBgpSessionHealthSensor's attribution family.
        # The writer now refuses to file a BGP session it cannot attribute to
        # the network it was reported under (a host-wide FRR polled without a
        # VRF answers for one routing context and was replayed under every
        # iBGP network the host belongs to). That refusal is the honest
        # answer, and it is also an ABSENCE, so it has to be routed somewhere
        # an operator sees it or the fix is silent.
        #
        # skill: nil deliberately — SdwanBgpSessionRemediateExecutor restarts
        # FRR, and restarting FRR does not make an unscoped poll scoped. The
        # repair is rolling out an agent that names the VRF.
        #
        # NOT system.observation: that category is seeded auto_approve, which
        # collects for dashboards without reaching an operator (see the
        # sdwan_service_silent note above for the same trap). Its own
        # notify_and_proceed category instead, which is therefore also listed
        # in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES — this
        # lane proceeds but never actuates, and without that membership the
        # standing fingerprint would manufacture a false
        # fleet.remediation_stuck escalation.
        "system.sdwan_bgp_observation_unattributable" => {
          skill: nil,
          action_category: "system.sdwan_bgp_observation_investigate"
        },
        "system.sdwan_bgp_observation_not_measured" => {
          skill: nil,
          action_category: "system.sdwan_bgp_observation_investigate"
        },
        # IMP-c7d663f24a0b — SdwanServiceHealthSensor. Both kinds are
        # notify-level with skill: nil, deliberately: the sensor's whole point
        # is that the overlay is HEALTHY and the workload is not, so every
        # existing sdwan_* executor (peer remediate, failover, key rotate)
        # would act on plumbing this signal has just proven fine. They share
        # one action_category because they share one disposition — surface to
        # the operator — while keeping distinct kinds and fingerprints so
        # dedup and dashboards can tell a dead service from a dead DNAT rule.
        #
        # DO NOT "simplify" these to system.observation. It looks like the
        # same shape (skill: nil, notify-level) and is not: the fleet seed maps
        # system.observation to auto_approve and this category to
        # notify_and_proceed, so the swap silently downgrades the gate and the
        # signal reaches NO operator — a dead published service would then be
        # observed and never reported, which is the exact outcome this sensor
        # exists to prevent. Nor add `advisory: true`; per the declared-never-
        # inferred rule this engine states for that flag, it is inert here at
        # best.
        "system.sdwan_service_silent" => {
          skill: nil,
          action_category: "system.sdwan_service_health_investigate"
        },
        "system.sdwan_portmap_orphaned" => {
          skill: nil,
          action_category: "system.sdwan_service_health_investigate"
        },
        # IMP-57e9a90598ee — SdwanOvnDeploymentHealthSensor. Both kinds are
        # notify-level with skill: nil under ONE dedicated category, the
        # SdwanServiceHealthSensor shape and for the same reason: the fleet
        # seed maps this category to notify_and_proceed so the signal reaches
        # an operator, while system.observation would auto_approve it into
        # silence. No executor is bound by design — the degraded/stalled
        # component is the operator's OVN control infrastructure (northd,
        # NB/SB DBs), which the platform does not provision and must not
        # blindly poke; the category is therefore also listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES.
        "system.sdwan_ovn_deployment_degraded" => {
          skill: nil,
          action_category: "system.sdwan_ovn_deployment_investigate"
        },
        "system.sdwan_ovn_activation_stalled" => {
          skill: nil,
          action_category: "system.sdwan_ovn_deployment_investigate"
        },
        # IMP-da1b772c2596 — SdwanApplyHealthSensor. The agent's OBSERVED
        # apply outcome, which nothing on the server read until now: a node
        # whose nftables/vrf/bridge apply failed every tick was scored as
        # healthy because the platform had SERVED the config successfully.
        #
        # skill: nil, and there is no safe applier to name. A failed apply is
        # a kernel-side refusal the agent already retries on every tick, so
        # re-serving the same config remediates nothing; the repair is an
        # image or a config a person has to change. Same category for both
        # kinds because they share one disposition (reach an operator) while
        # keeping distinct kinds and fingerprints so a failing applier and an
        # unmeasured fleet stay separable.
        #
        # DO NOT collapse to system.observation — the fleet seed maps that to
        # auto_approve, which would file the signal for dashboards and reach
        # NO operator. Listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES for the
        # standing-fingerprint reason recorded there.
        "system.sdwan_apply_failed" => {
          skill: nil,
          action_category: "system.sdwan_apply_investigate"
        },
        "system.sdwan_apply_not_measured" => {
          skill: nil,
          action_category: "system.sdwan_apply_investigate"
        },
        # IMP-7034199a5a19 — SdwanUserDeviceConfigStalenessSensor. A user
        # device's WireGuard config is rendered ONCE, at download time, and the
        # bootstrap URL is 410 immediately after; node peers re-pull the same
        # surface every tick. So a VIP, a peer lan_subnet, or a federation
        # prefix added afterwards is missing from every previously-issued
        # client's AllowedIPs — silently, since AllowedIPs is a routing filter
        # and not a label.
        #
        # skill: nil, and NO remediation_action is named. The drifted artefact
        # is a text file on a user's laptop: the platform cannot reach it, and
        # binding the nearest side-effectful sdwan_* executor would act on
        # plumbing that is fine. The repair is a person re-issuing the device.
        #
        # DO NOT collapse to system.observation — the fleet seed maps that to
        # auto_approve, which files the signal for dashboards and reaches NO
        # operator, which is the entire point of this lane. Listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES for the
        # standing-fingerprint reason recorded there.
        "system.sdwan_user_device_config_stale" => {
          skill: nil,
          action_category: "system.sdwan_user_device_config_investigate"
        },
        # IMP-3855ff9908f2 — ModuleVerifyFailedSensor. The manifest's `verify:`
        # block asserts a RESOLVED PATH (never mere existence) in BOTH a login
        # and a non-login shell; the agent reports what the node actually
        # resolved, and this lane is what carries a mismatch to a person.
        #
        # skill: nil, and there is no safe applier to name. A failed probe
        # means the node's filesystem or PATH is not what the manifest says:
        # a wrong artifact, a shadowing package, a profile script reordering
        # PATH. Re-serving the same module changes none of those — in the
        # gitleaks v4 incident the artifact the platform would re-serve was
        # the EMPTY one that caused the failure. The repair is a person
        # changing an artifact or an image.
        #
        # Same category for both kinds because they share one disposition
        # (reach an operator), while keeping distinct kinds and fingerprints
        # so a proven failure and an unverified fleet stay separable.
        #
        # DO NOT collapse to system.observation — the fleet seed maps that to
        # auto_approve, which files the signal for dashboards and reaches NO
        # operator. Listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES for the
        # standing-fingerprint reason recorded there.
        # No skill: there is no applier for "the janitor is inert" and there
        # can be none — the causes are code and configuration. See
        # StuckTaskBacklogSensor. Routed to an investigate category so it
        # reaches an operator; NOT system.observation, which the seed
        # auto_approves into a dashboard nobody is paged by.
        "system.task_backlog_stuck" => {
          skill: nil,
          action_category: "system.task_backlog_investigate"
        },
        "system.module_verify_failed" => {
          skill: nil,
          action_category: "system.module_verify_investigate"
        },
        "system.module_verify_not_measured" => {
          skill: nil,
          action_category: "system.module_verify_investigate"
        },
        # IMP-a8f9fa74284d — BootLkgArmSensor. System::BootLkgStateWriter has
        # derived `arm_state` on every heartbeat since IMP-b8d5cfa33b79 and
        # nothing consumed it: the platform could answer "is this node armed
        # with a valid last-known-good?" while the question an operator faces
        # before pulling a control plane was still answered by the absence of
        # an alarm.
        #
        # skill: nil, and there is NO safe applier to name. The LKG is frozen
        # on the node's own disk by the agent at boot; nothing the platform can
        # dispatch re-arms it, and borrowing the nearest side-effectful
        # executor to fill this slot would act on plumbing that is fine
        # (IMP-df40782d3f4d is the precedent for why that is worse than an
        # unbound lane). The repair is a person restoring or re-capturing the
        # LKG.
        #
        # Same category for both kinds because they share one disposition
        # (reach an operator), while keeping distinct kinds and fingerprints so
        # "cannot be shown to be armed" and "armed but aged" stay separable.
        #
        # DO NOT collapse to system.observation — the fleet seed maps that to
        # auto_approve, which files the signal for dashboards and reaches NO
        # operator, which is the entire point of this lane. Listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES for the
        # standing-fingerprint reason recorded there.
        "system.node_lkg_unarmed" => {
          skill: nil,
          action_category: "system.node_lkg_investigate"
        },
        "system.node_lkg_stale" => {
          skill: nil,
          action_category: "system.node_lkg_investigate"
        },
        "system.sdwan_vip_unreachable" => {
          skill: ::System::Ai::Skills::SdwanVipFailoverExecutor,
          action_category: "system.sdwan_vip_failover",
          side_effectful: true, # promotes a failover holder
          dry_run_supported: true,
          input_mapper: ->(signal) { { virtual_ip_id: signal.dig(:payload, "virtual_ip_id") } }
        },
        # M2 of the AI-driven provisioning conversation — adaptive evolution.
        # Skills are intentionally `nil` because adaptation is multi-step: the
        # remediation is not an on-node task but a diff PLAN, composed by
        # AdaptationProposerService (in the parent platform) out of one or more
        # provisioning_skill steps.
        #
        # IMP-4f7f7a0c9d33: this comment previously said the pending approval's
        # payload "triggers AdaptationProposerService". Nothing read that
        # payload — the proposer had zero production call sites and the lane
        # dead-ended at the gate. The proposer is invoked by the
        # #propose_project_adaptation entry in REMEDIATION_APPLIERS, on the
        # proceed lane, like every other actuated binding.
        #
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
        # Audit F3-07 registered this kind; IMP-df40782d3f4d rebound it.
        # An expiring MembershipCredential means the agent is NOT pulling
        # (TopologyCompiler's ensure_fresh! refreshes the MC on every
        # compile), so the credential is the thing to refresh — server-side
        # via the constellation signer, ready for the agent's next pull.
        # The previous binding rotated the WireGuard keypair
        # (SdwanPeerRemediateExecutor under system.sdwan_key_rotate,
        # auto_approve): that does nothing for the MC but REVOKES the
        # active key, so hubs drop the old pubkey on their next compile and
        # the still-connected, not-yet-polling peer loses a WORKING tunnel.
        # Key rotation stays bound to the drift signal
        # (system.sdwan_peer_drift above).
        "system.sdwan_credential_expiring" => {
          skill: ::System::Ai::Skills::SdwanCredentialRefreshExecutor,
          action_category: "system.sdwan_credential_refresh",
          side_effectful: true, # issues + supersedes a membership credential
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
        #
        # IMP-43e94c9d46d4: auto_approve with no applier meant every drifted
        # link proceeded and re-synced NOTHING. #sync_package_repository is
        # the applier; it goes through PackageRepositorySyncService.enqueue!,
        # never .call — a full sync is a minutes-long, memory-heavy job and
        # that service's own doc requires every non-worker entry point to
        # enqueue.
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
        # GitOps drift (GitopsDriftSensor) → notify_and_proceed in the fleet
        # seed. No skill: the reconciler (System::Gitops::Reconciler, driven by
        # SystemGitopsSyncJob) is what diffs desired vs live and opens the
        # proposals, so there is nothing for an executor to plan.
        #
        # IMP-43e94c9d46d4: this comment used to end "and no REMEDIATION_APPLIER
        # entry ... the DecisionEngine's role here is purely to surface the
        # drift". That made the lane a silent no-op the validator still scored.
        # #apply_gitops_drift is the applier, and it is deliberately NARROW —
        # it applies only proposals an operator ALREADY APPROVED and nothing
        # implemented (Ai::AgentProposal#approve! sets status and stops; only
        # the gitops_apply_proposal MCP tool ever ran ApplyService on that
        # path). It never approves a pending_review proposal: that would
        # autonomously bypass both the operator gate and the reconciler's
        # destroy guard.
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
        # which must pass the R1/R2/R3 reuse gate
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
        # NOT imply advisory. The example this comment used to give was false:
        # it offered cert_expiring and slo_violation as skill-less lanes that
        # actuated through some service elsewhere. Both actuated NOTHING
        # anywhere (IMP-43e94c9d46d4; cert_expiring now has an applier and
        # slo_violation is declared dormant in
        # RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS). The rule stands
        # on its own terms: advisory changes CONSENT-BUDGET and dedup
        # semantics, which is an orthogonal question to whether a lane
        # actuates, so deriving one from the other would silently retune the
        # consent ceiling of every applier-less kind.
        #
        # This kind is ALSO declared in NON_REMEDIATING_SIGNAL_KINDS. It is
        # require_approval today, so record_proceeded! never sees it — but the
        # policy row is operator-tunable, and a retune to notify_and_proceed
        # would otherwise start scoring a gap that only clears when a human
        # ships a module. The declaration is what makes the exemption survive
        # that retune instead of depending on DB state.
        "system.capability_gap" => {
          skill: nil,
          action_category: "system.capability_gap_review",
          advisory: true
        }
      }.freeze

      # Every action_category THIS ROUTER routes a signal to — its
      # ActionCategoryRouter declaration.
      #
      # This is the set that MUST have an Ai::InterventionPolicy row on the
      # agent running the sense pass. Without a row, FleetAutonomyService
      # #gate_action! takes its `not_permitted` arm and blocks the signal —
      # and `permitted_actions` is literally the policy-row set, so "not
      # permitted" and "nobody ever seeded this" are the same state.
      #
      # Exposed so the gate can tell a MISCONFIGURED lane (routed by code,
      # unseeded in this database) from an arbitrary unknown category, and so
      # a spec can assert every routed lane is actually seeded. NOT the whole
      # routed set — the gate reads ActionCategoryRouter's union, because
      # System::AdaptationGate routes four `project.*` categories that appear
      # in no signal binding.
      def self.routed_action_categories
        SIGNAL_BINDINGS.values.filter_map { |b| b[:action_category] }.uniq.freeze
      end


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
        # decides. ApprovalRequest dedup keeps this to one open approval, and
        # (IMP-01a025b3) that open row is what gives the lane a terminal state:
        # while it stands, escalate_stuck_remediation! goes quiet instead of
        # re-emitting and re-gating.
        streak = ineffective_streak(signal)
        if streak >= STUCK_STREAK_THRESHOLD
          decision = escalate_stuck_remediation!(signal, binding, streak)
          ::System::Fleet::EventBroadcaster.emit_decision!(account: account, decision: decision, signal: signal)
          return decision
        end

        # IMP-848c7e953e2d — the deferred lane's brake, into the SAME escalation.
        #
        # A remediation that DECLARED it could not converge (convergence_deferred)
        # settles `inconclusive`, which is held out of the streak on purpose:
        # neither the fingerprint's absence nor its presence is evidence about an
        # action that dispatched nothing. But holding it out ALSO removes the only
        # thing that ever told an operator — the file this reads from says so in
        # its own words (RemediationValidator's :proposal exemption, "this pins
        # ineffective_streak at 0 ... which disables F3-11 as the lane's brake"),
        # and that exemption names its replacement. This is ours.
        #
        # It is the SAME lane, not a second one: the HIGH fleet.remediation_stuck
        # event, the forced require_approval, the consent-budget skip, and the
        # open_operator_request? terminal state all carry over unchanged. Routing
        # here also stops the row churn, because the escalated decision is not
        # :proceed, so record_proceeded! mints nothing further.
        #
        # THAT LAST PROPERTY IS ALSO THE DANGER, and it is why the predicate is
        # time-bounded rather than a plain "has a deferred outcome" read. No
        # :proceed means no new outcome row, so nothing this lane does can ever
        # lift its own block — unlike the streak, which keeps proceeding below
        # the threshold and so can be reset by an `effective` row. And the
        # fingerprint is per-instance (`module_drift:<instance_id>`), not
        # per-drift, so an unbounded block would take that instance out of
        # autonomous remediation for every FUTURE drift too, including ordinary
        # ones a live sync would fix. RemediationOutcome::DEFERRED_BLOCK_WINDOW
        # bounds it; the constant carries the reasoning.
        #
        # ONE DEDUP CYCLE LATE, deliberately: the deferral is discovered AFTER the
        # gate (inside apply_remediation!), so it cannot re-gate in its own tick.
        # The outcome settles on a later tick and this fires on the next decide —
        # still sooner than the streak's three windows, and through machinery that
        # is already proven rather than a second escalation path.
        if deferred_convergence?(signal)
          decision = escalate_stuck_remediation!(signal, binding, 0, deferred: true)
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

      # Reconstruct the signal an approved request was minted for, from the
      # identity DecisionEngine#skill_metadata_payload stamped into
      # request_data["payload"]. Returns nil for a pre-F3-01 request that
      # carries no signal_kind and therefore cannot be replayed at all.
      #
      # Pure and deterministic — two callers reconstruct it independently
      # (execute_approved! to replay the action, FleetAutonomyService to score
      # the execution) rather than threading a Signal object through the
      # execution RESULT, which stamp_execution! serializes into request_data.
      #
      # NOTE the fingerprint fallback. `signal_fingerprint` is the sensor's own
      # per-resource key and is what a later sense pass re-emits; the
      # "approved:<id>" substitute exists only so a pre-fingerprint request can
      # still be replayed and logged. It matches NO sense pass, so nothing that
      # SCORES by fingerprint disappearance may key on it — see
      # FleetAutonomyService#record_approved_outcome!, which reads the stamped
      # value directly and mints nothing when it is absent.
      def signal_from_approval(request)
        data = request.request_data.is_a?(Hash) ? request.request_data : {}
        payload = data["payload"].is_a?(Hash) ? data["payload"] : {}
        kind = payload["signal_kind"]
        return nil if kind.blank?

        ::System::Fleet::Signal.from_hash(
          "kind" => kind,
          "severity" => payload["signal_severity"].presence || "medium",
          "payload" => payload.except("signal_kind", "signal_severity", "signal_fingerprint", "skill_plan"),
          "fingerprint" => payload["signal_fingerprint"].presence || "approved:#{request.id}"
        )
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
        signal = signal_from_approval(request)
        unless signal
          return { applied: false,
                   reason: "request_data missing signal_kind — pre-F3-01 request, cannot replay" }
        end

        binding = SIGNAL_BINDINGS[signal.kind]
        skill_result = nil
        if binding && binding[:skill] && binding[:side_effectful]
          inputs = binding.fetch(:input_mapper).call(signal)
          if inputs
            executor = binding[:skill].new(account: account, agent: autonomy_service.agent, user: nil)
            # gated: true — the human approval this method is replaying IS the
            # policy decision. BaseSkillExecutor gates on `requires_approval`
            # itself now (IMP-7e2bdc1774e4), and without the opt-out a
            # side-effectful skill would park a SECOND approval for the request
            # an operator just released.
            skill_result = executor.execute(gated: true, **inputs)
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

      # IMP-848c7e953e2d — same shape and same failure policy as the streak read
      # above: never let the bookkeeping query block a decision. False on error
      # means the tick behaves as it did before this lane existed.
      def deferred_convergence?(signal)
        ::System::Fleet::RemediationOutcome.deferred_convergence?(
          account: account, fingerprint: signal.fingerprint
        )
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] deferred-convergence read failed: #{e.message}")
        false
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
      def escalate_stuck_remediation!(signal, binding, streak, deferred: false)
        metadata = skill_metadata_payload(signal, nil).merge("remediation_stuck_streak" => streak)
        metadata = metadata.merge("convergence_deferred" => true) if deferred

        # IMP-01a025b3: the escalation has a TERMINAL STATE. Without one it had
        # none: this lane skips both the skill and the remediation, and
        # RemediationValidator only scores decisions that PROCEEDED, so no fresh
        # outcome is ever recorded for the fingerprint and the streak stays
        # pinned at the threshold forever. The trio below (HIGH event + forced
        # require_approval + decision.pending) therefore re-fired every dedup
        # TTL for as long as the condition stood. ApprovalRequest dedup already
        # collapsed those to ONE open row — nothing READ that row before
        # re-escalating.
        #
        # Skipping gate_action! is the load-bearing half, not the event
        # suppression: every non-advisory gate call consumes the target
        # module's daily consent budget (ConsentBudgetService#check_and_consume!
        # increments atomically per call), and this binding's metadata carries
        # the REAL module_id — so the noise drained LIVE modules' budgets and
        # pushed their genuine remediations down the budget-exhausted branch.
        #
        # The read is DB-backed on purpose (see #open_operator_request? for the
        # definition of "open" and what resolve/reject/expire do): cross-process
        # and restart-safe, where Rails.cache — memory_store on the hub — is
        # neither. The engine's own cache dedup stays an optimization in front
        # of it.
        #
        # The terminal state is per OPERATOR OBLIGATION, not per fingerprint,
        # because the obligation itself is: the gate's dedup key is coarser than
        # a fingerprint for module/template-keyed actions (config_drift's
        # fingerprint is per-assignment while its dedup key is module_id), so N
        # stuck assignments on one module share ONE ApprovalRequest and, now,
        # one escalation. That is a deliberate trade — the escalation announces
        # a request the operator does not yet have, and here they already have
        # it — but it does cost the per-node HIGH events that used to fan out.
        # The per-assignment detail is still emitted: emit_signal! above is
        # untouched, and each fingerprint still records its own
        # decision.awaiting_operator carrying its own correlation_id.
        if autonomy_service.open_operator_request?(binding[:action_category], metadata: metadata)
          record_decision!(signal)
          return {
            decision: :awaiting_operator,
            gate: "remediation_stuck",
            reason: "operator request already open for #{signal.fingerprint} — escalation already delivered",
            signal_kind: signal.kind,
            fingerprint: signal.fingerprint,
            action_category: binding[:action_category],
            remediation_stuck: true,
            ineffective_streak: streak,
            convergence_deferred: deferred
          }
        end

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "fleet.remediation_stuck",
          severity: :high,
          payload: {
            "fingerprint" => signal.fingerprint,
            "signal_kind" => signal.kind,
            "action_category" => binding[:action_category],
            "ineffective_streak" => streak,
            "threshold" => STUCK_STREAK_THRESHOLD,
            # IMP-848c7e953e2d — WHY this fingerprint is stuck. The deferred lane
            # reaches here with streak 0, so without this an operator reading the
            # event would see "0 consecutive ineffective outcomes" and no cause.
            "convergence_deferred" => deferred
          }.merge(signal.payload.is_a?(Hash) ? signal.payload.slice("instance_id", "node_id") : {}),
          source: "decision_engine.stuck_escalation",
          correlation_id: signal.fingerprint
        )

        gate_result = autonomy_service.gate_action!(
          binding[:action_category],
          metadata: metadata,
          reasoning: {
            summary: if deferred
                       "Remediation stuck: #{signal.kind} (#{signal.fingerprint}) — the last " \
                       "remediation declared it could not converge until this node reboots; " \
                       "re-running it is futile, so an operator decision is required"
                     else
                       "Remediation stuck: #{signal.kind} (#{signal.fingerprint}) — " \
                       "#{streak} consecutive ineffective outcomes; operator decision required"
                     end
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
          ineffective_streak: streak,
          convergence_deferred: deferred
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
        # The F3-06 resolution above IS this invocation's policy decision, taken
        # against the SIGNAL's action_category. BaseSkillExecutor gates on
        # `requires_approval` itself now (IMP-7e2bdc1774e4); letting it
        # re-evaluate here would resolve a DIFFERENT category (the skill's) and
        # park an approval on top of the verdict the engine already acted on.
        #
        # Passed as the SAME predicate the resolution is guarded on, not a bare
        # `true`: the F3-06 block runs only for a side-effectful binding, so on a
        # non-side-effectful one no policy has been resolved and there is nothing
        # to stand the executor's own gate down for. No such binding names a
        # gated executor today, which is exactly why an unconditional `true`
        # would sit here undetected until one did.
        executor.execute(gated: binding.fetch(:side_effectful), **inputs)
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
        # is skipped and the result DECLARES convergence_deferred, which
        # RemediationValidator settles as `inconclusive` rather than scoring
        # it — see #apply_template_closure_drift.
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
        "system.module_promotion_ready" => { method: :apply_module_promotion },
        # IMP-4f7f7a0c9d33: the project.* adaptation lane (M2 adaptive
        # evolution). ProjectSloSensor emitted these, SIGNAL_BINDINGS gated
        # them through project.adapt / project.cost_control, and there the lane
        # STOPPED — no entry here, and AdaptationProposerService#propose_from_signals
        # had zero production call sites (only its own specs and the M2 smoke,
        # which drives the proposer directly and so never exercised this path).
        # A proceed therefore minted a RemediationOutcome no actuation could
        # ever settle, which the F3-11 streak later mis-read as a stuck
        # remediation. Same class as the three IMPs above.
        #
        # DEPARTURE from the other appliers, and the only one: a project.*
        # remediation is a PROPOSAL, not a mutation. Its actions (rescale,
        # relocate, re-shape storage/SDWAN) are destructive and multi-step, so
        # the applier composes a diff plan + approval request and stops. The
        # result carries proposal: true so nothing downstream mistakes a minted
        # plan for a converged workload. Same intent as the convergence_deferred
        # flag on apply_template_closure_drift, and both are declared by the
        # applier and read by RemediationValidator#record_proceeded! — but a
        # DIFFERENT mechanism, and the difference matters: :proposal SKIPS the
        # outcome row entirely, while convergence_deferred MINTS one that later
        # settles `inconclusive`. The proposal lane has nothing to settle; the
        # deferred lane does, and that row is the evidence an operator reads.
        "system.project_slo_violation" => { method: :propose_project_adaptation },
        "system.project_drift" => { method: :propose_project_adaptation },
        "system.project_cost_breach" => { method: :propose_project_adaptation },
        # IMP-43e94c9d46d4 (APO-1d). Three routed lanes that actuated NOTHING
        # and were not exempt. Same class as IMP-555e29eeb4ab /
        # IMP-83471cc28e1a / IMP-41eb6ddbc490 above, but BE PRECISE about the
        # blast radius, because it differs per lane and the earlier draft of
        # this comment overstated it:
        #
        #   - system.package_drift_pressure (auto_approve) and
        #     system.gitops.drift_detected (notify_and_proceed) reached the
        #     PROCEED arm, so RemediationValidator#record_proceeded! minted a
        #     pending outcome for work no code attempted, and three ineffective
        #     settle windows fired a HIGH fleet.remediation_stuck.
        #   - system.cert_expiring routes to system.cert_rotate, seeded
        #     require_approval, so it never reached the proceed arm and
        #     FleetAutonomyService#executed_remediation? already dropped its
        #     applied:false on the approved arm. No false outcome, no false
        #     escalation — the defect there was that an operator APPROVED a
        #     rotation and nothing ran, while the binding comment named a
        #     `rotate` method on NodeCertificate that has never existed.
        "system.cert_expiring" => { method: :rotate_node_certificate },
        "system.gitops.drift_detected" => { method: :apply_gitops_drift },
        "system.package_drift_pressure" => { method: :sync_package_repository }
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

      # IMP-43e94c9d46d4 — the system.cert_expiring applier.
      #
      # WHAT THE PLATFORM CAN AND CANNOT DO HERE, because the binding used to
      # claim more than either half. A NodeCertificate's private key is
      # generated ON THE NODE and never leaves it; InternalCaService only SIGNS
      # a CSR the agent presents (NodeEnrollmentService#refresh!, POST
      # node_api/enroll/refresh, driven by the agent's CertRotator). There is
      # therefore no server-side re-issue — the platform cannot mint a
      # certificate the node could actually use, and the rotate method the old
      # binding comment named on NodeCertificate has never existed.
      #
      # What the platform CAN close is the loop the agent's own rotator leaves
      # open. #refresh! deliberately leaves the superseded NodeCertificate row
      # in place, and nothing revoked it: NodeCertificate#revoke! had ZERO
      # application call sites, so CertificateExpirySensor kept firing on a row
      # the node stopped using the moment it rotated. When a NEWER active cert
      # exists for the same instance, the expiring one is spent — revoke it
      # (CA first, then the row) and the fingerprint clears for the right
      # reason.
      #
      # When no successor exists the cert IS the instance's live identity and
      # the rotator has not run. Nothing on this side can actuate that, so this
      # returns applied:false and says why; record_proceeded! then mints
      # nothing instead of scoring a no-op into the LEARN step's ground truth.
      def rotate_node_certificate(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        cert = ::System::NodeCertificate
                 .joins(node_instance: :node)
                 .where(system_nodes: { account_id: account.id })
                 .find_by(id: payload["certificate_id"])
        return { applied: false, reason: "certificate not found" } unless cert
        return { applied: false, reason: "certificate already revoked" } if cert.revoked?

        successor = ::System::NodeCertificate
                      .active
                      .where(node_instance_id: cert.node_instance_id)
                      .where.not(id: cert.id)
                      .where("not_after > ?", cert.not_after)
                      .order(not_after: :desc)
                      .first
        unless successor
          return { applied: false,
                   reason: "cannot rotate server-side: the private key lives on the node, so only " \
                           "the agent can present a CSR (node_api/enroll/refresh); this instance " \
                           "has no newer certificate to supersede this one" }
        end

        revoke_at_ca(cert)
        cert.revoke!(reason: "superseded by #{successor.serial}")
        { applied: true, revoked_serial: cert.serial, superseded_by: successor.serial }
      end

      # Best-effort CA-side revocation. The ROW revocation is the load-bearing
      # half — it is what CertificateExpirySensor and every model reader
      # consult — so a sealed or unreachable Vault PKI must not leave the spent
      # row un-revoked and the signal standing forever.
      def revoke_at_ca(cert)
        ::System::InternalCaService.revoke_certificate(serial: cert.serial)
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] CA revocation failed for serial=#{cert.serial}: " \
                          "#{e.class}: #{e.message}")
        nil
      end

      # Applied per tick, so one drifted repository cannot turn an autonomy
      # tick into an unbounded apply loop. Mirrors the Reconciler's own
      # MAX_PROPOSALS_PER_TICK cap on the authoring side.
      GITOPS_APPLY_LIMIT = 10

      # IMP-43e94c9d46d4 — the system.gitops.drift_detected applier.
      #
      # NARROW BY CONSTRUCTION. It applies ONLY proposals an operator already
      # approved and that nothing implemented. That gap is real:
      # Ai::AgentProposal#approve! just sets status/reviewed_by and returns,
      # and the only other caller of Gitops::ApplyService on the approved path
      # is the gitops_apply_proposal MCP tool, so an operator approving a
      # GitOps proposal in /app/approvals left it approved-and-unapplied while
      # the drift kept firing.
      #
      # It must NEVER approve a pending_review proposal. The Reconciler's
      # auto-apply lane is the only thing allowed to act without a human, and
      # it carries two gates this lane has no business re-deriving: the
      # repository's own `auto_apply` opt-in, and the destroy guard
      # (auto_appliable_diff? admits create/update only).
      #
      # WHICH IS WHY status:"approved" ALONE IS NOT THE FILTER. Reconciler
      # #auto_apply_proposal MACHINE-approves — status "approved" with
      # reviewed_by nil and impact_assessment["approved_by"] =
      # "gitops_auto_apply" — and reverts to pending_review on apply failure
      # inside a rescue, so a failed revert leaves an approved-looking row a
      # status-only query would then re-apply unattended, outside both of
      # those gates. reviewed_by_id is the discriminator: Ai::AgentProposal
      # #approve! sets it to the approving user and the machine path
      # explicitly nils it, so "a human decided this" is READ, never inferred.
      def apply_gitops_drift(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        repo = ::System::GitopsRepository
                 .where(account_id: account.id)
                 .find_by(id: payload["repository_id"])
        return { applied: false, reason: "gitops repository not found" } unless repo

        proposals = ::Ai::AgentProposal
                      .where(account_id: account.id, status: "approved")
                      .where.not(reviewed_by_id: nil)
                      .where("proposed_changes->>'source' = ?", "gitops")
                      .where("proposed_changes->>'repository_id' = ?", repo.id.to_s)
                      .order(created_at: :asc)
                      .limit(GITOPS_APPLY_LIMIT)
                      .to_a
        if proposals.empty?
          return { applied: false,
                   reason: "no human-reviewed approved gitops proposal for repository #{repo.id} — " \
                           "the drift stands until a person reviews it" }
        end

        applied_ids = []
        failures = []
        proposals.each do |proposal|
          result = ::System::Gitops::ApplyService.apply!(proposal: proposal)
          if result.ok?
            applied_ids << proposal.id
          else
            failures << "#{proposal.id}: #{result.error}"
          end
        end

        if applied_ids.empty?
          return { applied: false, reason: "gitops apply failed — #{failures.join('; ')}" }
        end

        { applied: true, applied_proposal_ids: applied_ids,
          failed_proposals: failures.presence }.compact
      end

      # IMP-43e94c9d46d4 — the system.package_drift_pressure applier.
      #
      # ENQUEUE, NEVER .call. PackageRepositorySyncService's own contract says
      # every operator/API/MCP/agent entry point must use #enqueue!: a full
      # sync is a minutes-long, memory-heavy job whose inline form inflates RSS
      # past the puma worker recycler. This runs inside the autonomy tick, so
      # it is exactly the caller that rule is written for.
      #
      # `accessible_to` rather than a bare account scope: a drifted link can
      # point at a SHARED repository (account_id NULL), which an account-only
      # lookup would report as "not found" forever.
      #
      # SAY THE CONSEQUENCE OUT LOUD: on a shared repository that means ONE
      # account's autonomy tick enqueues a sync every account then reads, and
      # mutates a row (sync_status/last_sync_error) they all see. That is
      # intended — the drift it clears is equally fleet-wide, and a shared
      # repo nobody may sync is a repo that stays drifted forever — but it is
      # a cross-tenant side effect, so it is bounded rather than left open:
      # the `syncing` guard below makes concurrent ticks idempotent (the
      # second is a no-op, not a second job), and enqueue! is a metadata
      # refresh, never a mutation of any account's own resources.
      #
      # The `syncing` guard has a KNOWN edge, stated rather than papered over:
      # a wedged sync leaves the row `syncing`, so this returns applied:false
      # forever — and since IMP-43e94c9d46d4 record_proceeded! refuses
      # applied:false, nothing mints and nothing escalates. A wedged sync is
      # already the PackageRepositorySyncService's own alarm to raise
      # (last_sync_error / sync_status are operator-visible); inventing a
      # second escalation here would score a lane that correctly declined.
      def sync_package_repository(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        repo = ::System::PackageRepository
                 .accessible_to(account)
                 .find_by(id: payload["package_repository_id"])
        return { applied: false, reason: "package repository not found" } unless repo
        return { applied: false, reason: "package repository #{repo.id} is disabled" } unless repo.enabled?

        if repo.sync_status.to_s == "syncing"
          return { applied: false, reason: "package repository sync already in flight" }
        end

        ::System::PackageRepositorySyncService.enqueue!(repository: repo)
        { applied: true, package_repository_id: repo.id, sync: "enqueued" }
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

      # IMP-4f7f7a0c9d33 — the project.* adaptation applier, shared by all three
      # bound kinds (the proposer branches on signal.kind itself via its
      # CHANGE_TYPES map, so one method serves the whole lane).
      #
      # Reuses AdaptationProposerService rather than reimplementing diff
      # composition: it builds the diff-shaped Ai::GoalPlan of
      # provisioning_skill steps and STOPS. It does no approval routing of its
      # own — an earlier version of this comment claimed it routed through
      # Ai::Autonomy::ApprovalWorkflowService as `project.adapt_<change_type>`,
      # a category that has never existed. Gating belongs to
      # AdaptationDispatchService via the `adaptation_gate` seam, which resolves
      # a real `project.<change_type>` InterventionPolicy category. This wiring
      # deliberately does NOT revive the deleted AiProvisioningHandoffJob /
      # handoff RalphLoop machinery.
      #
      # Unlike the mutating appliers this returns proposal: true — the plan is
      # composed here and applied by AdaptationDispatchService, which this
      # applier calls below. Composing without dispatching would leave the lane
      # dead-ended in a persisted record, exactly where it was before it was
      # wired.
      #
      # EVERY return from this lane carries proposal: true. That flag is what
      # RemediationValidator#record_proceeded! reads to keep these decisions out
      # of the validate arc, and it has to hold on the DECLINE paths too — a
      # decline leaves the breach firing, so a pending outcome recorded for it
      # would score ineffective and rebuild the false fleet.remediation_stuck
      # this lane exists to remove. The RemediationOutcome for this lane is
      # minted by the dispatch service at SETTLE time (post-verification), never
      # at decide time, so decide-time recording would double-count as well.
      #
      # The cost, stated: a lane that can never compose stops escalating to an
      # operator. The decline stays visible in the decision event and in the
      # proposer's throttled decline log.
      def propose_project_adaptation(signal, _skill_result)
        payload = signal.payload.is_a?(Hash) ? signal.payload : {}
        mission_id = payload["mission_id"] || payload[:mission_id]
        mission = ::Ai::Mission.where(account_id: account.id).find_by(id: mission_id)
        return adaptation_declined("mission not found: #{mission_id.inspect}") unless mission

        # The gate's approval TTL outlives a mission — it can finish between the
        # sensor firing and this proceed. Adapting a finished mission would mint
        # a plan against infrastructure that is no longer being managed, so
        # re-check the LIVE status (mirrors apply_module_promotion's staging
        # re-check).
        if ::Ai::Mission::TERMINAL_STATUSES.include?(mission.status)
          return adaptation_declined(
            "mission is #{mission.status} — no adaptation for a terminal mission",
            mission_id: mission.id
          )
        end

        # IDEMPOTENCY — one OPEN proposal per mission. This is the lane's only
        # brake, and it carries two jobs at once:
        #
        #   1. Bounds the churn. Once RemediationValidator stops scoring proposals
        #      (see below), ineffective_streak is pinned at 0, so F3-11's
        #      escalate_stuck_remediation! — previously the only thing that capped
        #      this lane at ~3 plans — can never fire. Nothing else stops the
        #      repeat: recently_decided? is just a 600s TTL, and the consent budget
        #      no-ops because ConsentBudgetService#check_and_consume! allows a blank
        #      module_id, which every project.* payload has. Without this guard a
        #      single standing breach mints a GoalPlan version (plus, where
        #      governance is enabled, a pending ApprovalRequest) every dedup TTL —
        #      ~144/day, indefinitely.
        #   2. Prevents contradictory diffs in one tick. ProjectSloSensor emits up
        #      to three signals per mission per tick, and they map to DIFFERENT
        #      change_types (slo_violation/drift → scale_horizontal, cost_breach →
        #      cost_control), so the second signal composes "scale to initial-1"
        #      against the first's "scale to initial+2" on the same AgentGoal.
        #      Keying on the mission ALONE — not (mission, change_type) — is what
        #      closes this; a change_type-scoped key would let exactly that pair
        #      through, since their change_types differ.
        #
        # Same shape as the reconcile lanes' in-flight task check: an unsettled
        # proposal IS this mission's outstanding remediation.
        if (in_flight = in_flight_adaptation_plan(mission))
          return continue_adaptation(mission, in_flight, signal)
        end

        plan = ::Ai::Provisioning::AdaptationProposerService
                 .new(account: account, mission: mission)
                 .propose_from_signals(signals: [ signal ])
        unless plan
          # Not a failure of the lane. The composer declines by design whenever
          # it cannot bind a step to its executor's contract — relocate needs
          # inputs no heuristic supplies (offer 019ff49b-a8e5). Declining beats
          # composing a step that fails at execution. (cost_control used to
          # reach here too; IMP-e68a93c47106 wired its scale-IN composer, so it
          # no longer does.)
          return adaptation_declined("no diff plan composed for #{signal.kind}", mission_id: mission.id)
        end

        dispatch_adaptation!(mission, plan)
      rescue StandardError => e
        # apply_remediation!'s own rescue would return a hash WITHOUT the
        # proposal flag, putting this lane back in the validate arc on exactly
        # the paths least able to clear their signal. Keep the contract here.
        Rails.logger.error("[FleetDecisionEngine] adaptation lane failed: #{e.class}: #{e.message}")
        adaptation_declined("adaptation lane error: #{e.class}")
      end

      def adaptation_declined(reason, mission_id: nil)
        { applied: false, proposal: true, mission_id: mission_id, reason: reason }.compact
      end

      # INC-2's consumer (IMP-8c37b9e5ccd5). Composing is only half the lane:
      # dispatch! takes the diff plan through the `adaptation_gate` seam and, when
      # operator policy or an approval clears it, appends the steps onto the
      # mission's LIVE plan and runs them. It is idempotent and re-callable, so a
      # plan routed on this tick dispatches on a later one without minting a
      # second request.
      #
      # Leaving `draft` is also what RELEASES open_adaptation_plan above — the
      # brake and its release are the two halves of one mechanism, which is why
      # this lane could not land before the consumer existed.
      def dispatch_adaptation!(mission, plan)
        dispatcher = ::Ai::Provisioning::AdaptationDispatchService
        result = dispatcher.new(account: account, mission: mission).dispatch!(plan: plan)

        gate = result[:gate].to_s
        request_id = result[:approval_request_id].presence

        # Dispositions under which the lane did its job: the adaptation is
        # running, already applied, or genuinely held for an operator. The two
        # omitted ones — parked_gate_unavailable and applied_dispatch_failed —
        # mean nothing is progressing.
        progressing = [ dispatcher::GATE_ROUTED, dispatcher::GATE_AUTO_APPLY,
                        dispatcher::GATE_ALREADY_APPLIED ].include?(gate)

        # ROUTED normally means "a gate holds this plan", but AdaptationGate's
        # :blocked arm returns ROUTED with NO request minted — it fires whenever
        # the resolved project.<change_type> category has no permitting policy.
        # The SIGNAL binding gates on the coarse project.adapt, so an account
        # holding a project.adapt policy but none for project.scale_horizontal
        # takes that arm on every SLO breach. Calling that applied would be the
        # worst shape available: the plan wedges in draft, NOTHING exists for an
        # operator to see, and the validate-arc exemption pins ineffective_streak
        # at 0 so F3-11 cannot escalate it either — a silent failure with its own
        # alarm switched off. Held is only progress when something was minted to
        # hold it.
        held_with_nothing_to_act_on = gate == dispatcher::GATE_ROUTED && request_id.nil?

        # The gate may have CLOSED this plan during the call — a rejected or
        # expired approval is terminal, and AdaptationGate reflects that onto the
        # plan so the brake releases. Core's disposition vocabulary has no word
        # for it (it still reports ROUTED with the request id), so read the plan.
        # Without this, a REJECTED adaptation reported applied: true.
        closed = TERMINAL_PLAN_STATUSES.include?(plan.reload.status.to_s)
        applied = progressing && !held_with_nothing_to_act_on && !closed

        # The gate DECLARES why it minted nothing (IMP-fec9abb225c6). Reading it
        # is the whole difference between "your fleet has no policy for this"
        # and "you declined this ten minutes ago".
        if held_with_nothing_to_act_on
          escalate_blocked_adaptation!(mission, plan, result[:detail], result[:cause])
        end

        {
          applied: applied,
          proposal: true,
          mission_id: mission.id,
          plan_id: plan.id,
          step_count: plan.steps.count,
          gate: gate,
          dispatched: result[:dispatched] == true,
          approval_request_id: request_id,
          # The gate's own words are the only statement of WHY nothing moved.
          # Dropping them made a policy-blocked plan indistinguishable from an
          # approved one in the decision event.
          reason: (result[:detail].presence unless applied)
        }.compact
      end

      # An in-flight plan is not a reason to do nothing.
      #
      # A ROUTED plan stays `draft` until something asks the gate AGAIN —
      # AdaptationGate#from_existing answers from the standing request, so the
      # tick after an operator approves is when it dispatches. Returning early
      # here meant an approved adaptation sat in draft forever: the replay
      # through execute_approved! deduped, stamp_execution! then stopped the
      # poller retrying, and every later tick deduped too. Nothing else in the
      # system ever calls dispatch! for this plan. It is documented idempotent
      # and re-callable precisely so this retry is safe.
      #
      # An already-dispatched plan is left alone. Re-entering dispatch! would
      # take its RESUME path, which has an open defect (offer 019ff55e-84b1) in
      # how it resolves dependencies across a partial step set — and there is
      # nothing to gain, because the runner already owns the work.
      # EVERY in-flight plan is re-offered to dispatch!, including `executing`.
      #
      # `executing` is not "safely under way": #dispatch_appended! calls
      # start_execution! BEFORE execute_appended!, so a raised dispatch leaves
      # the plan executing with steps appended, unenqueued and unstamped —
      # precisely the state the consumer's #resumable_steps exists to recover,
      # and this lane is the only production caller that could reach it. Holding
      # those plans back left recovery to a manual operator MCP call.
      #
      # dispatch! is idempotent: an already-running adaptation comes back
      # ALREADY_APPLIED rather than being re-enqueued.
      #
      # KNOWN EXPOSURE, stated rather than argued away. Re-offering an executing
      # plan opens a window: step 1 completes and, before its worker enqueues
      # step 2, a fleet tick resumes the plan — two jobs racing
      # SkillCompositionRunner#execute_step!, whose in-flight guard is an
      # unlocked mark_executing → update! (instance 3 of the deferred concurrency
      # offer 019ff533-8638). Once that single mechanism lands — a partial unique
      # index or a compare-and-set claim — this degrades to a duplicate enqueue
      # where one worker wins, which is the correct behaviour. Until then
      # 019ff533-8638 is a PREREQUISITE for exercising this lane, not optional
      # hardening. Restoring the old early return is not the fix: it reinstates
      # the stranding defect (appended, unenqueued, unrecoverable) this replaced.
      #
      # An earlier version of this comment claimed the multi-step case was
      # unreachable "because this lane composes single-step diffs". That was
      # false: in_flight_adaptation_plan matches ANY adaptation_diff plan for the
      # mission, including operator/MCP-composed ones; only scale_horizontal and
      # cost_control take the single-step heuristic path, while relocate /
      # schema_change / security_change go through the LLM path, which has no
      # step cap, and persist_diff_plan! chains their dependencies. Chained
      # adaptations reach the resume path's ordering defect (019ff55e-84b1).
      def continue_adaptation(mission, plan, signal)
        result = dispatch_adaptation!(mission, plan)
        return result unless plan_change_type(plan) && different_condition?(plan, signal)

        # Finding 5: a SECOND, unrelated breach absorbed by this plan must not be
        # reported as though the plan addressed it. A cost breach folded into an
        # outstanding scale-out gets the scale-out's ids, so say whose plan it is.
        #
        # IMP-fec9abb225c6 (4) — the fold note rides its OWN key.
        #
        # It used to be merged over `reason`, unconditionally. But `reason` is
        # dispatch_adaptation!'s only statement of why nothing moved, and it is
        # emitted precisely when applied is false — so the clobber destroyed the
        # explanation in exactly the cases that have one. A cost breach folded
        # into a policy-BLOCKED scale-out reported applied: false with reason
        # "folded into the in-flight proposal", which is indistinguishable from
        # the healthy fold into a plan that IS progressing, and re-introduces the
        # ambiguity dispatch_adaptation! documents as a past bug.
        #
        # Both facts are true at once and both are worth reporting: the signal
        # WAS folded, and the plan it folded into is going nowhere.
        folded = result.merge(
          superseded_by_change_type: plan_change_type(plan),
          folded_signal_kind: signal.kind.to_s,
          folded_into: fold_note(signal, plan)
        )

        # When the plan IS progressing there is no reason key to protect (the
        # hash is compacted), so the fold note becomes the reason — the original
        # intent, kept.
        return folded if folded[:reason].present?

        folded.merge(reason: fold_note(signal, plan))
      end

      def fold_note(signal, plan)
        "#{signal.kind} folded into the in-flight #{plan_change_type(plan)} proposal"
      end

      def plan_change_type(plan)
        data = plan.plan_data.is_a?(Hash) ? plan.plan_data : {}
        data["change_type"].presence
      end

      # Did this signal ask for something other than what the in-flight plan is
      # already doing?
      def different_condition?(plan, signal)
        data = plan.plan_data.is_a?(Hash) ? plan.plan_data : {}
        data["signal_kind"].to_s != signal.kind.to_s
      end

      # Causes that are NOT an operator-actionable configuration gap. An operator
      # who has just rejected an adaptation does not need a high-severity page
      # telling them the adaptation did not happen — they know; they are the
      # reason. It still emits, quietly, because a lane that stays suppressed
      # long after the cooldown should be visible somewhere.
      #
      # Everything else — including an ABSENT cause — stays high. Not knowing
      # why nothing was minted is worth reporting, and this alarm exists
      # precisely because a silent failure had its alarm switched off.
      QUIET_BLOCK_CAUSES = [ ::System::AdaptationGate::CAUSE_REJECTION_COOLDOWN ].freeze

      # One alarm per plan per window, not per tick.
      #
      # The comment here used to claim dedup happened "through the ordinary
      # fleet event path". EventBroadcaster.emit! does none: it unconditionally
      # create!s a FleetEvent and never reads correlation_id for suppression, so
      # passing a fingerprint was a no-op. The only throttle was the engine's
      # 600s decide cache, and since the brake is deliberately held, the same
      # plan re-blocked every tick — ~144 high-severity rows/day for ONE mission
      # missing ONE policy, and up to ~432 for a mission breaching on three
      # fingerprints. (The rejection variant is lower, ~29/day, because each
      # cycle composes a fresh plan rather than re-offering one.)
      #
      # Keyed per PLAN, per the operator direction. A closed-and-recomposed plan
      # gets a new id and therefore one event per cycle — intended: that is a
      # genuinely new proposal being blocked, not the same one shouting.
      BLOCKED_ALARM_TTL_SECONDS = (ENV["FLEET_BLOCKED_ALARM_TTL_SECONDS"] || 6 * 60 * 60).to_i

      # The blocked arm has no reader, so it needs a voice.
      #
      # AdaptationGate returns ROUTED with no request minted when the resolved
      # project.<change_type> category has no permitting policy. Reporting
      # applied: false is honest but INERT — nothing consumes that flag, and the
      # validate-arc exemption means F3-11 cannot escalate it either. Without an
      # event, an operator's only symptom is a mission that silently never
      # adapts. Deduped by fingerprint through the ordinary fleet event path.
      #
      # The brake is deliberately NOT released here: a missing policy is a
      # configuration gap, and #continue_adaptation re-offers this same plan to
      # the gate every tick, so adding the policy dispatches the plan that is
      # already composed. Releasing instead would recompose a fresh plan every
      # dedup TTL and re-block it — churn in place of a fix.
      def escalate_blocked_adaptation!(mission, plan, detail, cause = nil)
        cause = cause.to_s.presence || ::System::AdaptationGate::CAUSE_UNKNOWN
        return unless claim_blocked_alarm!(plan)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "fleet.adaptation_blocked",
          severity: (QUIET_BLOCK_CAUSES.include?(cause) ? :low : :high),
          payload: {
            "mission_id" => mission.id,
            "plan_id" => plan.id,
            "change_type" => plan_change_type(plan),
            "action_category" => ::System::AdaptationGate.action_category_for(plan_change_type(plan).to_s),
            "cause" => cause,
            "detail" => detail
          }.compact,
          source: "decision_engine.adaptation_blocked",
          correlation_id: plan.id
        )
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] blocked-adaptation escalation failed: #{e.message}")
      end

      # FAILS CLOSED, unlike #recently_decided?.
      #
      # That asymmetry is deliberate. recently_decided? gates whether the fleet
      # REMEDIATES, so a broken cache there must not stop the fleet acting — it
      # returns false and the tick proceeds. This gates whether we SHOUT, and a
      # cache we cannot read is not a licence to shout every 60s: failing open
      # here is what would lift the storm from 144/day to 1440/day, precisely
      # when the platform is already unhealthy enough to have lost its cache.
      #
      # A store with no cache API at all (NullStore) is a different case from a
      # BROKEN one — there is no storm mechanism to arm and no dedup to be had,
      # so it emits rather than going silent.
      def claim_blocked_alarm!(plan)
        return true unless Rails.cache.respond_to?(:exist?) && Rails.cache.respond_to?(:write)

        key = "fleet:adaptation_blocked:#{account.id}:#{plan.id}"
        return false if Rails.cache.exist?(key)

        Rails.cache.write(key, Time.current.to_i.to_s, expires_in: BLOCKED_ALARM_TTL_SECONDS)
        true
      rescue StandardError => e
        Rails.logger.warn("[FleetDecisionEngine] blocked-alarm dedup unavailable, suppressing: #{e.message}")
        false
      end

      # Composed but never handed to a runner — a re-ask of the gate is exactly
      # what these need.
      UNDISPATCHED_PROPOSAL_STATUSES = %w[draft validated].freeze

      # A plan in one of these is finished and did NOT land, whatever the gate's
      # last disposition said.
      TERMINAL_PLAN_STATUSES = %w[rejected failed].freeze

      # In flight from composition until the plan settles. `executing` and
      # `approved` HAVE to be here: releasing the brake the instant dispatch
      # claims the plan means that under an auto_approve policy the first signal
      # of a pass moves its plan to executing, and the second signal — a
      # different fingerprint, so cross-tick dedup never sees it — composes a
      # SECOND scale_project run and appends it onto the same live plan.
      # completed / failed / rejected are settled: the next genuine breach may
      # propose again.
      IN_FLIGHT_PROPOSAL_STATUSES = (UNDISPATCHED_PROPOSAL_STATUSES + %w[approved executing]).freeze

      def in_flight_adaptation_plan(mission)
        ::Ai::GoalPlan
          .where(account_id: account.id, status: IN_FLIGHT_PROPOSAL_STATUSES)
          .where("plan_data @> ?", { "kind" => "adaptation_diff", "mission_id" => mission.id }.to_json)
          .order(created_at: :desc)
          .first
      rescue StandardError => e
        # Never let the bookkeeping query block a remediation — worst case is the
        # pre-existing duplicate-proposal behavior, not a lost decision.
        Rails.logger.warn("[FleetDecisionEngine] in-flight proposal lookup failed: #{e.message}")
        nil
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
      #     picks them up) and the result declares convergence_deferred.
      #
      # IMP-848c7e953e2d — that declaration replaces the write-only
      # `requires_reprovision` flag this arm used to return (three writers, no
      # readers).
      #
      # THIS LANE IS NOW MEASURED, and the reasoning that used to stand here no
      # longer holds. It read: this signal kind never reaches the validate arc,
      # because #force_policy_for forces require_approval whenever the payload's
      # requires_approval is set (and it is always set — the sensor filters
      # instances by TemplateApprovalPolicy::LIVE_INSTANCE_SCOPE and the policy
      # counts nodes over that SAME scope, so a firing sensor implies a non-zero
      # provisioned_node_count), forced require_approval decides :pending, and
      # RemediationValidator only records :proceed. The first half is still
      # true. The parenthetical was "nor does the approved replay create one —
      # execute_approved_actions! stamps the request and never calls the
      # validator", and IMP-31f1e5f9b365 closed exactly that gap: the approved
      # replay now records. Forced require_approval is therefore this kind's
      # ONLY route into the validate arc, not its exemption from one.
      #
      # What the declaration guards against is no longer hypothetical.
      # TemplateApplyService#apply! creates exactly the assignment rows
      # TemplateClosureDriftSensor subtracts, so after one apply the sensor's
      # difference is empty BY CONSTRUCTION and the fingerprint is absent from
      # every later pass — and #apply! runs on BOTH arms, above the split
      # below, so the cloud_init arm is silenced the same way. Scored by
      # fingerprint disappearance, both arms would read EFFECTIVE every time,
      # forever, whether or not a single node converged: a fabricated 1.0 in
      # the ground truth the LEARN step consumes. Hence `fingerprint_self_
      # clearing` below, declared on BOTH arms. The pivot arm ALSO declares
      # convergence_deferred, and that one wins — its row is scored by the
      # declaration rather than by the fingerprint, so it is still evidence.
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

        # IMP-31f1e5f9b365 — DECLARED here, at the one point where it becomes
        # true, and on BOTH arms. #apply! has just created exactly the
        # assignment rows TemplateClosureDriftSensor subtracts, so from this
        # line on the fingerprint is absent from every later sense pass whether
        # or not the node ever converged. Fingerprint disappearance is
        # therefore not evidence for this result, and
        # RemediationValidator#record_proceeded! must not mint a row that
        # scores by it. The failing `apply_result.ok?` return above is
        # deliberately outside this: nothing was created, so the sensor still
        # sees the drift and the fingerprint means what it usually means.
        if instance.pivot_boot?
          return {
            applied: true, instance_id: instance.id, node_id: node.id,
            assignments_created: created_module_ids, convergence_deferred: true,
            fingerprint_self_clearing: true,
            reason: "pivot-booted instance composes its module union at boot — assignments created; " \
                    "a rolling reprovision (reboot) is required for them to take effect"
          }
        end

        sync_result = dispatch_reconcile_task(signal, skill_result, command: "sync_modules")
        # NOTE: no convergence_deferred key here, rather than an explicit false.
        # dispatch_reconcile_task can itself return the reboot_pending
        # escalation, which DECLARES the deferral; merging a false over it
        # would erase the one fact this result exists to carry.
        sync_result.merge(assignments_created: created_module_ids, fingerprint_self_clearing: true)
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

        # IMP-f1c1e6d61104 (c) — break the dispatch -> fail -> redispatch loop.
        #
        # Once the agent reports a module whose manifest declares
        # reboot_required (agent part (a) of this task fails the task rather
        # than completing it), another reconcile cannot converge that module:
        # its content cannot be materialized live at all, so re-dispatching is
        # guaranteed to fail again. Escalate the same way
        # #apply_template_closure_drift does rather than looping.
        if (escalation = reboot_pending_escalation(instance, command))
          return escalation
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

      # IMP-f1c1e6d61104 (c) — nil unless this instance's LAST finished reconcile
      # of the same command failed because a module needs a reboot.
      #
      # IMP-848c7e953e2d — the returned hash declares convergence_deferred.
      # This lane's fingerprint is the OPPOSITE case to the pivot closure arm:
      # the drift is still live on every later pass (nobody rebooted), so the
      # validator scored it ineffective every window and three of those tripped
      # STUCK_STREAK_THRESHOLD into a false fleet.remediation_stuck for a lane
      # that declined correctly. Presence is no more evidence than absence when
      # convergence was deferred, so this settles `inconclusive` too.
      #
      # Ordered by completed_at and status-checked SEPARATELY on purpose:
      # System::Task stamps completed_at on fail!/abort!/cancel! as well as
      # complete!, so a timestamp alone cannot tell a failure from a success —
      # the same trap the parent task's guard clauses were built around. Taking
      # the most recent finished task and then asking whether it FAILED is what
      # makes a later successful apply clear the block, rather than the block
      # persisting for the life of the node.
      def reboot_pending_escalation(instance, command)
        last = ::System::Task.where(account: account, operable: instance, command: command)
                             .where.not(completed_at: nil)
                             .order(completed_at: :desc)
                             .first
        return nil unless last&.status == "failed"
        return nil unless last.error_message.to_s.include?("reboot_pending")

        {
          applied: false, instance_id: instance.id, convergence_deferred: true,
          reason: "last #{command} failed with reboot_pending — the module's content cannot be " \
                  "materialized live; a reboot (or rolling reprovision) is required, so another " \
                  "reconcile would fail identically"
        }
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
