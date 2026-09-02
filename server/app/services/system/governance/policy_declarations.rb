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
        "restart" => "auto_approve",
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
        # DECLARED, never inferred, so a new notify-only category must be added by
        # hand or it ships this failure mode.
        #
        # IMP-43e94c9d46d4: the parenthetical here used to offer system.cert_rotate
        # and the SLO categories as lanes that actuated somewhere else. They did
        # not — both were proceed lanes that actuated NOTHING, and this sentence
        # was one of three copies telling readers not to check. cert_rotate now has
        # a REMEDIATION_APPLIERS entry and system.slo_violation is declared in
        # RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS. Add a category here
        # ONLY when its lane genuinely proceeds without actuating; the equality
        # oracle in spec/services/system/fleet/proceed_lane_actuation_spec.rb is
        # what refuses a silent lane in either direction.
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

        # ModulePromotionBacklogSensor — "a newer usable version exists and the
        # fleet is still running the old one". Seeded HERE for the same
        # mechanical reason as the categories above: the sensor fires from
        # FleetAutonomyService::SENSORS and gates as THIS agent, so a policy
        # declared on any other agent is invisible to the tick and every signal
        # dies at the gate.
        #
        # notify_and_proceed, never auto_approve, and there is deliberately no
        # applier — promoting the stalled version is precisely what a gate, a
        # broken publish chain or a deliberate hold has already declined to do.
        # What the notify verb actually buys is a SEPARATELY TUNABLE, operator-
        # facing policy row (this constant is also what registers the category
        # for the Autonomy modal) rather than folding the stall into the silent
        # auto-approved bucket. Be precise about the rest: gate_action!'s extra
        # step for this verb is FleetAutonomyService#notify_action, which today
        # only writes a Rails.logger line — it is not an operator page. Also in
        # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, because the
        # fingerprint stands until a person promotes, withdraws or fixes it.
        "system.module_promotion_investigate" => "notify_and_proceed",

        # Read/notify
        "system.module_assign"           => "notify_and_proceed",
        "system.instance_reboot"         => "notify_and_proceed",

        # Sensitive — require_approval
        "system.instance_reprovision"    => "require_approval",
        "system.instance_terminate"      => "require_approval",
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
        "system.architecture.delete"  => "require_approval",

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

        # === Gated skill executors (APO-1c, IMP-7e2bdc1774e4) ==================
        # Every executor declaring `requires_approval: true` resolves one of
        # these before #perform, on MCP, REST and Concierge alike. Seeded at
        # the SAME verdict the resolver would default to for an unseeded
        # category (require_approval), so landing these rows changes no
        # behaviour: it makes the verdict VISIBLE in the Autonomy modal and
        # TUNABLE through PATCH /api/v1/system/autonomy, and satisfies
        # routed_lane_policy_coherence_spec — BaseSkillExecutor is a declared
        # ActionCategoryRouter, so its categories are routed categories.
        "system.acme_certificate_provision" => "require_approval",
        "system.architecture_create"        => "require_approval",
        "system.architecture_delete"        => "require_approval",
        "system.architecture_update"        => "require_approval",
        "system.expose_service_local"       => "require_approval",
        "system.expose_service_public_tcp"  => "require_approval",
        "system.expose_service_publicly"    => "require_approval",
        "system.federation_acceptance"      => "require_approval",
        "system.fulfill_capability_request" => "require_approval",
        "system.multi_tenant_isolation"     => "require_approval",
        "system.package_module_create"      => "require_approval",
        "system.relocate_workload"          => "require_approval",
        "system.service_discovery_compose"  => "require_approval",
        "system.restore_volume"             => "require_approval",
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

      PROVISIONING_POLICIES = {
        "project.adapt" => "notify_and_proceed",
        "project.cost_control" => "notify_and_proceed",
        "project.scale_horizontal" => "auto_approve",
        "project.relocate" => "require_approval",
        "project.schema_change" => "require_approval",
        "project.security_change" => "require_approval"
      }.freeze

      # IMP-8c0f0fe9a8cf (APO-3b) — the destructive half of PlatformDeployment
      # replica reconciliation (System::Platform::ReplicaReconciler).
      #
      # Scale-OUT is deliberately NOT declared here: it provisions, which is
      # additive and reversible, and it runs on the caller's own authority.
      # Declaring a category the reconciler never resolves would render an
      # operator control that governs nothing — the defect
      # RUNTIME_OPERATOR_GATED_KEYS below exists to avoid.
      #
      # Scale-IN terminates instances, which is not reversible, so the
      # reconciler resolves this category before actuating and removes nothing
      # unless the verdict auto-executes. require_approval is a NO-OP on
      # resolution (it is also the absent-row default), so the row buys exactly
      # one thing: the control is REAL and retunable in the Autonomy modal
      # rather than a verdict with nothing behind it. Registration for that
      # modal is derived from POLICY_SETS in the engine initializer, so this
      # declaration is the only edit the category needs.
      #
      # Global scope, no agent: the reconciler is reached from the operator's
      # Concierge-bound platform_resilience skill, not from a monitor agent's
      # tick, so an agent-scoped row would resolve for nobody who can call it.
      PLATFORM_SCALING_POLICIES = {
        "system.platform.scale_in" => "require_approval"
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
          priority: 5,  conditions: {}, policies: INSTANCE_POOL_POLICIES },
        { key: "platform-scaling",   agent_key: nil,                  scope: "global",
          priority: 5,  conditions: {}, policies: PLATFORM_SCALING_POLICIES }
      ].freeze
    end
  end
end
