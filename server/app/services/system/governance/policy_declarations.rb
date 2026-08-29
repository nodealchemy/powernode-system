# frozen_string_literal: true

module System
  module Governance
    # SINGLE AUTHORITY for the governance rows the code declares.
    #
    # These used to live as local hashes inside the seed files, which made them
    # unreadable from anywhere except a seed run — and `db:seed` is first-boot
    # only (rails-start.sh gates it behind a durable `.db-initialized` marker),
    # so a policy added after an install's first boot never reached it. Measured
    # on live ops-hub 2026-08-24: nine policies added to seeds afterwards had
    # never landed, including `system.module_verify_investigate`, whose sensors
    # had been firing into a silently-blocked arm since the day they shipped.
    #
    # Declaring them here lets PolicyReconciler assert the invariant "every
    # governance row the code declares exists in the RUNNING database" without
    # executing a seed — which matters because the seed path is DESTRUCTIVE (see
    # PolicyReconciler's header) and must not run on an established install.
    #
    # The seed consumes this same constant, so first boot and every later
    # reconcile agree by construction rather than by two lists staying in sync.
    module PolicyDeclarations
      # Operator-path rows for System::Task commands: scope "global", no agent,
      # no user. Verbs are the OPERATOR's default, deliberately conservative for
      # anything that destroys or overwrites state.
      #
      # NOTE (IMP-944567d41689): this key set currently disagrees with
      # System::Task::COMMANDS in both directions — it declares categories for
      # commands the model refuses to insert, and omits real commands. That
      # drift is tracked separately; this constant records what is declared
      # TODAY so the reconciler is honest about the current contract rather than
      # silently repairing a vocabulary question it has no mandate to decide.
      MANUAL_OPERATION_POLICIES = {
        "system.task.start" => "auto_approve",
        "system.task.stop" => "auto_approve",
        "system.task.restart" => "auto_approve",
        "system.task.reboot" => "auto_approve",
        "system.task.terminate" => "require_approval",        # destroys instance
        "system.task.provision" => "notify_and_proceed",      # creates infra
        "system.task.deprovision" => "require_approval",      # destroys infra
        "system.task.associate_public_ip" => "auto_approve",
        "system.task.disassociate_public_ip" => "auto_approve",
        "system.task.create_volume" => "notify_and_proceed",
        "system.task.delete_volume" => "require_approval",
        "system.task.attach_volume" => "auto_approve",
        "system.task.detach_volume" => "notify_and_proceed",
        "system.task.create_snapshot" => "auto_approve",
        "system.task.delete_snapshot" => "require_approval",
        "system.task.restore_snapshot" => "require_approval", # rolls back state
        "system.task.create_network" => "notify_and_proceed",
        "system.task.delete_network" => "require_approval",
        "system.task.sync" => "auto_approve",
        "system.task.sync_modules" => "auto_approve",
        "system.task.apply_config" => "notify_and_proceed",
        "system.task.build_module" => "notify_and_proceed",
        "system.task.commit_module" => "notify_and_proceed",
        "system.task.ssh_command" => "require_approval",      # arbitrary code execution
        "system.task.backup" => "auto_approve",
        "system.task.restore" => "require_approval",          # overwrites state
        "system.task.custom" => "require_approval"            # unknown semantics
      }.freeze

      # The row SHAPE these declarations resolve at. Load-bearing: an
      # agent-scoped row can never match an agent-less operator caller
      # (Ai::InterventionPolicy#agent_matches?), so the operator path needs a
      # row of exactly this shape or it falls through to the require_approval
      # default regardless of what any agent-scoped row says.
      MANUAL_OPERATION_SCOPE = { scope: "global", ai_agent_id: nil, user_id: nil }.freeze

      MANUAL_OPERATION_ATTRIBUTES = {
        priority: 5,
        is_active: true,
        conditions: {},
        preferred_channels: %w[notification]
      }.freeze

      # ================================================================
      # AGENT-SCOPED AND OPERATOR-PATH SETS
      # ================================================================
      # Same argument as the manual set above, one tier out. These lived as
      # LOCAL HASHES inside their seed files, so nothing but a seed run could
      # read them — and `db:seed` is first-boot only. Every set below is a row
      # group that an established install can be missing with no way to notice.
      #
      # Moved here verbatim, comments included; each seed now consumes its
      # constant, so first boot and every later reconcile agree by construction
      # rather than by two lists staying in sync.

      # The trust gate every seeded policy row carries. Mirrors
      # System::Seeds::AgentSetupHelpers::DEFAULT_TRUST_CONDITIONS — an
      # emergency trust demotion knocks out agent and operator rows together.
      DEFAULT_TRUST_CONDITIONS = { "trust_tier_minimum" => "monitored" }.freeze

      FLEET_AUTONOMY_POLICIES = {
        # Node-cert rotation has NO server-side actuator: NodeEnrollmentService
        # refresh requires the on-node agent's CSR (private keys never leave the
        # node), so the platform cannot rotate autonomously. require_approval
        # keeps each expiring cert visible as an operator work item instead of a
        # proceed lane that silently does nothing (audit F3-03).
        "system.cert_rotate"             => "require_approval",

        # Platform ACME cert renewal (CertExpirySensor → platform_maintenance
        # cert_rotate). notify_and_proceed: renewal is reversible/low-blast-radius
        # but can fail on CA/DNS-01 issues, so an operator should be informed.
        "system.acme_cert_rotate"        => "notify_and_proceed",

        # Phase 3 (Federation & Multi-Site) — federation peer liveness remediation
        # (FederationPeerLivenessSensor → system.federation_peer_remediate). This
        # policy MUST live on Fleet Autonomy, not SDWAN Manager: the sensor runs in
        # FleetAutonomyService::SENSORS, whose tick! gates as the "Fleet Autonomy"
        # agent, so gate_action! resolves permitted_actions against THIS agent.
        # Re-handshake / degrade / alert is low-to-medium blast radius and the
        # dedup TTL self-throttles repeat firings → notify_and_proceed.
        "system.federation_peer_remediate" => "notify_and_proceed",

        # Phase 3 (SDWAN autonomous remediation) — the 6 system.sdwan_* actions below
        # were MOVED here from system_sdwan_manager_agent.rb. Like
        # federation_peer_remediate, they fire from FleetAutonomyService::SENSORS,
        # whose tick! gates as the "Fleet Autonomy" agent — so gate_action! resolves
        # these policies against THIS agent. Seeded on SDWAN Manager they were
        # stranded (silently 'not_permitted') in the sensor path. The operator-
        # initiated sdwan.* CRUD policies stay on SDWAN Manager (gated via
        # Ai::AutonomyGate as that agent). Autonomy levels preserved from the prior
        # SDWAN Manager seed.
        #
        # IMP-17bc5546009a (2026-08-21): a 7th, system.sdwan_route_policy_audit, was
        # seeded here too but DELETED outright — no sensor emitted it, no
        # DecisionEngine binding routed to it, and no executor carried the category,
        # so it was a permanently no-op auto_approve row. A real compiled-policy-vs-
        # FRR-observed drift sensor is a deliberate future build, not something to
        # back into because this row existed; see FleetAutonomyService#dedup_key_for
        # spec for the pinned removal.
        "system.sdwan_peer_remediate"        => "notify_and_proceed",
        # NOTE: no signal routes here since IMP-df40782d3f4d moved
        # system.sdwan_credential_expiring to system.sdwan_credential_refresh
        # below. Kept seeded + registered (subset invariant allows a category
        # without a producer) so live rows stay operator-tunable and a future
        # true key-TTL lane inherits its recorded intent.
        "system.sdwan_key_rotate"            => "auto_approve",
        "system.sdwan_failover"              => "require_approval",
        "system.sdwan_user_device_revoke"    => "require_approval",
        "system.sdwan_bgp_session_remediate" => "notify_and_proceed",
        "system.sdwan_vip_failover"          => "require_approval",

        # IMP-df40782d3f4d — system.sdwan_credential_expiring routes here now:
        # a server-side MembershipCredential re-issue (SdwanCredentialRefreshExecutor
        # → MembershipCredentialSigner.ensure_fresh!), NOT a key rotation — rotating
        # the WG key revoked the active pubkey and cut the still-working tunnel of
        # exactly the not-polling peer whose MC was aging out. notify_and_proceed:
        # the refresh itself is benign and idempotent, but an MC can only near
        # expiry when the agent has stopped pulling, and the operator should see
        # that degraded control channel rather than have it silently patched over.
        # Seeded HERE (not SDWAN Manager) for the same mechanical reason as the 7
        # actions above — the sensor fires from FleetAutonomyService::SENSORS,
        # which gates as THIS agent.
        "system.sdwan_credential_refresh"    => "notify_and_proceed",
        # IMP-c7d663f24a0b — SdwanServiceHealthSensor (sdwan_service_silent +
        # sdwan_portmap_orphaned). notify_and_proceed: notify-level first, no
        # auto-remediation until the signal quality is proven in the field.
        #
        # Seeded HERE rather than on the SDWAN Manager agent for the same mechanical
        # reason recorded in the NOTE at the bottom of this file — the sensor fires
        # from FleetAutonomyService::SENSORS, and #permitted_actions resolves
        # policies with `where(ai_agent_id: agent.id)` against the agent running the
        # tick. A policy on SDWAN Manager is invisible to that lookup, so
        # gate_action! would return :blocked/"not_permitted" and every signal this
        # sensor produces would die at the gate — a sensor inert at its far end.
        # Same placement as federation_peer_remediate / gitops_drift_remediate /
        # disk_image_publication_investigate.
        #
        # TRAP, if you add another notify-level category: this one PROCEEDS but never
        # actuates (skill: nil in SIGNAL_BINDINGS, no REMEDIATION_APPLIERS entry), and
        # RemediationValidator opens a pending RemediationOutcome for every proceeded
        # decision. Nothing ever clears it — the triggering condition ends when a
        # person fixes the workload, not inside the 90s SETTLE_WINDOW — so it scores
        # ineffective every window until the F3-11 streak manufactures a FALSE
        # fleet.remediation_stuck HIGH escalation and forces require_approval on a
        # lane that never acted. That is why the category is also listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES. Membership there is
        # DECLARED, never inferred: "skill-less and applier-less" does NOT imply
        # non-remediating (system.cert_rotate and the SLO categories are both and
        # still actuate elsewhere), so a new notify-only category must be added by
        # hand or it ships this failure mode.
        "system.sdwan_service_health_investigate" => "notify_and_proceed",

        # IMP-57e9a90598ee — SdwanOvnDeploymentHealthSensor (ovn deployment
        # degraded / activation stalled). Seeded HERE because the sensor fires from
        # FleetAutonomyService::SENSORS, which gates as THIS agent (see the
        # sdwan_service_health_investigate note above — a policy on SDWAN Manager
        # would be invisible to this tick and every signal would die at the gate).
        #
        # notify_and_proceed, never auto_approve: the lane has NO applier by design
        # — the degraded component is the operator's own OVN control plane (northd,
        # NB/SB DBs), which the platform does not provision — so "proceed" means
        # "notify the operator" and nothing else. Also listed in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES so the persistent
        # fingerprint cannot manufacture false remediation_stuck escalations.
        "system.sdwan_ovn_deployment_investigate" => "notify_and_proceed",

        # IMP-2f34679b6b73 — SdwanBgpSessionHealthSensor's attribution family (a BGP
        # report the platform could not attribute to the network it arrived under, or
        # one the agent disclaimed). Seeded HERE for the same reason as the two
        # categories above: the sensor fires from FleetAutonomyService::SENSORS and
        # gates as THIS agent, so a policy anywhere else is invisible to the tick and
        # every signal dies at the gate.
        #
        # notify_and_proceed, never auto_approve: the condition is an ABSENCE of a
        # measurement, and the whole point of surfacing it is that an operator learns
        # the host is running an agent that polls FRR without naming a VRF. There is
        # no applier — "proceed" means "notify" — so the category is also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES.
        "system.sdwan_bgp_observation_investigate" => "notify_and_proceed",

        # IMP-da1b772c2596 — SdwanApplyHealthSensor (sdwan_apply_failed +
        # sdwan_apply_not_measured): the agent's OBSERVED per-subsystem apply
        # outcome, which nothing on the server consumed before this. Seeded HERE for
        # the same mechanical reason as the three categories above — the sensor
        # fires from FleetAutonomyService::SENSORS and gates as THIS agent, so a
        # policy on SDWAN Manager would be invisible to the tick and every signal
        # would die at the gate.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be
        # none — a failed apply is a kernel-side refusal the agent already retries
        # on every tick, so re-serving the same config remediates nothing. "Proceed"
        # means "notify the operator". Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because a
        # persistently failing applier holds one fingerprint indefinitely.
        "system.sdwan_apply_investigate" => "notify_and_proceed",

        # IMP-7034199a5a19 — SdwanUserDeviceConfigStalenessSensor. An issued user
        # device's config is rendered once and never re-pulled, so a VIP, a peer
        # lan_subnet, or a federation prefix added afterwards is missing from every
        # config already in the field. Seeded HERE for the same mechanical reason as
        # the categories above — the sensor fires from FleetAutonomyService::SENSORS
        # and gates as THIS agent, so a policy on SDWAN Manager would be invisible to
        # the tick and every signal would die at the gate.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be none
        # — the drifted artefact is a text file on a user's laptop. "Proceed" means
        # "notify the operator", who re-issues the device. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a human acts.
        "system.sdwan_user_device_config_investigate" => "notify_and_proceed",

        # IMP-3855ff9908f2 — ModuleVerifyFailedSensor (module_verify_failed +
        # module_verify_not_measured): the agent's OBSERVED answer to "does this
        # node actually provide what the module declares", which nothing produced
        # before this. Seeded HERE for the same mechanical reason as the categories
        # above — the sensor fires from FleetAutonomyService::SENSORS and gates as
        # THIS agent, so a policy anywhere else is invisible to the tick and every
        # signal would die at the gate.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be
        # none — a failed probe means the node's filesystem or PATH disagrees with
        # the manifest (a wrong artifact, a shadowing package, a profile script
        # reordering PATH), and re-serving the same module fixes none of them. In
        # the gitleaks v4 incident the artifact the platform would re-serve was the
        # empty one. "Proceed" means "notify the operator". Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a human changes an artifact or an image.
        "system.module_verify_investigate" => "notify_and_proceed",

        # IMP-a8f9fa74284d — BootLkgArmSensor (node_lkg_unarmed +
        # node_lkg_stale): whether a live node is armed with a valid
        # last-known-good composition. System::BootLkgStateWriter has derived
        # that answer on every heartbeat since IMP-b8d5cfa33b79 and nothing
        # asked. Seeded HERE for the same mechanical reason as the categories
        # above — the sensor fires from FleetAutonomyService::SENSORS and gates
        # as THIS agent, so a policy anywhere else is invisible to the tick and
        # every signal would die at the gate.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be
        # none — the LKG is frozen on the node's own disk by the agent at boot,
        # and nothing the platform dispatches re-arms it. "Proceed" means
        # "notify the operator", who restores or re-captures it. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a person acts — and on a fleet still running
        # pre-boot/LKG agents it stands indefinitely.
        "system.node_lkg_investigate" => "notify_and_proceed",

        # StuckTaskBacklogSensor — "tasks are piling up behind the janitor". Seeded
        # HERE for the same mechanical reason as the categories above: the sensor
        # fires from FleetAutonomyService::SENSORS and gates as THIS agent, so a
        # policy anywhere else is invisible to the tick and every signal dies at the
        # gate.
        #
        # notify_and_proceed, never auto_approve: there is no applier and can be
        # none. The causes are an empty scope, a stopped worker, a broken seam — none
        # repairable by anything the platform can dispatch. "Proceed" means "reach an
        # operator". Also in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES,
        # because the fingerprint stands until a person fixes the janitor.
        "system.task_backlog_investigate" => "notify_and_proceed",

        # Read/notify
        "system.module_assign"           => "notify_and_proceed",
        "system.instance_reboot"         => "notify_and_proceed",

        # Sensitive — require_approval
        "system.instance_reprovision"    => "require_approval",
        "system.instance_terminate"      => "require_approval",
        "system.cert_revoke"             => "require_approval",
        "system.module_promote_to_live"  => "require_approval",
        "system.fleet_rolling_upgrade"   => "require_approval",
        # Campaign 019f505f inc 4 — BootImageDriftSensor → BootImageDriftRolloutExecutor.
        # Seeded HERE (Fleet Autonomy), not Disk Image Manager, because the sensor fires
        # from FleetAutonomyService::SENSORS and gates as THIS agent (same reason
        # system.disk_image_publication_investigate lives here). A fleet-wide in-place
        # reboot rollout is high blast radius → require_approval; the executor plans
        # canary-first and dispatches the batch on approval.
        "system.node_boot_image_drift"   => "require_approval",
        # Campaign 019f6084 §2.4.3 — TemplateClosureDriftSensor → apply the
        # template's current closure onto an already-provisioned instance
        # (TemplateApplyService#apply! + sync_modules, or a rolling-reprovision
        # flag for pivot-booted instances). Seeded require_approval as a
        # baseline, but DecisionEngine#force_policy_for pins it there regardless:
        # the sensor only ever fires for an instance that already exists on the
        # template, so TemplateApprovalPolicy's blast-radius classification is
        # never the "nothing provisioned" case — a manifest change is about to
        # propagate to live fleet, same rationale as node_boot_image_drift above.
        "system.template_closure_apply"  => "require_approval",
        "system.region_expansion"        => "require_approval",
        "system.capacity_resize"         => "require_approval",

        # Stale BGP observations are pure observation — no remediation; the
        # `observation` action_category collects them for dashboards without
        # entering the approval pipeline.
        "system.observation"             => "auto_approve",

        # Stale storage assignment re-reconciliation (StorageAssignmentDriftSensor,
        # audit F3-07). notify_and_proceed: it re-runs the same reconciliation the
        # assignment's own after_commit would — reversible and low blast radius —
        # but the operator should see that the safety net is firing.
        "system.storage_assignment_reconcile" => "notify_and_proceed",

        # GitOps drift surfaced by GitopsDriftSensor (in FleetAutonomyService::SENSORS,
        # so it gates as THIS agent — same reason federation_peer_remediate and the
        # autonomous sdwan_* policies live here, not on the GitOps Reconciler agent
        # that authors the proposals). notify_and_proceed: drift is informational
        # (the reconciler opens proposals for the actual apply); without this binding
        # the signal was classified :skipped and never reached the operator. Deduped
        # per repo+revision fingerprint, so a standing drift notifies once per TTL.
        "system.gitops_drift_remediate" => "notify_and_proceed",

        # DK3 of the disk-image-CI restoration — DiskImagePublicationFailureStreakSensor
        # lives in FleetAutonomyService::SENSORS (not Disk Image Manager's own tick),
        # so it gates as THIS agent — same reason federation_peer_remediate /
        # gitops_drift_remediate / sdwan_* live here rather than on their specialist
        # agent. notify_and_proceed: no auto-remediation exists (a broken CI pipeline
        # needs operator investigation), this only surfaces the streak; deduped
        # per-platform via the sensor's fingerprint.
        "system.disk_image_publication_investigate" => "notify_and_proceed",

        # IMP-4019664a524b — CapabilityGapSensor (in FleetAutonomyService::SENSORS,
        # so it gates as THIS agent, same reason as the three above). require_approval
        # is the disposition, not a placeholder: the gap's only remediation is
        # AUTHORING a module, which must pass the R1/R2/R3 reuse gate
        # (docs/runbooks/module-authoring.md Phase 0), so the operator queue IS the
        # destination. It also keeps #decide at :pending, which RemediationValidator
        # never snapshots — a gap that stands until someone ships a module would
        # otherwise score ineffective forever and trip a false remediation_stuck.
        "system.capability_gap_review" => "require_approval",

        # Package repository ingestion. Sync is routine + reversible (just
        # refreshes cached metadata); module creation is supply-chain critical
        # (operator audits each new package entering the fleet); refresh requires
        # approval for non-CVE drifts (intervention policy splits CVE-flagged
        # refresh out into auto-approve via the executor's payload metadata).
        "system.package_repository.sync" => "auto_approve",
        "system.package_module.create"   => "require_approval",
        "system.package_module.refresh"  => "require_approval",

        # Architecture catalog. Propose auto-approves at the policy layer
        # because the Ai::AgentProposal it creates is itself the human-review
        # gate. Direct CRUD requires approval — even with system.architectures.manage,
        # mutating the catalog surfaces for operator confirmation because it
        # affects every account's available platforms.
        "system.architecture.propose" => "auto_approve",
        "system.architecture.create"  => "require_approval",
        "system.architecture.update"  => "require_approval",
        "system.architecture.delete"  => "require_approval"

        # NOTE: Operator-initiated SDWAN CRUD policies (sdwan.*) live on
        # system_sdwan_manager_agent.rb (2026-05-10) — they gate via Ai::AutonomyGate
        # as the SDWAN Manager agent. The 7 AUTONOMOUS system.sdwan_* remediation
        # policies were moved back HERE (above), because they fire from the sensor
        # path which gates as Fleet Autonomy.
        # NOTE: CVE policies moved to system_cve_responder_agent.rb (2026-05-10).
        # NOTE: Disk Image policies moved to system_disk_image_manager_agent.rb (2026-05-10).
        # The 5-agent split keeps per-domain approval queues independent and lets
        # operators pause one domain (e.g. SDWAN during a maintenance window)
        # without halting fleet ops.
      }.freeze

      SDWAN_MANAGER_POLICIES = {
        # NOTE: 6 autonomous SDWAN remediation actions (system.sdwan_peer_remediate,
        # system.sdwan_key_rotate, system.sdwan_failover, system.sdwan_user_device_revoke,
        # system.sdwan_bgp_session_remediate, system.sdwan_vip_failover) were MOVED to
        # fleet_autonomy_agent.rb. Those actions fire from FleetAutonomyService::SENSORS,
        # whose tick! gates as the "Fleet Autonomy" agent, so gate_action! resolves the
        # policy against THAT agent — seeding them here left them stranded (silently
        # 'not_permitted') in the sensor path. This mirrors the
        # system.federation_peer_remediate move.
        #
        # IMP-17bc5546009a: a 7th, system.sdwan_route_policy_audit, moved alongside
        # them but was later DELETED outright (2026-08-21) — it had no sensor, no
        # DecisionEngine binding, and no executor, so it was a seeded no-op on either
        # agent. Not re-added here; see fleet_autonomy_agent.rb's history for the
        # removal.
        #
        # Only operator-initiated sdwan.* CRUD policies remain here.
        #
        # This table is seeded TWICE, against two different audiences (see the
        # operator upsert below): once agent-scoped, which is what an agent dispatch
        # resolves against, and once agent-less, which is what an operator HTTP
        # request resolves against. The verbs below are the single recorded intent for
        # both — do not fork them.

        # Operator-initiated network ops (newly gated 2026-05-10)
        "sdwan.network_create"              => "notify_and_proceed",
        "sdwan.network_update"              => "notify_and_proceed",
        "sdwan.network_delete"              => "require_approval",

        # Peer ops — destroy revokes a node's network membership
        "sdwan.peer_create"                 => "notify_and_proceed",
        "sdwan.peer_update"                 => "notify_and_proceed",
        "sdwan.peer_delete"                 => "require_approval",

        # Firewall rules — additive auto, removal/edit notify
        "sdwan.firewall_rule_create"        => "notify_and_proceed",
        "sdwan.firewall_rule_update"        => "notify_and_proceed",
        "sdwan.firewall_rule_delete"        => "require_approval",

        # VIPs — create/update notify, destroy + manual failover require approval
        "sdwan.virtual_ip_create"           => "notify_and_proceed",
        "sdwan.virtual_ip_update"           => "notify_and_proceed",
        "sdwan.virtual_ip_delete"           => "require_approval",

        # Route policies — additive notify, destructive require approval
        "sdwan.route_policy_create"         => "notify_and_proceed",
        "sdwan.route_policy_update"         => "notify_and_proceed",
        "sdwan.route_policy_delete"         => "require_approval",

        # Port mappings — DNAT. Creating and updating are low-risk; DELETING is
        # not. It tears down the ingress path of a published service, which is
        # no less destructive than the network/peer/VIP deletes right next to
        # it. It was the ONLY destructive verb in this set that proceeded
        # unattended — 1 of 14 — which reads as an oversight rather than a
        # decision. Pinned by the "every destructive verb requires approval"
        # spec so the set cannot drift back.
        "sdwan.port_mapping_create"         => "notify_and_proceed",
        "sdwan.port_mapping_update"         => "notify_and_proceed",
        "sdwan.port_mapping_delete"         => "require_approval",

        # Access grants — granting FRESH access notifies, revoking requires approval.
        # Deleting is strictly more destructive than revoking: dependent: :destroy
        # cascades to every VPN device and their Vault keys, leaving nothing for the
        # 90-day audit window, so it is gated at least as tightly.
        #
        # IMP-343163bf37a4 splits REACTIVATION out of create. The grant is unique per
        # (network, user), so a "create" naming a user whose grant was revoked reuses
        # that row and clears its revocation — it is the inverse of the revoke above,
        # not an additive grant, and the "granting notifies" rationale never covered
        # it. notify_and_proceed executes inline (Ai::AutonomyGate treats it exactly
        # as auto_approve), so leaving reactivation under the create category would
        # have re-entered the revoked->active state with no human decision at all.
        # It therefore carries revoke's own tier.
        "sdwan.access_grant_create"         => "notify_and_proceed",
        "sdwan.access_grant_reactivate"     => "require_approval",
        "sdwan.access_grant_revoke"         => "require_approval",
        "sdwan.access_grant_delete"         => "require_approval",

        # User devices — issuing a VPN config notifies, revoking requires approval
        "sdwan.user_device_create"          => "notify_and_proceed",

        # Phase O6 write family (IMP-97c7b4123d8f). These shipped outside the
        # executor/gate regime entirely — direct model writes with no category, so
        # no tier was configurable at all.
        #
        # For the OVN family specifically, REST is read-only (routes.rb exposes only
        # index/show for ovn_deployments and no routes at all for switches, ports or
        # ACLs), so an agent held destructive reach a console operator did not have.
        # RESIDUAL recorded here, to be closed by the per-family parity tasks that
        # own those controllers: host_bridges#destroy (which forced release,
        # skipping the drain window) and ipfix_collectors#update/#destroy were REST
        # writes that remained UNGATED, so for those two families the asymmetry was
        # inverted rather than removed. BOTH ARE NOW CLOSED:
        #   - ipfix_collectors#create/#update/#destroy: CLOSED by IMP-6bbe5c673c38,
        #     which also added sdwan.ipfix_collector_update below. All three now
        #     route through Ai::AutonomyGate, so the tiers in this table bind on
        #     both surfaces for this family.
        #   - host_bridges#destroy: CLOSED by IMP-53a5c597ec8c, which also added
        #     REST create + activate so all three host-bridge tiers below bind on
        #     both the REST and MCP surfaces. NOT on a third: the
        #     SdwanHostBridgeComposeExecutor AI skill allocates (up to MAX_HOSTS
        #     = 100) and force-releases on rollback through the allocator
        #     directly, outside Ai::AutonomyGate — BaseSkillExecutor has no gate
        #     seam. Skills are a separate authorization lane from MCP actions and
        #     bringing them under these tiers is its own task; stated here so the
        #     coverage claim is not read wider than it is. That task additionally fixed a SEMANTIC divergence the
        #     gap was hiding: the REST route hard-forced the release (skipping the
        #     drain window) while the MCP twin defaulted to draining, so one act
        #     had opposite safety postures depending on who asked. The default is
        #     now DRAIN on both surfaces, declared once on
        #     Sdwan::Executors::ReleaseHostBridge, with force an explicit opt-in.
        #     NOTE this tier now gates BOTH arms: an approver reading a
        #     host_bridge_delete card must check the `force` param to know whether
        #     they are authorizing a drain or an immediate teardown.
        # Tiers follow the sibling precedent: creates and state transitions notify,
        # deletes require approval.
        #
        # Two deletes are sharper than their siblings and are called out rather than
        # left to the pattern: sdwan.ovn_deployment_delete removes the account's
        # whole OVN control plane (REST has no equivalent verb), and
        # sdwan.ovn_acl_delete retracts an isolation rule, which RELAXES multi-tenant
        # separation rather than merely removing a resource.
        "sdwan.host_bridge_create"          => "notify_and_proceed",
        "sdwan.host_bridge_update"          => "notify_and_proceed",
        "sdwan.host_bridge_delete"          => "require_approval",
        "sdwan.ovn_deployment_create"       => "notify_and_proceed",
        "sdwan.ovn_deployment_delete"       => "require_approval",
        "sdwan.ovn_logical_switch_create"   => "notify_and_proceed",
        "sdwan.ovn_logical_switch_update"   => "notify_and_proceed",
        "sdwan.ovn_logical_switch_delete"   => "require_approval",
        "sdwan.ovn_logical_switch_port_create" => "notify_and_proceed",
        "sdwan.ovn_logical_switch_port_update" => "notify_and_proceed",
        "sdwan.ovn_logical_switch_port_delete" => "require_approval",
        "sdwan.ovn_acl_create"              => "notify_and_proceed",
        "sdwan.ovn_acl_delete"              => "require_approval",
        "sdwan.ipfix_collector_create"      => "notify_and_proceed",
        # IMP-6bbe5c673c38 — the state toggle, on the family rule stated above
        # (creates and state transitions notify). It is the NON-destructive way to
        # take a collector out of service; the delete below additionally cascades
        # the collector's flow_samples. Tiering the toggle at or above the delete
        # would push an agent back toward the destructive verb, which is the defect
        # this row exists to close, so it sits with its state-transition siblings
        # (sdwan.host_bridge_update, sdwan.ovn_logical_switch_update).
        #
        # Stated plainly because the category is per-verb and cannot separate the
        # two directions: this tier also covers DISABLE, and disabling the winning
        # collector stops IPFIX export for the whole account (the compiler stamps
        # exactly one). notify_and_proceed executes INLINE, so the notification is
        # the only control on that — accepted because the effect is fully reversible
        # by one further call and destroys nothing, unlike the delete below.
        "sdwan.ipfix_collector_update"      => "notify_and_proceed",
        "sdwan.ipfix_collector_delete"      => "require_approval",

        # Federation — cross-instance peering is always sensitive
        "sdwan.federation_peer_propose"     => "require_approval",
        "sdwan.federation_peer_accept"      => "require_approval",
        "sdwan.federation_peer_revoke"      => "require_approval",

        # IMP-9bf58a693634 — data_residency is a compliance DECLARATION, not a
        # label: Federation::ResidencyEnforcer gates cross-boundary record homing on
        # it and Sdwan::FederationGovernance raises a finding on an active platform
        # peer that has not declared one. Rewriting it relaxes or fabricates a
        # regulatory boundary, so it carries the tier of the three trust-boundary
        # verbs above rather than the notify_and_proceed the other peer-field edits
        # take — notify_and_proceed executes INLINE (Ai::AutonomyGate treats it
        # exactly as auto_approve), which for this field would have bought an audit
        # row and no human decision at all.
        "sdwan.federation_peer_data_residency" => "require_approval"
      }.freeze

      CVE_RESPONDER_POLICIES = {
        "system.cve_remediate"               => "require_approval",   # patch strategy needs operator review
        "system.cve_sbom_ingest"             => "auto_approve",       # importing inventory is read-shape
        "system.cve_exposure_scan"           => "auto_approve",       # scanning produces findings, no mutations
        "system.cve_auto_remediate"          => "block",              # off by default; operators opt in per-policy
        # Fires only when CriticalUpgradeAvailableSensor sees the intersection
        # of (a) drift on a package-derived module AND (b) an open CveExposure
        # on that module. The patched upstream version *already exists* — the
        # only thing left to do is materialize it locally and roll it out. This
        # is the "proactively upgrade critical modules" path: notify operators
        # and dispatch the orchestrator inline. Use the system.cve_auto_remediate
        # kill-switch to force this back to block/require_approval per-account.
        "system.module_critical_upgrade_ready" => "notify_and_proceed"
      }.freeze

      DISK_IMAGE_MANAGER_POLICIES = {
        "system.disk_image_publication_promote"   => "require_approval",  # production rollout
        "system.disk_image_publication_rollback"  => "require_approval",  # reverting affects active fleet
        "system.disk_image_retention_update"      => "auto_approve",      # GC config, low-risk
        "system.disk_image_webhook_trigger"       => "notify_and_proceed", # webhook ingest
        "system.disk_image_webhook_revoke"        => "require_approval",  # cuts active CI integration
        "system.disk_image_webhook_rotate_secret" => "notify_and_proceed" # invalidates old, but recoverable
      }.freeze

      GITOPS_RECONCILER_POLICIES = {
        "system.gitops_apply_proposal"      => "require_approval",  # applies a diff to live fleet state
        "system.gitops_register_repository" => "require_approval",  # adds a new declarative source of truth
        "system.gitops_sync_repository"     => "auto_approve"       # read-side: refresh the diff, no mutation
      }.freeze

      RUNTIME_MANAGER_POLICIES = {
        # Docker daemon lifecycle
        "system.runtime_docker_provision"        => "notify_and_proceed",
        "system.runtime_docker_decommission"     => "require_approval",

        # Kubernetes cluster lifecycle (K3s today, kubeadm in Phase 3 —
        # same action vocabulary regardless of flavor; flavor enum on
        # Devops::KubernetesCluster gates which provisioner the agent uses).
        "system.runtime_k8s_cluster_bootstrap"   => "notify_and_proceed",
        "system.runtime_k8s_cluster_decommission" => "require_approval",
        "system.runtime_k8s_node_join"           => "notify_and_proceed",
        "system.runtime_k8s_node_drain"          => "require_approval",
        "system.runtime_k8s_runtime_upgrade"     => "require_approval"
      }.freeze

      INSTANCE_POOL_POLICIES = {
        "system.instance_pool_create"     => "require_approval",   # capacity commitment
        "system.instance_pool_update"     => "notify_and_proceed", # changes pool size targets
        "system.instance_pool_delete"     => "require_approval",   # removes pool + ready instances
        "system.instance_pool_replenish"  => "auto_approve",       # tops up to target — routine
        "system.instance_pool_drain"      => "require_approval",   # halts replenishment
        "system.instance_pool_acquire"    => "auto_approve"        # claim a ready member — fast path
      }.freeze

      PROVISIONING_POLICIES = {
        "project.adapt" => "notify_and_proceed",
        "project.cost_control" => "notify_and_proceed",
        "project.scale_horizontal" => "auto_approve",
        "project.relocate" => "require_approval",
        "project.schema_change" => "require_approval",
        "project.security_change" => "require_approval"
      }.freeze

      # DELIBERATELY THE GATED SUBSET, NOT ALL SEVEN. The other four runtime
      # categories have no gate site, so an operator row for them would render
      # as a working control that nothing reads —
      # `system_runtime_operator_policies_spec.rb` pins that they must NOT
      # resolve. Declaring them here would manufacture that defect.
      RUNTIME_OPERATOR_GATED_KEYS = %w[
        system.runtime_docker_provision
        system.runtime_docker_decommission
        system.runtime_k8s_cluster_decommission
      ].freeze

      RUNTIME_OPERATOR_POLICIES = RUNTIME_MANAGER_POLICIES.slice(*RUNTIME_OPERATOR_GATED_KEYS).freeze

      # project.scale_horizontal carries an extra machine-readable window on
      # top of the trust gate. A set-level `conditions` cannot express it, so
      # the declaration record below carries per-category overrides — without
      # that slot this condition silently flattens to the set default.
      PROVISIONING_CONDITION_OVERRIDES = {
        "project.scale_horizontal" => {
          "trust_tier_minimum" => "monitored",
          "auto_apply_window" => "watch_policies.auto_scale_max_replicas"
        }.freeze
      }.freeze

      # Agent identity is keyed on SOURCE_KEY, not name. The seeds look agents
      # up by name, but every seeded agent also carries a source_key and the
      # model documents these as "platform-provided, seed-managed by
      # source_key" — so an operator who renames one keeps a resolvable
      # declaration instead of silently losing its whole policy set.
      AGENT_IDENTITIES = {
        "fleet-autonomy"     => { name: "Fleet Autonomy",      agent_type: "monitor" },
        "sdwan-manager"      => { name: "SDWAN Manager",       agent_type: "monitor" },
        "cve-responder"      => { name: "CVE Responder",       agent_type: "monitor" },
        "disk-image-manager" => { name: "Disk Image Manager",  agent_type: "monitor" },
        "gitops-reconciler"  => { name: "GitOps Reconciler",   agent_type: "monitor" },
        "runtime-manager"    => { name: "Runtime Manager",     agent_type: "monitor" }
      }.freeze

      # Every declared row group, with the SHAPE it resolves at. `agent_key`
      # nil means an agent-less row; a set whose agent is absent is SKIPPED,
      # never guessed at another shape.
      #
      # NOTE the two dual-shape entries: instance-pool declares the same six
      # categories at BOTH the operator (global) and agent shapes, exactly as
      # its seed writes them, because the two bind different callers.
      POLICY_SETS = [
        { key: "fleet-autonomy",     agent_key: "fleet-autonomy",     scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: FLEET_AUTONOMY_POLICIES },
        { key: "sdwan-manager",      agent_key: "sdwan-manager",      scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: SDWAN_MANAGER_POLICIES },
        { key: "cve-responder",      agent_key: "cve-responder",      scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: CVE_RESPONDER_POLICIES },
        { key: "disk-image-manager", agent_key: "disk-image-manager", scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: DISK_IMAGE_MANAGER_POLICIES },
        { key: "gitops-reconciler",  agent_key: "gitops-reconciler",  scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: GITOPS_RECONCILER_POLICIES },
        { key: "runtime-manager",    agent_key: "runtime-manager",    scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: RUNTIME_MANAGER_POLICIES },
        { key: "instance-pool-agent", agent_key: "fleet-autonomy",    scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: INSTANCE_POOL_POLICIES },
        { key: "provisioning",       agent_key: "fleet-autonomy",     scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: PROVISIONING_POLICIES,
          condition_overrides: PROVISIONING_CONDITION_OVERRIDES },
        { key: "sdwan-operator",     agent_key: nil,                  scope: "action_type",
          priority: 5,  conditions: DEFAULT_TRUST_CONDITIONS, policies: SDWAN_MANAGER_POLICIES },
        { key: "runtime-operator",   agent_key: nil,                  scope: "action_type",
          priority: 5,  conditions: DEFAULT_TRUST_CONDITIONS, policies: RUNTIME_OPERATOR_POLICIES },
        { key: "instance-pool-operator", agent_key: nil,              scope: "global",
          priority: 5,  conditions: {}, policies: INSTANCE_POOL_POLICIES }
      ].freeze
    end
  end
end
