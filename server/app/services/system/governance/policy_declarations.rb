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
      # Gate-path rows for System::Task commands: scope "global", no agent, no
      # user. These are the defaults for every caller that reaches the gate —
      # operator AND agent, see "WHO THIS ACTUALLY GOVERNS" below — and are
      # deliberately conservative for anything that destroys or overwrites
      # state, or that hands the caller an unvalidated payload on a node.
      #
      # THE KEY SET IS DERIVED FROM System::Task::COMMANDS (IMP-944567d41689).
      # It used to be a hand-written list, and it had drifted THREE ways at
      # once: it declared 19 categories for commands the model REFUSES to insert
      # (provision, deprovision, the two public-IP verbs, the seven volume/
      # snapshot verbs, the two network verbs, sync, build_module,
      # commit_module, backup, restore, custom), it omitted 12 commands that are
      # real and in daily use (upgrade_boot_image, a2a_call, the seven storage.*
      # verbs, the two ci.* verbs, probe.module_smoke), and the engine's
      # registration + the seed's key set both inherited the drift because they
      # read this constant. A hand-synced list drifts again the next time a
      # command lands, which is exactly how it arrived here; deriving it means
      # a command cannot exist without an operator policy row, and a policy row
      # cannot exist for a command that does not.
      #
      # WHO THIS ACTUALLY GOVERNS — WIDER THAN "AN OPERATOR CLICKING A BUTTON".
      #
      # These rows are written at MANUAL_OPERATION_SCOPE, which is scope
      # "global" with ai_agent_id: nil. Two things follow, and the verbs below
      # were chosen against BOTH:
      #
      #   * Ai::InterventionPolicy#agent_matches? returns TRUE whenever
      #     ai_agent_id is nil, and InterventionPolicyService#resolve admits the
      #     scope-"global" audience for an AGENT caller by design (it is the
      #     account-wide floor; only scope "action_type" is operator-only). No
      #     agent-scoped row exists anywhere in the `system.task.*` namespace, so
      #     these ARE the rows an AI agent resolves against. "auto_approve" here
      #     means an agent — including one carrying a prompt injection — runs the
      #     command unattended with no human in the loop.
      #   * the payload is not vetted. TasksController#create permits
      #     `options: {}` — arbitrary JSONB, with no server-side validation of
      #     any storage/probe/build field — and hands it to the node agent, which
      #     interpolates it into systemd units, /etc/exports.d entries, curl
      #     arguments and find/chown arguments. Several handlers below are
      #     therefore ROOT-EQUIVALENT primitives on an arbitrary fleet node when
      #     driven by a hostile payload, whatever their names suggest.
      #
      # So the question each verb answers is NOT "is this routine when the
      # platform issues it?" — every in-process producer (ChownDispatchService,
      # NfsExportManager, SmbUserManager, GatewayProvisioningService,
      # AssignmentReconciliationService, BootImage::UpgradeDispatcher,
      # AgentFleetMissionService, ModuleSmokeProbe) calls System::Task.create!
      # directly and NEVER meets the gate, so the machine path is unaffected by
      # anything here. The only callers these verbs govern are the gate sites:
      # TasksController#create and NodeInstanceGating. For the handlers whose
      # payload is unvalidated, that means the only caller a loose verb serves is
      # the adversarial one — a permissive verb buys nothing operationally and
      # sells the whole node.
      #
      # WHAT A DECLARED ROW BUYS, AND WHAT IT COSTS. Absence resolves to
      # require_approval (Ai::InterventionPolicyService#default_policy), so a
      # declared require_approval is a NO-OP on resolution and only makes the
      # control tunable in the Autonomy modal (registration is derived from this
      # same constant — see lib/powernode_system/engine.rb). Any verb looser
      # than that is a WIDENING for an install PolicyReconciler converges, and
      # note that notify_and_proceed PROCEEDS: it is a widening too, not a
      # softer form of approval.
      MANUAL_OPERATION_DEFAULT_VERBS = {
        # --- Instance lifecycle (server-dispatched, ExecutionDispatcher::COMMAND_REGISTRY)
        "start" => "auto_approve",
        "stop" => "auto_approve",
        "restart" => "require_approval",        # unit-scoped: agent takes options["unit"] into systemctl as root; gate sites only, RestartAfterUpdate never meets the gate (IMP-0c1a7dca5781)
        "reboot" => "auto_approve",
        "terminate" => "require_approval",         # destroys the instance
        "sync_modules" => "auto_approve",
        "apply_config" => "notify_and_proceed",
        "ssh_command" => "require_approval",       # arbitrary code execution

        # --- Agent-delegated (ExecutionDispatcher::AGENT_DELEGATED_COMMANDS)
        #
        # Writes the target UKI to the ESP and runs `systemctl reboot`
        # (agent/internal/runtime/tasks/handlers/upgrade_boot_image.go). Not
        # permissive under any reading: the recovery path for a bad image is an
        # A/B boot-slot rollback, and on a self-hosted control plane the node
        # being rebooted may be the one serving the approval UI.
        "upgrade_boot_image" => "require_approval",

        # Drives a PEER instance: NodeInstancePeersController mints a capability
        # token and enqueues this; the callee verifies the token's Ed25519
        # signature before acting, so the payload cannot widen what the caller
        # was granted. It crosses an instance boundary rather than a privilege
        # one — proceeds, but an operator should see that it happened.
        "a2a_call" => "notify_and_proceed",

        # --- storage.* — READ THE AGENT HANDLERS, NOT THE NAMES.
        #
        # STATUS as of IMP-671662bfd2dd: the agent now validates every one of
        # these payloads at the actuator (agent/internal/taskguard +
        # agent/internal/storage/validate.go). The unit name must be a bare
        # `powernode-storage-*.mount`, every value interpolated into a unit body
        # or an /etc/exports line is refused if it carries a control character
        # or a space, and the chown/mount/export target is refused if it is, or
        # would mask, a critical system path.
        #
        # THE VERBS BELOW DO NOT CHANGE, and the descriptions are kept in the
        # past tense rather than deleted, because the guard ships in the AGENT
        # BINARY. That binary rolls out as a module overlay, per node, with no
        # coordination point — so an un-upgraded node still has every hole
        # described here. Relaxing any of these verbs needs evidence that the
        # fleet is fully upgraded, not just that this file was read.
        #
        # Five of these seven WERE unvalidated root primitives on the target
        # node. They are
        # require_approval for the same reason `ssh_command` is, and in three
        # cases they are a STRICTLY STRONGER primitive than ssh_command because
        # they do not announce themselves as remote execution.
        #
        # storage.mount WAS ARBITRARY ROOT CODE EXECUTION. agent/internal/
        # storage/systemd.go: `filepath.Join(SystemdUnitDir, task.UnitName)` then
        # os.WriteFile, `systemctl daemon-reload`, `systemctl start <UnitName>`.
        # UnitName was unsanitised, so the caller picked the filename under
        # /etc/systemd/system (traversal and overwrite included), and
        # renderMountUnit interpolates `strings.Join(task.Options, ",")` raw into
        # the unit body — a newline in one option injected arbitrary systemd
        # directives. Name the unit `*.service` and the injected
        # `[Service] ExecStart=` was what `systemctl start` then ran, as root.
        "storage.mount" => "require_approval",
        # WAS NOT storage-scoped. stopAndRemoveMountUnit runs `systemctl stop
        # <UnitName>` and deletes the unit file, and with an unsanitised
        # UnitName `powernode-<uuid>-rails.service` stopped the control plane and
        # removed its unit — a denial-of-service primitive over any unit on the
        # node, not an unmount. The prefix rule is what bounds it now, and it
        # matters more than the suffix rule: `persist.mount` and `sysroot.mount`
        # are real units on these nodes and end in ".mount".
        "storage.unmount" => "require_approval",
        # NOTHING BOUND THIS TO A SHARE. exports.go writes
        # `<ExportPath> <PeerIP>/128(<Options>)` into /etc/exports.d and runs
        # `exportfs -ra`; ExportPath, PeerIP and Options were all unvalidated, so
        # `export_path: "/"` with `no_root_squash` exported the node's root
        # filesystem, writable as root, to whatever peer the caller named — host
        # compromise, not an ACL edit. The subtler half was that a SPACE in
        # export_path made it two /etc/exports fields while still reading as one
        # path to any prefix check; that is now refused too. Note what is still
        # NOT bounded: the option list itself, so a caller who can issue this
        # can still name `no_root_squash` for the peer it names. (NfsExportManager#grant! and #revoke!
        # also both ride this one command, so one verb would govern widening and
        # narrowing even if the arguments were bounded.)
        "storage.exports.apply" => "require_approval",
        # samba-tool create / delete / set_password (SmbUserManager). Credential
        # lifecycle for a share principal — bounded to Samba's own user database
        # rather than to arbitrary node state, which is why this one stays a
        # notify rather than joining its five siblings above.
        "storage.smb_user.apply" => "notify_and_proceed",
        # WAS the same unvalidated-unit-name class as storage.mount (and is now
        # bounded by the same rules): ProvisionGateway
        # writes and starts a systemd unit whose name and body the caller
        # supplies. Root code execution by the same mechanism.
        # NOTE the asymmetry the rules preserve: re_export_path is a LOCAL path
        # and gets the critical-root denylist, while upstream_export_path names
        # a path on the remote NFS server and correctly does not.
        "storage.gateway.provision" => "require_approval",
        # Tears that gateway down, and every consumer mounted through it loses
        # its path at once — the widest blast radius of the seven even before
        # the unit-name problem.
        "storage.gateway.deprovision" => "require_approval",
        # Recursive `find <MountPath> -uid OLD -exec chown NEW`. chown.go used to
        # refuse ONLY "" and "/", so `mount_path: "/etc", old_uid: 0,
        # new_uid: <any>` was permitted and handed the node's configuration tree
        # to an unprivileged uid — privilege escalation, not a slow maintenance
        # job. "/etc" itself is now refused; /etc/nginx is not, because
        # System::Storage::MountPathInferenceService lists it as a supported
        # storage path owned by a service user.
        # The reversibility that makes the MACHINE path safe does not exist for
        # a caller this verb governs: chown_previous_uid/gid is recorded on a
        # StorageAssignment, and a hand-issued or agent-issued task has no
        # StorageAssignment at all, so there is nothing to reverse from.
        "storage.chown" => "require_approval",

        # --- ci.* — build on a LEASED module-forge builder. Not inert: the
        # build's TERMINAL step is a registry write. module-forge-build.sh
        # pushes UNSIGNED to the OCI registry under the caller-supplied OCI_REF
        # using the platform's ORAS credentials, and the content-addressed skip
        # path `oras tag`s an already-published artifact as OCI_REF — so the tag
        # is attacker-chosen either way. Two things bound it, and they are why
        # this is notify rather than require_approval: the agent gets 403 from
        # config/ci_build_context unless the instance is a module-forge builder
        # holding an active module_build lease, and the promote path filters to
        # the batch's own tracked_task_ids, so an injected batch_id cannot slip a
        # digest into a promote.
        "ci.module_build" => "notify_and_proceed",
        "ci.package_build" => "notify_and_proceed",

        # --- probe.* — the CHECK NAMES are allow-listed
        # (probeModuleSmokeChecks). Their ARGUMENTS were not, and as of
        # IMP-671662bfd2dd they are: the endpoint must be a relative path or an
        # http(s) URL, the method must be one of ModuleService::HEALTH_METHODS,
        # and the ldd candidate must be an absolute canonical path. A refused
        # argument fails ITS check rather than the task, so the probe keeps
        # reporting. What is still NOT bounded is the DESTINATION — the blind
        # SSRF / port-scan oracle below is unchanged, and re-deriving this verb
        # means deciding about that, not about the argument shapes. checkHealthEndpoint runs
        # `curl -X <method> <endpoint>` with both caller-supplied, from the
        # node's HOST network namespace, discarding the body and returning the
        # status code — an arbitrary-verb HTTP request plus a blind SSRF and
        # port-scan oracle against anything the node can reach. checkLddClosure
        # runs `chroot /sysroot ldd <path>` on a caller-supplied path.
        #
        # It stays auto_approve anyway, and the reasoning is the bound, not the
        # name: every one of those primitives is strictly weaker than what the
        # allow-listed check set already grants, none of them WRITES, and the
        # three checks cannot be extended by payload. A caller who can issue
        # this can read status codes and linker output — not change node state.
        # If a fourth check is ever added, re-derive this verb before shipping it.
        "probe.module_smoke" => "auto_approve"
      }.freeze

      # Fail-safe for a command added to System::Task::COMMANDS without a verb
      # above. It matches what absence already resolves to, so an undeclared
      # command behaves exactly as it does today rather than crashing boot —
      # and the registration spec is what forces the decision to be made.
      MANUAL_OPERATION_FALLBACK_VERB = "require_approval"

      # LOAD-TIME DEPENDENCY, stated because its failure mode is silent. This
      # class body now references ::System::Task, so PolicyDeclarations cannot
      # load unless the model does. The engine reads this constant from inside
      # a block that rescues StandardError into a `Rails.logger.warn`
      # (lib/powernode_system/engine.rb), so a System::Task that failed to
      # autoload there would not raise — it would leave EVERY extension
      # action_category unregistered, with one warn line as the only evidence,
      # and PATCH /api/v1/system/autonomy refusing every operator edit.
      # The vacuity guard in
      # spec/lib/powernode_system/system_task_category_vocabulary_spec.rb
      # ("has real inputs on both sides") is what catches that state: an empty
      # registry fails it rather than passing both set-difference examples.
      MANUAL_OPERATION_POLICIES = ::System::Task::COMMANDS.to_h { |command|
        [ "system.task.#{command}",
          MANUAL_OPERATION_DEFAULT_VERBS.fetch(command, MANUAL_OPERATION_FALLBACK_VERB) ]
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

      # ================================================================
      # WHO GATES A SENSOR-ROUTED ROW (HIER-P2A)
      # ================================================================
      # Every sensor still runs on the Fleet Autonomy tick
      # (FleetAutonomyService::SENSORS), but a decision is no longer gated
      # against the agent RUNNING that tick. Each DecisionEngine::SIGNAL_BINDINGS
      # entry declares the `owner:` of its action_category — an
      # AGENT_IDENTITIES source_key, default "fleet-autonomy" — and the tick
      # resolves that agent (FleetAutonomyService#for_owner, override-aware, the
      # same resolution PolicyReconciler uses so rows land where the gate
      # looks) and gates the decision under it: policy lookup, approval chain,
      # executor agent, event attribution and the agent_id on the
      # ApprovalRequest all follow the owner. A missing owner falls back to
      # Fleet Autonomy with a WARN event.
      #
      # THE INVARIANT, pinned by
      # spec/services/system/fleet/sensor_owner_gating_spec.rb: a binding's
      # owner IS the agent whose agent-scoped set below declares its
      # action_category (`PolicyDeclarations.owner_of`). Declaring a category on
      # one agent and gating it under another is the old defect — a row the
      # tick never reads — one layer over.
      #
      # So the mechanical reason the 14 system.sdwan_* / system.federation_*
      # remediation rows, system.gitops_drift_remediate and
      # system.disk_image_publication_investigate all had to sit in this set
      # ("gate_action! resolves policies against the agent running the tick")
      # is gone, and they now live on SDWAN Manager, GitOps Reconciler and
      # Disk Image Manager respectively. PolicyReconciler RE-HOMES an existing
      # row whose declared owner changed (ai_agent_id updated in place, verb /
      # is_active / conditions / priority preserved, audit row written) rather
      # than creating a fresh one and leaving the tuned one stale.
      #
      # HIER-P2DECL (Phase 2 wave 1, operator rulings 2026-09-03) LIFTED the
      # named groups P2A left here onto their own agents: CAPACITY_POLICY_KEYS
      # → Capacity Manager, STORAGE_POLICY_KEYS → Storage Manager,
      # INGRESS_POLICY_KEYS → Ingress Manager, SUPPLY_CHAIN_POLICY_KEYS →
      # Supply Chain Manager, and the topology pair → System Topology
      # Designer (see the wave-1 block below PROVISIONING_CONDITION_OVERRIDES).
      # The groups stay as named constants so each agent set reads as "the
      # group plus what else it took", and the verbs did not move with the
      # owner. The agents are SEEDED in wave 2; until then their sets skip in
      # PolicyReconciler ("agent absent") and the fleet tick gates their
      # bindings under Fleet Autonomy with a fleet.owner_agent_missing event
      # (FleetAutonomyService#for_owner) — where an established install still
      # holds the rows, because the reconciler moves nothing off a former
      # owner until the new one exists.

      # Capacity-shaped node-lifecycle keys: the DR replace/reap pair, the two
      # cost-bearing expansions, and workload relocation. instance_reboot /
      # _reprovision / _terminate stay in the Fleet Autonomy literal below —
      # they are remediation lanes for a silent or compromised instance, not
      # capacity. Owned by the Capacity Manager since HIER-P2DECL
      # (CAPACITY_MANAGER_POLICIES); the instance_unrecoverable binding
      # declares that owner.
      CAPACITY_POLICY_KEYS = {
        # IMP-e2f53e87d090 (APO-2b) — the disaster-recovery lane.
        # InstanceUnrecoverableSensor emits system.instance_unrecoverable for a
        # silent instance a reboot demonstrably cannot recover (the VM is
        # terminated/error at the provider, every connection to its host is
        # unusable, or the reboot lane's outcomes already scored ineffective).
        # It is a SEPARATE category from system.instance_reprovision on
        # purpose: both are require_approval today, but they are separately
        # tunable operator decisions and collapsing them would put "reboot it"
        # and "throw it away and build another" behind one row.
        #
        # require_approval, and it should stay that way now that a replace
        # APPLIER exists (IMP-555db48d41f1 / APO-4 —
        # System::Ai::Skills::ReplaceInstanceExecutor, named by the
        # DecisionEngine binding). The reasoning inverted with the actuator:
        # this row used to hold the lane shut because nothing would have run,
        # and now holds it shut because something will. The category came OUT
        # of RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES in the
        # same change — a lane that actuates must be scored.
        "system.instance_replace"        => "require_approval",
        # IMP-555db48d41f1 (APO-4, DR-1) — the DESTRUCTIVE half of a replace,
        # split out so it can be refused while the additive half proceeds.
        # This is the action_category of a CLASS of its own,
        # System::Ai::Skills::ReapInstanceExecutor: the replace executor has no
        # terminate call site at all, and hands the reap to Ai::AutonomyGate
        # under THIS category, which parks a resumable row and replays the reap
        # executor when a person releases it. The class split is what makes the
        # split gate real — a flag on the replace executor would have resolved
        # the REPLACE category (BaseSkillExecutor gates on one category per
        # class), so this row would have governed nothing. No signal binding
        # routes it, so it is not in System::Autonomy::ActionCategoryRouter's
        # routed set — the row exists so the terminate is an operator-visible,
        # separately tunable control rather than an unrowed default.
        "system.instance_reap"           => "require_approval",
        "system.region_expansion"        => "require_approval",
        "system.capacity_resize"         => "require_approval",
        "system.relocate_workload"       => "require_approval"
      }.freeze

      # Owned by the Storage Manager since HIER-P2DECL (STORAGE_MANAGER_POLICIES,
      # with the snapshot delete beside them); the storage_assignment_drift
      # binding declares that owner. No binding routes system.restore_volume —
      # it is a gated executor category (RestoreVolumeExecutor).
      STORAGE_POLICY_KEYS = {
        # Stale storage assignment re-reconciliation (StorageAssignmentDriftSensor,
        # audit F3-07). notify_and_proceed: it re-runs the same reconciliation the
        # assignment's own after_commit would — reversible and low blast radius —
        # but the operator should see that the safety net is firing.
        "system.storage_assignment_reconcile" => "notify_and_proceed",
        "system.restore_volume"               => "require_approval"
      }.freeze

      # === Gated skill executors (APO-1c, IMP-7e2bdc1774e4) ==================
      # Every executor declaring `requires_approval: true` resolves one of
      # these before #perform, on MCP, REST and Concierge alike. Seeded at
      # the SAME verdict the resolver would default to for an unseeded
      # category (require_approval), so landing these rows changes no
      # behaviour: it makes the verdict VISIBLE in the Autonomy modal and
      # TUNABLE through PATCH /api/v1/system/autonomy, and satisfies
      # routed_lane_policy_coherence_spec — BaseSkillExecutor is a declared
      # ActionCategoryRouter, so its categories are routed categories.
      #
      # Owned by the Ingress Manager since HIER-P2DECL (INGRESS_MANAGER_POLICIES,
      # with system.service_backends_update beside them). NO SIGNAL_BINDINGS
      # entry routes to any of these: they gate the executor / MCP doors only
      # (sensor_owner_gating_spec asserts that rather than assuming it), so the
      # Ingress Manager owns rows but, today, no sensor lane.
      INGRESS_POLICY_KEYS = {
        "system.acme_certificate_provision" => "require_approval",
        "system.expose_service_local"       => "require_approval",
        "system.expose_service_public_tcp"  => "require_approval",
        "system.expose_service_publicly"    => "require_approval"
      }.freeze

      # Owned by the Supply Chain Manager since HIER-P2DECL
      # (SUPPLY_CHAIN_MANAGER_POLICIES is exactly this group); the
      # package_drift_pressure binding declares that owner. The architecture
      # rows gate the executor door only.
      SUPPLY_CHAIN_POLICY_KEYS = {
        # Package repository ingestion. Sync is routine + reversible (just
        # refreshes cached metadata); module creation is supply-chain critical
        # (operator audits each new package entering the fleet). The refresh row
        # is DECLARED BUT UNREAD today: no DecisionEngine binding routes a signal
        # to system.package_module.refresh (system.package_drift_pressure routes
        # to package_repository.sync), and the only caller of
        # PackageModuleRefreshExecutor is CveRemediationOrchestrationExecutor
        # #dispatch_refreshes, which invokes it directly under the CVE lane's own
        # gate. There is no CVE-flagged/non-CVE split anywhere — that claim was
        # aspirational prose. The row stays so a future sensor-routed refresh
        # lane starts at require_approval rather than the unmatched default.
        "system.package_repository.sync" => "auto_approve",
        "system.package_module.create"   => "require_approval",
        "system.package_module.refresh"  => "require_approval",

        # Architecture catalog. Propose auto-approves at the policy layer
        # because the Ai::AgentProposal it creates is itself the human-review
        # gate. Direct CRUD requires approval — even with system.architectures.manage,
        # mutating the catalog surfaces for operator confirmation because it
        # affects every account's available platforms.
        #
        # ABSENT and must not be re-added (IMP-51e5c6184ae4, IMP-2effedffc990):
        # system.architecture_create / _update / _delete and
        # system.package_module_create. Those four were the DERIVED
        # "<domain>.<skill name>" categories of gated executors, seeded beside
        # the dotted rows the same executors' actions already had. Two rows
        # over one action are two controls: an operator who tuned the dotted
        # one did not tune the executor's gate. The executors now DECLARE
        # `action_category:` on the dotted spelling, so there is nothing left
        # to seed — see
        # spec/lib/powernode_system/autonomy_category_spelling_uniqueness_spec.rb.
        "system.architecture.propose" => "auto_approve",
        "system.architecture.create"  => "require_approval",
        "system.architecture.update"  => "require_approval",
        "system.architecture.delete"  => "require_approval"
      }.freeze

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

        # IMP-3855ff9908f2 — ModuleVerifyFailedSensor (module_verify_failed +
        # module_verify_not_measured): the agent's OBSERVED answer to "does this
        # node actually provide what the module declares", which nothing produced
        # before this.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be
        # none — a failed probe means the node's filesystem or PATH disagrees with
        # the manifest (a wrong artifact, a shadowing package, a profile script
        # reordering PATH), and re-serving the same module fixes none of them. In
        # the gitleaks v4 incident the artifact the platform would re-serve was the
        # empty one. "Proceed" means "notify the operator". Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a human changes an artifact or an image.
        #
        # TRAP, if you add another notify-level category: a lane that PROCEEDS
        # but never actuates (skill: nil in SIGNAL_BINDINGS, no
        # REMEDIATION_APPLIERS entry) opens a pending RemediationOutcome for
        # every proceeded decision, and nothing ever clears it — the triggering
        # condition ends when a person acts, not inside the 90s SETTLE_WINDOW —
        # so it scores ineffective every window until the F3-11 streak
        # manufactures a FALSE fleet.remediation_stuck HIGH escalation and forces
        # require_approval on a lane that never acted. Membership in
        # NON_REMEDIATING_ACTION_CATEGORIES is DECLARED, never inferred, so a new
        # notify-only category must be added by hand or it ships this failure
        # mode. The equality oracle in
        # spec/services/system/fleet/proceed_lane_actuation_spec.rb refuses a
        # silent lane in either direction.
        "system.module_verify_investigate" => "notify_and_proceed",

        # IMP-a8f9fa74284d — BootLkgArmSensor (node_lkg_unarmed +
        # node_lkg_stale): whether a live node is armed with a valid
        # last-known-good composition. System::BootLkgStateWriter has derived
        # that answer on every heartbeat since IMP-b8d5cfa33b79 and nothing
        # asked.
        #
        # notify_and_proceed, never auto_approve: there is NO applier and can be
        # none — the LKG is frozen on the node's own disk by the agent at boot,
        # and nothing the platform dispatches re-arms it. "Proceed" means
        # "notify the operator", who restores or re-captures it. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a person acts — and on a fleet still running
        # pre-boot/LKG agents it stands indefinitely.
        "system.node_lkg_investigate" => "notify_and_proceed",

        # StuckTaskBacklogSensor — "tasks are piling up behind the janitor".
        #
        # notify_and_proceed, never auto_approve: there is no applier and can be
        # none. The causes are an empty scope, a stopped worker, a broken seam — none
        # repairable by anything the platform can dispatch. "Proceed" means "reach an
        # operator". Also in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES,
        # because the fingerprint stands until a person fixes the janitor.
        "system.task_backlog_investigate" => "notify_and_proceed",

        # ModulePromotionBacklogSensor — "a newer usable version exists and the
        # fleet is still running the old one".
        #
        # notify_and_proceed, never auto_approve, and there is deliberately no
        # applier — promoting the stalled version is precisely what a gate, a
        # broken publish chain or a deliberate hold has already declined to do.
        # What the notify verb actually buys is a SEPARATELY TUNABLE, operator-
        # facing policy row (this constant is also what registers the category
        # for the Autonomy modal) rather than folding the stall into the silent
        # auto-approved bucket. Be precise about the rest: gate_action!'s extra
        # step for this verb is FleetAutonomyService#notify_action, which writes
        # a durable NOTIFY_EVENT_KIND FleetEvent plus a Rails.logger line — it
        # is not an operator page. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a person promotes, withdraws or fixes it.
        "system.module_promotion_investigate" => "notify_and_proceed",

        # Read/notify
        "system.module_assign"           => "notify_and_proceed",
        "system.instance_reboot"         => "notify_and_proceed",

        # Sensitive — require_approval
        "system.instance_reprovision"    => "require_approval",
        "system.instance_terminate"      => "require_approval",
        "system.replica_promote"         => "require_approval",
        "system.cert_revoke"             => "require_approval",
        "system.module_promote_to_live"  => "require_approval",
        "system.fleet_rolling_upgrade"   => "require_approval",
        # Campaign 019f505f inc 4 — BootImageDriftSensor → BootImageDriftRolloutExecutor.
        # Declared on Fleet Autonomy, not Disk Image Manager: a fleet-wide
        # in-place reboot rollout is a fleet operation, and high blast radius →
        # require_approval; the executor plans canary-first and dispatches the
        # batch on approval.
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

        # Stale BGP observations are pure observation — no remediation; the
        # `observation` action_category collects them for dashboards without
        # entering the approval pipeline. Several SDWAN sensors route their
        # observation-only kinds here (sdwan_bgp_session_stale,
        # sdwan_credential_refresh_stalled) while their remediation kinds gate
        # under SDWAN Manager — ownership follows the CATEGORY, not the sensor.
        "system.observation"             => "auto_approve",

        # IMP-4019664a524b — CapabilityGapSensor. require_approval is the
        # disposition, not a placeholder: the gap's only remediation is
        # AUTHORING a module, which must pass the R1/R2/R3 reuse gate
        # (docs/runbooks/module-authoring.md Phase 0), so the operator queue IS the
        # destination. It also keeps #decide at :pending, which RemediationValidator
        # never snapshots — a gap that stands until someone ships a module would
        # otherwise score ineffective forever and trip a false remediation_stuck.
        "system.capability_gap_review" => "require_approval",

        # Gated skill executor (APO-1c) that is neither ingress nor supply
        # chain nor topology — see INGRESS_POLICY_KEYS for the rationale. The
        # other two of the old "neither" trio (system.multi_tenant_isolation,
        # system.service_discovery_compose) are Topology Designer composer
        # skills and moved to TOPOLOGY_DESIGNER_POLICIES at HIER-P2DECL;
        # system.service_backends_update moved to INGRESS_MANAGER_POLICIES.
        "system.fulfill_capability_request" => "require_approval"
      }.freeze

      # The AUTONOMOUS SDWAN / federation remediation rows, gated under SDWAN
      # Manager by the fleet tick (the sensors run on Fleet Autonomy's tick; the
      # bindings declare `owner: "sdwan-manager"` — see the note above
      # CAPACITY_POLICY_KEYS). Agent set ONLY — but be precise about WHY, because
      # the rule does not generalise from the shape: 13 of the 14 are
      # sensor-routed, so no operator door issues them at all. The 14th,
      # system.federation_acceptance, has NO SIGNAL_BINDINGS entry and no sensor
      # — it is an operator/Concierge-driven gated skill executor
      # (FederationAcceptanceExecutor) grouped here because it is SDWAN-domain,
      # and seeded agent-shape because the agent that ACTS on it is the SDWAN
      # Manager. "Sensor-routed ⇒ agent shape only" is therefore not a rule you
      # can apply in reverse when deciding whether a new member needs an
      # operator row.
      #
      # HISTORY. These lived on the SDWAN Manager seed in the 2026-05-10 split,
      # were MOVED to Fleet Autonomy because #gate_action! resolved every policy
      # against the agent running the tick (a row here was silently
      # 'not_permitted' in the sensor path), and moved BACK here in HIER-P2A once
      # the tick learned to gate each binding under its declared owner. Verbs are
      # unchanged across all three moves. IMP-17bc5546009a: a 7th early member,
      # system.sdwan_route_policy_audit, was DELETED outright (2026-08-21) — no
      # sensor emitted it, no binding routed to it, no executor carried it.
      SDWAN_REMEDIATION_POLICIES = {
        # Phase 3 (Federation & Multi-Site) — federation peer liveness remediation
        # (FederationPeerLivenessSensor → system.federation_peer_remediate).
        # Re-handshake / degrade / alert is low-to-medium blast radius and the
        # dedup TTL self-throttles repeat firings → notify_and_proceed.
        "system.federation_peer_remediate" => "notify_and_proceed",

        # Phase 3 (SDWAN autonomous remediation). Autonomy levels preserved from
        # the original SDWAN Manager seed.
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
        "system.sdwan_credential_refresh"    => "notify_and_proceed",

        # The four notify-only SDWAN investigate lanes. Each PROCEEDS but never
        # actuates (skill: nil, no REMEDIATION_APPLIERS entry), so each is also
        # listed in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES —
        # see the TRAP note on system.module_verify_investigate in
        # FLEET_AUTONOMY_POLICIES for why that membership is load-bearing.
        #
        # IMP-c7d663f24a0b — SdwanServiceHealthSensor (sdwan_service_silent +
        # sdwan_portmap_orphaned). Notify-level first, no auto-remediation until
        # the signal quality is proven in the field.
        "system.sdwan_service_health_investigate" => "notify_and_proceed",
        # IMP-57e9a90598ee — SdwanOvnDeploymentHealthSensor (ovn deployment
        # degraded / activation stalled). NO applier by design — the degraded
        # component is the operator's own OVN control plane (northd, NB/SB DBs),
        # which the platform does not provision — so "proceed" means "notify the
        # operator" and nothing else.
        "system.sdwan_ovn_deployment_investigate" => "notify_and_proceed",
        # IMP-2f34679b6b73 — SdwanBgpSessionHealthSensor's attribution family (a
        # BGP report the platform could not attribute to the network it arrived
        # under, or one the agent disclaimed). The condition is an ABSENCE of a
        # measurement; the point of surfacing it is that an operator learns the
        # host is running an agent that polls FRR without naming a VRF.
        "system.sdwan_bgp_observation_investigate" => "notify_and_proceed",
        # IMP-da1b772c2596 — SdwanApplyHealthSensor (sdwan_apply_failed +
        # sdwan_apply_not_measured): the agent's OBSERVED per-subsystem apply
        # outcome. NO applier and can be none — a failed apply is a kernel-side
        # refusal the agent already retries on every tick, so re-serving the same
        # config remediates nothing.
        "system.sdwan_apply_investigate" => "notify_and_proceed",
        # IMP-7034199a5a19 — SdwanUserDeviceConfigStalenessSensor. An issued user
        # device's config is rendered once and never re-pulled, so a VIP, a peer
        # lan_subnet, or a federation prefix added afterwards is missing from
        # every config already in the field. NO applier and can be none — the
        # drifted artefact is a text file on a user's laptop; the operator
        # re-issues the device.
        "system.sdwan_user_device_config_investigate" => "notify_and_proceed",

        # Gated skill executor (APO-1c, IMP-7e2bdc1774e4) — cross-instance
        # peering acceptance is always sensitive; seeded at the resolver's own
        # unseeded default so landing the row changes nothing but visibility.
        "system.federation_acceptance"      => "require_approval"
      }.freeze

      # Operator-initiated sdwan.* CRUD. This table is seeded TWICE, against two
      # different audiences: once agent-scoped as part of SDWAN_MANAGER_POLICIES
      # (what an agent dispatch resolves against) and once agent-less as the
      # "sdwan-operator" set (what an operator HTTP request resolves against —
      # see the operator upsert in db/seeds/system_sdwan_manager_agent.rb). The
      # verbs below are the single recorded intent for both — do not fork them.
      # The remediation rows above are NOT part of the operator audience.
      SDWAN_OPERATOR_POLICIES = {
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

      # The SDWAN Manager AGENT set: operator CRUD + the sensor-routed
      # remediations. 57 keys. POLICY_SETS binds this at scope "agent" and
      # SDWAN_OPERATOR_POLICIES alone at scope "action_type".
      SDWAN_MANAGER_POLICIES = SDWAN_OPERATOR_POLICIES.merge(SDWAN_REMEDIATION_POLICIES).freeze

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
        "system.disk_image_webhook_rotate_secret" => "notify_and_proceed", # invalidates old, but recoverable

        # DK3 of the disk-image-CI restoration — DiskImagePublicationFailureStreakSensor
        # (a platform whose last N publications all failed). The sensor runs on
        # Fleet Autonomy's tick, and its binding declares `owner:
        # "disk-image-manager"`, so the tick gates it HERE (HIER-P2A; it was
        # declared on Fleet Autonomy while the tick could only gate as the
        # agent running it). notify_and_proceed: no auto-remediation exists (a
        # broken CI pipeline needs operator investigation), this only surfaces
        # the streak; deduped per-platform via the sensor's fingerprint. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES.
        "system.disk_image_publication_investigate" => "notify_and_proceed"
      }.freeze

      # system.gitops_apply_proposal is EVALUATED by Ai::Tools::SystemFleetTool's
      # declare_action on system_gitops_apply_proposal (IMP-0b4f18ae4384) —
      # the verb parks through Ai::AutonomyGate on the generic replay
      # executor. Until that declaration it was decoration: a row an operator
      # could read and tune that no gate ever consulted. This set is written
      # at scope "agent" against the GitOps Reconciler, so it binds only a
      # call made AS that agent — and the reconciler's own auto_apply lane
      # calls System::Gitops::ApplyService directly rather than the MCP verb,
      # so in practice every caller that meets the new gate (an operator, or
      # any other agent) resolves the unmatched default, which is
      # require_approval. Tuning this row is therefore not yet the operator
      # control it reads as; an operator-shape (scope "global") set is the
      # follow-up. The two siblings are declared `mutating:` only and meet no
      # gate.
      #
      # system.gitops_drift_remediate is the AUTONOMOUS row: GitopsDriftSensor
      # runs on Fleet Autonomy's tick and its binding declares `owner:
      # "gitops-reconciler"`, so the tick gates it HERE (HIER-P2A; it was
      # declared on Fleet Autonomy while the tick could only gate as the agent
      # running it). notify_and_proceed: drift is informational (the reconciler
      # opens proposals for the actual apply); without this binding the signal
      # was classified :skipped and never reached the operator. Deduped per
      # repo+revision fingerprint, so a standing drift notifies once per TTL.
      GITOPS_RECONCILER_POLICIES = {
        "system.gitops_apply_proposal"      => "require_approval",  # applies a diff to live fleet state
        "system.gitops_register_repository" => "require_approval",  # adds a new declarative source of truth
        "system.gitops_sync_repository"     => "auto_approve",      # read-side: refresh the diff, no mutation
        "system.gitops_drift_remediate"     => "notify_and_proceed" # sensor-routed drift notification
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

      # IMP-24daa05e7a22 — `_ceiling_raise` and `_archive` are the two PATCH
      # transitions Api::V1::System::InstancePoolsController#update gates. They
      # are separate categories rather than a single "update" row because they
      # are separate operator decisions with different blast radius: one commits
      # spend the (deliberately ungated) replenish tick will then make, the
      # other reaches the state the GATED destroy's on_proceed writes. An
      # operator relaxing one must not relax the other, which one shared row
      # could not express.
      #
      # `_update` stays declared and stays UNREAD by any gate site: every other
      # PATCH transition — decreases, min_size, description, regions, metadata,
      # status paused/draining — is applied inline by operator direction. It is
      # censused as such in spec/lint/instance_pool_replenish_gating_spec.rb.
      INSTANCE_POOL_POLICIES = {
        "system.instance_pool_create"        => "require_approval",   # capacity commitment
        "system.instance_pool_update"        => "notify_and_proceed", # changes pool size targets
        "system.instance_pool_ceiling_raise" => "require_approval",   # raises target/max — commits spend
        "system.instance_pool_archive"       => "require_approval",   # PATCH twin of the gated destroy
        "system.instance_pool_delete"        => "require_approval",   # removes pool + ready instances
        "system.instance_pool_replenish"     => "auto_approve",       # tops up to target — routine
        "system.instance_pool_drain"         => "require_approval",   # halts replenishment
        "system.instance_pool_acquire"       => "auto_approve"        # claim a ready member — fast path
      }.freeze

      # IMP-5a2b801f3386 — DELIBERATELY THE GATED SUBSET, NOT ALL EIGHT.
      #
      # The operator set below seeds rows at (scope "global", ai_agent_id nil):
      # the shape an agent-less caller resolves, and the shape the Autonomy
      # modal renders. A row here for a category NO gate site passes is a
      # control an operator can edit that changes nothing — the defect
      # RUNTIME_OPERATOR_GATED_KEYS was introduced to prevent
      # (IMP-9b9653e6514e), and `system.instance_pool_drain` was its sharpest
      # form: declared require_approval, so the operator was shown an approval
      # requirement no code path enforces.
      #
      # The four listed are the four an InstancePoolsController gate site
      # passes to Ai::GatedActions — `_create` (#create), `_delete` (#destroy)
      # and `_ceiling_raise` / `_archive` (#update's GATED_UPDATE_CATEGORIES).
      # The other four — `_acquire`, `_drain`, `_replenish`, `_update` — have
      # no gate site and so get no operator row; they resolve to
      # Ai::InterventionPolicyService's require_approval default on that path,
      # which is the honest answer for an action no gate consults, and they
      # stay REGISTERED (registration in the engine unions every set, and the
      # agent set below still declares them) so an operator-authored row for
      # one still validates.
      #
      # `_replenish` staying ungated is a recorded DECISION, not an omission —
      # see System::Executors::InstancePool::ReplenishPool and the census in
      # spec/lint/instance_pool_replenish_gating_spec.rb. Gaining a gate site
      # for any of the four is what puts it back in this list; both halves are
      # pinned by spec/db/seeds/system_instance_pool_operator_policies_spec.rb.
      #
      # WITHDRAWING A DECLARATION DOES NOT DELETE A ROW. This is forward-only:
      # db:seed runs on first boot only, so an install that has already booted
      # keeps the four rows its first boot wrote, and its operator still sees
      # `_drain` advertising an approval nothing enforces. No RECURRING sweep
      # collects them, by design and not by oversight — PolicyReconciler is
      # create-only ("reconcile ABSENCE ONLY ... never delete": at this shape
      # it cannot tell a stale seeded row from an operator's tuning),
      # clean_stale_operator_policies! keys on scope "action_type" rather than
      # "global", and clean_unregistered_policies! collects only DEREGISTERED
      # categories — these four stay registered via the agent set below, which
      # is correct. The bounded ONE-SHOT collection that question came down to
      # (improvement 01a063db-c869-7117-b7f6-f88b7061ab4a) has been taken:
      # db/migrate/20260903033000_collect_inert_instance_pool_operator_policies.rb
      # (IMP-57a4b1ef94b3) deletes the four inert global-scope rows once on
      # every install that boots past it; an operator who deactivated one by
      # hand beforehand lost nothing, since the row was equally inert.
      #
      # The AGENT set is untouched and keeps all eight: the agent's own
      # dispatch vocabulary is a different audience on a different path. That
      # agent is the Capacity Manager since HIER-P2DECL (the whole of
      # INSTANCE_POOL_POLICIES is merged into CAPACITY_MANAGER_POLICIES; the
      # "instance-pool-agent" set on Fleet Autonomy is gone, and this operator
      # set is its declared twin — OPERATOR_TWINS). Which keys an AGENT path
      # actually reads: the four gated ones through Ai::GatedActions when the
      # caller is an agent principal, and `_acquire` / `_replenish` through
      # System::Executors::InstancePool when Fleet-side capacity work runs as
      # that agent; no SIGNAL_BINDINGS entry routes to any of them.
      INSTANCE_POOL_OPERATOR_GATED_KEYS = %w[
        system.instance_pool_create
        system.instance_pool_delete
        system.instance_pool_ceiling_raise
        system.instance_pool_archive
      ].freeze

      INSTANCE_POOL_OPERATOR_POLICIES =
        INSTANCE_POOL_POLICIES.slice(*INSTANCE_POOL_OPERATOR_GATED_KEYS).freeze

      PROVISIONING_POLICIES = {
        "project.adapt" => "notify_and_proceed",
        "project.cost_control" => "notify_and_proceed",
        "project.scale_horizontal" => "auto_approve",
        "project.relocate" => "require_approval",
        "project.schema_change" => "require_approval",
        "project.security_change" => "require_approval"
      }.freeze

      # IMP-8c0f0fe9a8cf (APO-3b) — the two halves of PlatformDeployment
      # replica reconciliation (System::Platform::ReplicaReconciler). Both
      # categories have a resolving site in that service; a category the
      # reconciler never resolves would render an operator control that
      # governs nothing — the defect RUNTIME_OPERATOR_GATED_KEYS below exists
      # to avoid.
      #
      # Scale-OUT (IMP-f986d379120a, bulk review ruling D16) is
      # auto_apply_within_bounds: the row auto-executes, and the reconciler
      # pairs that verdict with the deployment's DECLARED window
      # (System::PlatformDeployment#scaling_bounds — metadata → account →
      # SiteSetting, fail-closed to "no ceiling"), applying only when the
      # target sits inside it and PARKING otherwise. The same pairing
      # `project.scale_horizontal` uses on the project side. It used to run on
      # the caller's authority with no category at all, matching the
      # platform_deploy precedent; the window is what makes an auto-executing
      # row safe to seed, because an install that declares no ceiling gets no
      # unattended scale-out from this row.
      #
      # Scale-IN terminates instances, which is not reversible, so the
      # reconciler resolves this category before actuating and removes nothing
      # unless the verdict auto-executes. require_approval is a NO-OP on
      # resolution (it is also the absent-row default), so the row buys exactly
      # one thing: the control is REAL and retunable in the Autonomy modal
      # rather than a verdict with nothing behind it. Registration for that
      # modal is derived from POLICY_SETS in the engine initializer, so this
      # declaration is the only edit either category needs.
      #
      # Global scope, no agent, for the OPERATOR row: the reconciler is reached
      # from the operator's Concierge-bound platform_resilience skill and the
      # Scaling panel, not from a monitor agent's tick. Since HIER-P2DECL the
      # pair is ALSO declared on the Capacity Manager's agent set
      # (CAPACITY_MANAGER_POLICIES; this set is its twin — OPERATOR_TWINS): the
      # agent row resolves only when the reconciler is invoked AS that agent
      # (an executor bound to it in wave 2), and no SIGNAL_BINDINGS entry
      # routes to either key. The operator row stays the one an operator tunes.
      PLATFORM_SCALING_POLICIES = {
        "system.platform.scale_out" => "auto_approve",
        "system.platform.scale_in" => "require_approval"
      }.freeze

      # IMP-e025722ef14e (APO-5 remainder) — snapshot DELETE is approval-gated.
      #
      # `system_delete_volume_snapshot` destroys a restore point. APO-5
      # (IMP-4b4bed6967ed) shipped it behind the system.volumes.delete
      # permission ALONE and stated the deferral at its declaration, because
      # this file belonged to another lane that batch and a guessed category
      # is not inert: an unmatched one resolves to the default
      # require_approval with no operator-visible row to tune. The category
      # and the gate (SystemFleetTool's declare_action quartet on
      # Ai::Executors::DeferredToolCall) land in ONE change, as the operator
      # direction asked.
      #
      # OPERATOR (global) shape, like the instance-pool operator set: the MCP
      # verb is called by a user or an agent, and Ai::InterventionPolicyService
      # resolves both against scope-"global" rows ("Agent-BINDING by design").
      # It is NOT in FLEET_AUTONOMY_POLICIES. Since HIER-P2DECL it is also
      # declared on the Storage Manager's agent set (STORAGE_MANAGER_POLICIES;
      # this set is its twin — OPERATOR_TWINS, operator ruling: every
      # operator-only set gets an agent twin). What reads the agent row today:
      # the MCP verb when the caller is an agent principal (the Storage
      # Manager, once wave 2 binds it). No SIGNAL_BINDINGS entry routes to it
      # yet — the snapshot schedule sensor (improvement
      # 01a065df-4ab7-7a04-8293-8069d805b0b1) must ask THIS category when it
      # lands, so one row governs a delete whichever door it arrives through
      # (System::VolumeManagementService.snapshot_schedule_for).
      #
      # BOTH WRITERS, as for the instance-pool operator set: declaring here
      # makes the gate resolve, but the row an operator actually tunes is
      # written by db/seeds/system_volume_snapshot_policies.rb on a first boot
      # and by PolicyReconciler on an install that had already booted. The
      # declared verb EQUALS the unmatched default, so the discriminating
      # oracle for "is the control there" is the resolved RECORD, not the
      # resolved verb — see
      # spec/db/seeds/system_volume_snapshot_operator_policies_spec.rb.
      VOLUME_SNAPSHOT_OPERATOR_POLICIES = {
        "system.volume_snapshot_delete" => "require_approval" # destroys a restore point
      }.freeze

      # IMP-0467eee9fc57 — the cordon-only (unschedulable) mode for a
      # NodeInstance, gated by Ai::Tools::SystemFleetTool's
      # system_cordon_instance AND system_uncordon_instance under ONE category:
      # the same operator control governs taking a node out of scheduling and
      # putting it back (an agent re-admitting a node an operator cordoned for
      # maintenance is the ops-hold lesson — a hold that lifts itself is
      # worse than no hold). require_approval by operator direction: a cordon
      # removes capacity from every pool consumer at once and the replenisher
      # spends to backfill it. GLOBAL (operator) scope like the snapshot set —
      # no sensor lane routes it; since HIER-P2DECL the key is also on the
      # Capacity Manager's agent set (CAPACITY_MANAGER_POLICIES, this set's
      # twin), read only when the cordon verb is called AS that agent. The
      # operator row is written by
      # db/seeds/system_instance_cordon_policies.rb on a first boot and by
      # PolicyReconciler on an install that had already booted; as with the
      # snapshot set the declared verb EQUALS the unmatched default, so the
      # oracle for "is the control there" is the resolved RECORD — see
      # spec/db/seeds/system_instance_cordon_operator_policies_spec.rb.
      INSTANCE_CORDON_OPERATOR_POLICIES = {
        "system.instance_cordon" => "require_approval" # takes capacity out of / back into scheduling
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

      # ================================================================
      # PHASE 2 WAVE 1 (HIER-P2DECL) — THE FOUR OPERATIONS MANAGERS, THE
      # TOPOLOGY OWNER AND THE OPERATOR-SET TWINS
      # ================================================================
      # Operator rulings 2026-09-03, not re-litigated here: Fleet Autonomy is
      # split into a Capacity Manager, a Storage Manager, an Ingress Manager
      # and a Supply Chain Manager; the System Topology Designer takes the
      # topology set; every operator-only set is paired with the agent set
      # that carries the same keys; all official agents are global seeded
      # canonicals under the System Concierge (HIER-P1).
      #
      # THIS WAVE MOVES DECLARATIONS ONLY. The FOUR MANAGERS (identity,
      # prompt, chain, trust, skills) are seeded in wave 2. Until then, for
      # those four sets — and ONLY those four:
      #   * PolicyReconciler skips the set ("agent absent") and leaves the
      #     moved rows on Fleet Autonomy — it re-homes them, in place, the
      #     first reconcile after the agent exists (its FORMER_OWNERS map
      #     records every key below as moved off fleet-autonomy);
      #   * the fleet tick gates each re-pointed binding under Fleet Autonomy
      #     with a fleet.owner_agent_missing event, where those rows are.
      #
      # THE TOPOLOGY DESIGNER IS THE EXCEPTION, and it is the one wave-1 owner
      # that ALREADY EXISTS: db/seeds/system_topology_designer_agent.rb seeds
      # name "System Topology Designer" / agent_type "assistant", exactly the
      # AGENT_IDENTITIES entry below, so AgentResolver resolves it and its set
      # is NOT skipped. The first `rake system:governance:reconcile` after this
      # wave deploys re-homes system.multi_tenant_isolation and
      # system.service_discovery_compose off Fleet Autonomy onto it and CREATES
      # system.sdwan_federation_compose. All three declare require_approval,
      # which is also the unmatched default the composer executors resolved
      # while those rows sat on an agent they never run as — so no verdict
      # changes on a row nobody tuned. What DOES change: the three executors
      # `binds_to "System Topology Designer"` and BaseSkillExecutor resolves
      # the policy against the EXECUTING agent, so a Fleet Autonomy row an
      # operator had TUNED (auto_approve, say) stops being invisible to them
      # and starts applying — a loosening, on this wave alone.
      # policy_reconciler_rehome_spec pins the move.
      #
      # So an established install sees exactly those three rows change when
      # this wave is deployed by itself; the other 33 of FORMER_OWNERS's 35
      # wave-1 keys wait for wave 2.
      # A FRESH install seeded between the waves has no row anywhere for the
      # moved sensor-routed lanes (the Fleet Autonomy seed no longer declares
      # them and no seed exists for the four managers) — wave 2's seeds close
      # it.
      #
      # WHAT IS AGENT-ROUTED, PER SET. Stated because the operator ruling's
      # "twin where a sensor or executor lane exists" is a fact about each key:
      #   Capacity: system.instance_replace (instance_unrecoverable binding) and
      #     project.adapt / project.cost_control (the three project_* bindings
      #     and System::AdaptationGate) are sensor-routed; the other
      #     project.* verbs and the DR/expansion keys gate executors; the eight
      #     instance_pool keys, the platform-scaling pair and the cordon key are
      #     operator-door twins (Ai::GatedActions / SystemFleetTool /
      #     ReplicaReconciler), read at the agent shape only for a call made AS
      #     the Capacity Manager.
      #   Storage: system.storage_assignment_reconcile is sensor-routed
      #     (storage_assignment_drift); restore_volume gates an executor;
      #     volume_snapshot_delete is an operator-door twin.
      #   Ingress: nothing sensor-routed — five executor/MCP gates.
      #   Supply chain: system.package_repository.sync is sensor-routed
      #     (package_drift_pressure); the other six gate executors.
      #   Topology: nothing sensor-routed — three composer executor gates.

      # Capacity Manager = the capacity-shaped node-lifecycle keys + the eight
      # instance-pool keys (agent shape; the operator shape stays the gated
      # four) + the six project.* provisioning keys (with their per-category
      # condition override, carried on the POLICY_SETS entry) + the
      # platform-scaling pair + the cordon key. 22 keys. The former
      # "instance-pool-agent" and "provisioning" sets on Fleet Autonomy are
      # REPLACED by this one; every key here is new to Capacity Manager and,
      # except the three operator-twin-only keys, moved off Fleet Autonomy.
      CAPACITY_MANAGER_POLICIES = CAPACITY_POLICY_KEYS.merge(
        INSTANCE_POOL_POLICIES, PROVISIONING_POLICIES,
        PLATFORM_SCALING_POLICIES, INSTANCE_CORDON_OPERATOR_POLICIES
      ).freeze

      # Storage Manager = the two storage keys + the snapshot delete (twin of
      # the volume-snapshot operator set). 3 keys.
      STORAGE_MANAGER_POLICIES = STORAGE_POLICY_KEYS.merge(VOLUME_SNAPSHOT_OPERATOR_POLICIES).freeze

      # Ingress Manager = the four ingress executor gates + system.service_
      # backends_update. 5 keys.
      #
      # service_backends_update TRAVELS WITH THE INGRESS GROUP (the decision
      # HIER-P2A deferred to this increment): the category gates
      # Ai::Tools::SystemIngressTool#system_set_service_backends
      # (SERVICE_BACKENDS_CATEGORY, IMP-0c10b9fd5596), which writes a
      # published service's backend set — the same Sdwan::Service the four
      # expose_* verbs publish and the ACME verb certifies. The agent that
      # owns the ingress WRITER owns the row that gates it; leaving it on
      # Fleet Autonomy would have put one ingress write behind a different
      # agent's chain than its siblings. The UI domain (DOMAIN_PREFIXES
      # "ingress") and the ownership now agree.
      INGRESS_MANAGER_POLICIES = {
        "system.service_backends_update" => "require_approval"
      }.merge(INGRESS_POLICY_KEYS).freeze

      # Supply Chain Manager = the packages + architecture keys. 7 keys.
      # Nothing beyond the group today; written as a merge rather than an
      # alias so the text scan in spec/docs/reference_counts_spec.rb expands
      # it the way it expands its siblings.
      SUPPLY_CHAIN_MANAGER_POLICIES = SUPPLY_CHAIN_POLICY_KEYS.merge({}).freeze

      # System Topology Designer = the two composer categories that were in
      # FLEET_AUTONOMY_POLICIES since IMP-4ba48fd088ce, plus
      # system.sdwan_federation_compose, which was REGISTERED (an explicit
      # concat in lib/powernode_system/engine.rb) but declared by no set —
      # so it had no row anywhere, resolved the unmatched default and could
      # be tuned but never reconciled. Declared require_approval, which IS
      # that default: landing the row changes no verdict, it makes the
      # control visible and reconcilable. All three are
      # SdwanFederationComposeExecutor / MultiTenantIsolationExecutor /
      # ServiceDiscoveryComposerExecutor gates, bound to this assistant. The
      # Topology Designer is the EXISTING assistant (seeded by
      # db/seeds/system_topology_designer_agent.rb); it gains a policy set,
      # not a new identity. 3 keys, none sensor-routed.
      TOPOLOGY_DESIGNER_POLICIES = {
        "system.multi_tenant_isolation"    => "require_approval",
        "system.service_discovery_compose" => "require_approval",
        "system.sdwan_federation_compose"  => "require_approval"
      }.freeze

      # operator-set key → the agent-set key that carries the same keys at the
      # agent shape (operator ruling: every operator-only set gets an agent
      # twin). Declared so a new operator set cannot land unpaired;
      # policy_declarations_ownership_spec checks each pair against the sets
      # themselves (every operator key present on the twin, same verb). The
      # manual-operations set is NOT a POLICY_SETS entry and stays
      # operator-only by design — System::Task commands are an operator
      # vocabulary; PolicyReconciler#manual_set is its only home.
      OPERATOR_TWINS = {
        "sdwan-operator"           => "sdwan-manager",
        "runtime-operator"         => "runtime-manager",
        "instance-pool-operator"   => "capacity-manager",
        "platform-scaling"         => "capacity-manager",
        "instance-cordon-operator" => "capacity-manager",
        "volume-snapshot-operator" => "storage-manager"
      }.freeze

      # Agent identity is keyed on SOURCE_KEY, not name. The seeds look agents
      # up by name, but every seeded agent also carries a source_key and the
      # model documents these as "platform-provided, seed-managed by
      # source_key" — so an operator who renames one keeps a resolvable
      # declaration instead of silently losing its whole policy set.
      #
      # HIER-P2DECL adds the four wave-1 managers (seeded in wave 2 — an
      # identity here with no agent behind it is exactly the state
      # PolicyReconciler reports as "<set>(agent absent)" and the tick warns
      # about as fleet.owner_agent_missing) and the System Topology Designer,
      # which is the EXISTING assistant: its seed carries source_key
      # "system-topology-designer", so it resolves through the name+type
      # primary path here, not the source_key fallback.
      AGENT_IDENTITIES = {
        "fleet-autonomy"       => { name: "Fleet Autonomy",           agent_type: "monitor" },
        "sdwan-manager"        => { name: "SDWAN Manager",            agent_type: "monitor" },
        "cve-responder"        => { name: "CVE Responder",            agent_type: "monitor" },
        "disk-image-manager"   => { name: "Disk Image Manager",       agent_type: "monitor" },
        "gitops-reconciler"    => { name: "GitOps Reconciler",        agent_type: "monitor" },
        "runtime-manager"      => { name: "Runtime Manager",          agent_type: "monitor" },
        "capacity-manager"     => { name: "Capacity Manager",         agent_type: "monitor" },
        "storage-manager"      => { name: "Storage Manager",          agent_type: "monitor" },
        "ingress-manager"      => { name: "Ingress Manager",          agent_type: "monitor" },
        "supply-chain-manager" => { name: "Supply Chain Manager",     agent_type: "monitor" },
        "topology-designer"    => { name: "System Topology Designer", agent_type: "assistant" }
      }.freeze

      # Every declared row group, with the SHAPE it resolves at. `agent_key`
      # nil means an agent-less row; a set whose agent is absent is SKIPPED,
      # never guessed at another shape.
      #
      # NOTE the dual-shape operator/agent pairs (OPERATOR_TWINS): a family is
      # declared at BOTH the operator (global / action_type) and agent shapes
      # because the two bind different callers — but NOT the same rows. The
      # instance-pool agent shape (on the Capacity Manager since HIER-P2DECL)
      # carries all eight categories; the operator set carries only the four
      # a gate site passes (IMP-5a2b801f3386, see
      # INSTANCE_POOL_OPERATOR_GATED_KEYS above). One agent, ONE set: the
      # former "instance-pool-agent" and "provisioning" sets that keyed
      # fleet-autonomy a second and third time are folded into the
      # capacity-manager set, so `agent_key` is unique across the agent
      # entries and a key is declared exactly once.
      POLICY_SETS = [
        { key: "fleet-autonomy",       agent_key: "fleet-autonomy",       scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: FLEET_AUTONOMY_POLICIES },
        { key: "sdwan-manager",        agent_key: "sdwan-manager",        scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: SDWAN_MANAGER_POLICIES },
        { key: "cve-responder",        agent_key: "cve-responder",        scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: CVE_RESPONDER_POLICIES },
        { key: "disk-image-manager",   agent_key: "disk-image-manager",   scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: DISK_IMAGE_MANAGER_POLICIES },
        { key: "gitops-reconciler",    agent_key: "gitops-reconciler",    scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: GITOPS_RECONCILER_POLICIES },
        { key: "runtime-manager",      agent_key: "runtime-manager",      scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: RUNTIME_MANAGER_POLICIES },
        # HIER-P2DECL wave 1. The capacity set carries the provisioning
        # override that the old "provisioning" set carried (a set-level
        # `conditions` cannot express project.scale_horizontal's window).
        { key: "capacity-manager",     agent_key: "capacity-manager",     scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: CAPACITY_MANAGER_POLICIES,
          condition_overrides: PROVISIONING_CONDITION_OVERRIDES },
        { key: "storage-manager",      agent_key: "storage-manager",      scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: STORAGE_MANAGER_POLICIES },
        { key: "ingress-manager",      agent_key: "ingress-manager",      scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: INGRESS_MANAGER_POLICIES },
        { key: "supply-chain-manager", agent_key: "supply-chain-manager", scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: SUPPLY_CHAIN_MANAGER_POLICIES },
        { key: "topology-designer",    agent_key: "topology-designer",    scope: "agent",
          priority: 10, conditions: DEFAULT_TRUST_CONDITIONS, policies: TOPOLOGY_DESIGNER_POLICIES },
        { key: "sdwan-operator",     agent_key: nil,                  scope: "action_type",
          priority: 5,  conditions: DEFAULT_TRUST_CONDITIONS, policies: SDWAN_OPERATOR_POLICIES },
        { key: "runtime-operator",   agent_key: nil,                  scope: "action_type",
          priority: 5,  conditions: DEFAULT_TRUST_CONDITIONS, policies: RUNTIME_OPERATOR_POLICIES },
        { key: "instance-pool-operator", agent_key: nil,              scope: "global",
          priority: 5,  conditions: {}, policies: INSTANCE_POOL_OPERATOR_POLICIES },
        { key: "platform-scaling",   agent_key: nil,                  scope: "global",
          priority: 5,  conditions: {}, policies: PLATFORM_SCALING_POLICIES },
        { key: "volume-snapshot-operator", agent_key: nil,            scope: "global",
          priority: 5,  conditions: {}, policies: VOLUME_SNAPSHOT_OPERATOR_POLICIES },
        { key: "instance-cordon-operator", agent_key: nil,            scope: "global",
          priority: 5,  conditions: {}, policies: INSTANCE_CORDON_OPERATOR_POLICIES }
      ].freeze

      # action_category → the source_key of the agent whose AGENT-SCOPED set
      # declares it (HIER-P2A). This is the single answer to "which agent gates
      # this sensor-routed category": DecisionEngine::SIGNAL_BINDINGS declares
      # each binding's `owner:` and sensor_owner_gating_spec pins that the two
      # agree, and PolicyReconciler uses it to tell a row whose owner CHANGED
      # (re-home) from a row an operator put on an agent of their own (leave).
      #
      # nil for a category no agent set declares — since HIER-P2DECL every
      # operator set has an agent twin, so that is the manual-operations set
      # (system.task.*) and unknown names alike. Unambiguous by construction:
      # no category is declared on two agents, and none twice on one
      # (policy_declarations_ownership_spec pins both).
      AGENT_SET_OWNERS = POLICY_SETS
        .select { |set| set[:scope] == "agent" && set[:agent_key] }
        .each_with_object({}) { |set, owners| set[:policies].each_key { |c| owners[c] ||= set[:agent_key] } }
        .freeze

      def self.owner_of(action_category)
        AGENT_SET_OWNERS[action_category.to_s]
      end
    end
  end
end
