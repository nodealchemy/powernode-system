# frozen_string_literal: true

module Ai
  module Tools
    # MCP tool surface for the System extension. Exposes Node/NodeInstance/
    # NodeTemplate/NodeModule/Task lifecycle to operators + AI agents.
    #
    # Reference: Golden Eclipse plan M5 — MCP CRUD surface for System extension.
    # Mirrors trading_*_tool.rb in shape so the operator approval UI + agent
    # invocation paths work uniformly.
    class SystemFleetTool < BaseTool
      # Floor permission: every caller needs at least system.nodes.read to use
      # the tool at all. Per-action permissions in ACTION_PERMISSIONS gate
      # mutating actions to higher levels.
      REQUIRED_PERMISSION = "system.nodes.read"

      # How many of a build plan's excluded modules #dispatch_module_build_batch
      # samples into its result; excluded_count always carries the true total.
      EXCLUDED_MODULE_SAMPLE_LIMIT = 25

      # Params on which THIS tool routes an inner action of its own, rather than
      # on :action. The lifecycle-skill wrappers (#platform_maintenance,
      # #platform_resilience) cannot use :action — the MCP dispatcher owns that
      # key for the tool name itself — so they discriminate on `op:`, with a
      # per-skill alias. See #effective_action_name for why the deny overlay has
      # to know them. (IMP-e89d83547bad)
      INNER_ACTION_KEYS = %i[op maintenance_action resilience_action].freeze

      # IMP-7f01dfcb13e0 — a grant is applied server-side immediately, but an
      # MCP client caches tools/list at connect. The write now fires
      # `notifications/tools/list_changed` (System::NodeInstancePeer), which is
      # correct per protocol and harmless to a client that ignores it — but
      # whether a given client re-lists on it cannot be established here, so the
      # response says the truthful thing either way. Without this line the
      # documented recovery ("a missing tool is an instance-grant gap — grant it
      # with mode: add") appears to succeed while changing nothing the caller
      # can observe, inviting a retry, an over-wide re-grant, or an escalation
      # to breakglass that was never needed.
      MCP_GRANT_SESSION_NOTICE =
        "Applied server-side immediately. A connected MCP session caches its tools/list " \
        "from connect time: a notifications/tools/list_changed notification was broadcast " \
        "to this account's active sessions, but a client that does not act on it will keep " \
        "the old catalog — newly granted tools stay invisible and removed tools stay " \
        "advertised (they are still refused at call time) until the session RECONNECTS. " \
        "If the tool is still not listed after this call, reconnect the MCP session before " \
        "re-granting or widening further."

      # Per-action permission map. Aligned with the registered
      # `system.<resource>.<action>` catalog — the authoritative home is the
      # Permissions.register_catalog(namespace: "system") block in
      # server/lib/powernode_system/engine.rb (the old permission-seed
      # migration was deleted in the squash into
      # server/db/migrate/20250101000009_system_baseline.rb).
      # Internal callers (system services, autonomy reconcilers) bypass
      # this check by passing `internal: true` to .new — passing user: nil
      # alone is NOT a bypass (IMP-9030413bc292).
      ACTION_PERMISSIONS = {
        # Read
        "system_list_nodes"             => "system.nodes.read",
        "system_get_node"               => "system.nodes.read",
        "system_list_instances"         => "system.node_instances.read",
        "system_get_instance"           => "system.node_instances.read",
        "system_find_node_with_gpu"     => "system.node_instances.read",
        "system_list_instance_types_by_gpu" => "system.nodes.read",
        "system_deploy_inference_server" => "system.instances.create",
        "system_grant_instance_mcp_tools" => "system.node_instances.manage",
        "system_grant_instance_peer_skills" => "system.node_instances.manage",
        "system_discover_peers" => "system.node_instances.read",
        "system_authorize_peer_call" => "system.node_instances.read",
        "system_launch_agent_fleet" => "system.node_instances.manage",
        "system_agent_fleet_status" => "system.node_instances.read",
        "system_reap_agent_fleet" => "system.node_instances.manage",
        "system_mint_peer_capability_token" => "system.node_instances.manage",
        "system_list_isolation_tiers" => "system.node_instances.read",
        # IMP-767c0448b8b9 — template actions take the templates family, not
        # nodes.*: the registered catalog carries system.templates.{read,
        # create,update,delete} (engine.rb `resource :templates`) and REST
        # gates every template action there. Admin grant is identical either
        # way; the families differ for system_worker (nodes grants it
        # read+update, templates nothing), matching REST's refusal.
        "system_list_templates"         => "system.templates.read",
        "system_get_template"           => "system.templates.read",
        # IMP-20b3eb50da30 — design-time composition analysis. Reads a module
        # set and reports conflicts/footprint/graph; persists nothing. REST's
        # compose_preview is gated on templates.UPDATE only because it was
        # grouped with the composer's save flow, so this takes the permission
        # matching what it actually does. Same admin grant either way
        # (engine.rb `resource :templates`), so nothing widens.
        "system_compose_preview_template" => "system.templates.read",
        "system_list_modules"           => "system.modules.read",
        "system_get_module"             => "system.modules.read",
        "system_list_module_versions"   => "system.modules.read",
        # IMP-67aea0728774 — semantic catalog discovery (the reuse-first gate).
        # Read-only ranking over the same rows list_modules/list_templates
        # already expose, so each takes the permission of its list counterpart.
        "system_discover_modules"       => "system.modules.read",
        "system_discover_templates"     => "system.templates.read",
        "system_module_publish_target"  => "system.modules.read",
        "system_module_publication_integrity" => "system.modules.read",
        "system_instance_hold_status"   => "system.instances.read",
        "system_instance_hold"          => "system.instances.control",
        "system_instance_release_hold"  => "system.instances.control",
        "system_drift_report"           => "system.node_instances.read",
        "system_list_tasks"             => "system.infra_tasks.read",
        "system_get_task"               => "system.infra_tasks.read",

        # Mutate
        "system_create_node"            => "system.nodes.create",
        "system_update_node"            => "system.nodes.update",
        "system_delete_node"            => "system.nodes.delete",
        "system_create_template"        => "system.templates.create",
        # Clone CREATES a template, so it takes the create grant like REST's
        # clone action — not templates.read, despite reading a source.
        "system_clone_template"         => "system.templates.create",
        "system_delete_template"        => "system.templates.delete",
        "system_update_template"        => "system.templates.update",
        "system_update_instance"        => "system.instances.update",
        "system_create_module"          => "system.modules.create",
        "system_update_module"          => "system.modules.update",
        # The inverse of system_module_mark_canary. Gated on modules.update to
        # match REST's unmark_canary — deliberately NOT on the worker-only
        # system.fleet.autonomy that mark_canary carries, so an operator who
        # can set the flag over REST can always clear it over MCP.
        "system_unmark_module_canary"   => "system.modules.update",
        "system_delete_module"          => "system.modules.delete",
        "system_refresh_instance_modules" => "system.node_instances.manage",
        "system_upgrade_boot_image"     => "system.node_instances.manage",
        # IMP-dcf2e39e92ed — a join mutation is a TEMPLATE mutation. The row
        # belongs_to the template, record_template_blast_radius reports the
        # change against the TEMPLATE's live nodes, and REST
        # (template_modules_controller) already gated all three on
        # templates.update — so this ends the two-conventions split rather
        # than leaving each surface with its own defensible reading.
        "system_assign_module_to_template" => "system.templates.update",
        # Deliberately the same grant as assign/unassign: disabling a join is
        # the non-destructive alternative to unassigning it, so anyone who can
        # do the destructive removal must be able to reach the safe one.
        "system_update_template_module" => "system.templates.update",
        "system_provision_instance"     => "system.instances.create",
        "system_terminate_instance"     => "system.instances.control",
        "system_destroy_instance"       => "system.instances.control",
        # F4-08 — lifecycle control (start/stop/reboot): same level as
        # terminate, wraps InstanceControlService.
        "system_start_instance"         => "system.instances.control",
        "system_stop_instance"          => "system.instances.control",
        "system_reboot_instance"        => "system.instances.control",

        # Promotion (state-changing across the fleet — same level as module update)
        "system_promote_module_version" => "system.modules.update",

        # Task control
        "system_cancel_task"            => "system.infra_tasks.control",
        # IMP-8153d1952ff8 — operator recourse on a wedged :running task,
        # same gate as cancel (system.infra_tasks.control).
        "system_abort_task"             => "system.infra_tasks.control",

        # Module diff (read — same level as get_module)
        "system_module_diff"            => "system.modules.read",

        # Platform deployment (D1.2 + D2 + D3) — wizard payload is
        # safe to read with system.platform.read; actual deploy mutation
        # requires system.platform.deploy.
        "system_deploy_platform"        => "system.platform.deploy",

        # Storage volume CRUD (MCP.1) — read/list/create/update/delete
        # + attach/detach + NFS export probe. The recommendations
        # read/write surface the shared-memory tunables.
        "system_list_volumes"           => "system.volumes.read",
        "system_get_volume"             => "system.volumes.read",
        "system_create_volume"          => "system.volumes.create",
        "system_update_volume"          => "system.volumes.update",
        "system_delete_volume"          => "system.volumes.delete",
        "system_attach_volume"          => "system.volumes.update",
        "system_detach_volume"          => "system.volumes.update",
        "system_test_nfs_export"        => "system.volumes.read",
        "system_get_storage_recommendations"    => "system.platform.read",
        "system_update_storage_recommendations" => "system.platform.scale",
        "system_migrate_storage_component"      => "system.platform.scale",
        # E7.3 — storage migration lifecycle
        "system_list_storage_migrations"        => "system.platform.read",
        "system_get_storage_migration"          => "system.platform.read",
        "system_approve_storage_migration"      => "system.platform.scale",
        "system_cancel_storage_migration"       => "system.platform.scale",
        "system_report_storage_migration_progress" => "system.platform.scale",
        # Increment 9 — revert_binding! (R) / cleanup (C). Same
        # permission tier as the rest of the lifecycle family; there is
        # no finer-grained "destructive storage op" permission today
        # (see the definitions: requires_approval note on
        # system_cleanup_storage_migration re: the 019f34a3 gap).
        "system_revert_storage_migration_binding" => "system.platform.scale",
        "system_cleanup_storage_migration"        => "system.platform.scale",

        # Lifecycle skill wrappers (MCP.2) — surface platform_maintenance
        # + platform_resilience as MCP-callable actions so external
        # tools (concierge, autonomous agents, ops scripts) can invoke
        # them directly. The executors are reused.
        "system_platform_maintenance"   => "system.platform.read",
        "system_platform_resilience"    => "system.platform.scale",

        # Audit + AI skills surfaces
        # ComplianceSnapshotService#snapshot! is a PURE READ — it only collects
        # and returns a Hash; its own class comment says the CALLER persists the
        # document via add_document, so the bang means "raises on bad args", not
        # "mutates". Operator-facing audit evidence, not an autonomy decision.
        # (IMP-7ad2c4f02f55)
        "system_compliance_snapshot"    => "system.fleet.read",
        "system_runbook_generate"       => "system.modules.read",
        "system_cve_runbook_generate"   => "system.modules.read",
        "system_cve_triage"             => "system.modules.read",

        # Observability + attribution.
        # Both read System::FleetEvent scoped to @account and decide nothing, so
        # they carry the operator-facing fleet permission rather than the
        # system_worker-scoped system.fleet.autonomy. These are the MCP twins of
        # the HTTP /fleet/signals and /fleet/boot_replay endpoints moved to
        # system.fleet.read in 428f84ce — the same operator was being answered
        # over HTTP and refused over MCP. (IMP-7ad2c4f02f55)
        "system_recent_signals"         => "system.fleet.read",
        "system_attribute_failure"      => "system.node_instances.read",
        "system_inspect_correlation"    => "system.fleet.read",

        # === Slice 7 — instance pools ===
        # Read paths fall under node_instances.read; mutate paths under instances.create/control.
        "system_list_instance_pools"    => "system.node_instances.read",
        "system_get_instance_pool"      => "system.node_instances.read",
        "system_create_instance_pool"   => "system.instances.create",
        # F8-07 — REST update parity (mirrors instance_pools_controller
        # authorize_write! = system.instances.create/.control).
        "system_update_instance_pool"   => "system.instances.create",
        "system_drain_instance_pool"    => "system.instances.control",
        "system_acquire_pooled_instance" => "system.instances.create",
        "system_replenish_instance_pool" => "system.instances.create",
        "system_recycle_pool"            => "system.instances.control",

        # === Gap remediation slice 1 (Phase 4 — operator-runbook-driven actions) ===
        # system_drain_instance: graceful drain marker — operator opts into a
        #   workload-relocation window before terminate. v1 records intent +
        #   emits FleetEvent; future cordon/stop logic on the same handle.
        # system_get_silent_instances: read-only view aligned with InstanceStatusSensor.
        # system_validate_module_manifest: pure validation; no DB writes.
        "system_drain_instance"           => "system.instances.control",
        "system_get_silent_instances"     => "system.node_instances.read",
        "system_validate_module_manifest" => "system.modules.read",

        # === Gap remediation slice 2 — CVE catalog + module assignment cleanup ===
        # CVE actions touch the GLOBAL Cve table (not account-scoped); create/delete
        # require system.fleet.autonomy elevated permission. Read paths are
        # account-aware via CveExposure → NodeModuleVersion → NodeModule scoping.
        "system_get_cve"                       => "system.modules.read",
        "system_get_cve_exposure"              => "system.modules.read",
        "system_create_cve"                    => "system.fleet.autonomy",
        "system_delete_cve"                    => "system.fleet.autonomy",
        "system_unassign_module_from_template" => "system.templates.update",
        # Toggle a NodeModuleAssignment's enabled flag (mirrors the
        # NodeModuleAssignmentsController enable/disable member actions).
        "system_update_module_assignment"      => "system.modules.update",

        # === Gap remediation slice 3 — pool ops + canary marking ===
        "system_return_pooled_instance"        => "system.instances.control",
        "system_delete_instance_pool"          => "system.instances.create",
        "system_module_mark_canary"            => "system.fleet.autonomy",

        # === Gap remediation slice 5 — disk image CI ===
        # Read paths use the existing system.fleet.read pattern; mutate paths
        # use the existing CI worker permission scheme (ci_workers.create/delete).
        "system_list_disk_image_publications"        => "system.modules.read",
        "system_set_default_disk_image_publication"  => "system.modules.update",
        # Roll a platform's disk image back to a prior publication. Mirrors
        # DiskImagePublicationsController#rollback's dedicated permission.
        "system_revert_disk_image"                   => "system.platforms.rollback_disk_image",
        "system_set_disk_image_retention"            => "system.modules.update",
        "system_provision_ci_worker"                 => "system.ci_workers.create",
        "system_terminate_ci_worker"                 => "system.ci_workers.delete",
        "system_list_ci_workers"                     => "system.ci_workers.read",
        # Campaign 019f5885 inc3 — ephemeral CI runner leases.
        "system_lease_ci_runner"                     => "system.ci_runner_leases.create",
        "system_release_ci_runner"                   => "system.ci_runner_leases.update",
        "system_list_ci_runner_leases"               => "system.ci_runner_leases.read",
        "system_list_disk_image_webhooks"            => "system.modules.read",
        # Campaign 019f5885 inc9 — native module-build batch orchestration.
        "system_dispatch_module_build_batch"         => "system.module_builds.dispatch",
        # Cancel is deliberately NOT gated on ...dispatch: that permission is
        # granted only to system_worker, so reusing it would leave the human
        # operator — the one who notices mid-batch that the wrong thing was
        # dispatched — unable to stop it, which is the whole finding. Its own
        # permission is registered to admin/manager alongside ...read.
        "system_cancel_module_build_batch"           => "system.module_builds.cancel",
        # Operator recovery after a bad publish — admin-granted, not worker.
        "system_rollback_module_version"             => "system.modules.rollback",

        # === Missing-features slice 6a — GitOps reconciler MCP surface ===
        "system_gitops_register_repository" => "system.modules.update",
        "system_gitops_sync_repository"     => "system.modules.update",
        "system_gitops_get_sync_run"        => "system.modules.read",
        "system_gitops_get_drift_report"    => "system.modules.read",
        # IMP-f07be27ba0b0 — read verbs. NOT gated like the sibling gitops
        # reads above: these two are the first MCP surface to return
        # serialize_gitops_repository, whose projection carries
        # vault_credential_path (IMP-0f914db2c7cf). On system.modules.read that
        # put a GitOps repository's Vault KV PATH in front of every principal
        # holding module read for ordinary module work — {admin, system_worker,
        # super_admin} instead of REST's {system_worker, super_admin}.
        #
        # IMP-b1191457a091 fixed the permission MODEL rather than the symptom.
        # system.gitops.read was registered worker-only, so no assignable role
        # held the operator read its own REST controller and GitOps tab are
        # gated on; that is what forced these verbs onto a different name.
        # engine.rb now grants it to admin as well, so matching REST here costs
        # the operator nothing.
        #
        # State the direction of travel honestly, both ways. Parity was reached
        # by RAISING REST, not only by lowering MCP: REST's read audience gains
        # `admin`, which it never had. The net HUMAN audience for the Vault path
        # is therefore unchanged — {admin, system_worker, super_admin} before and
        # after. What actually narrows is the population this finding named: a
        # non-admin principal holding system.modules.read for ordinary module
        # work (a custom role, an agent user) no longer reaches the projection.
        #
        # And this map is not the only gate on that audience: action_permitted?
        # returns early for internal? and instance_authorized? (see the note at
        # its definition), so an instance principal granted these tool NAMES
        # still gets the projection without any permission being consulted.
        # Changing the name here does not touch that path.
        #
        # Paths and key names only, never values — and no credential PROBE is
        # mirrored to MCP.
        "system_gitops_get_repository"      => "system.gitops.read",
        "system_gitops_list_repositories"   => "system.gitops.read",

        # === Missing-features slice Vault DR-3 — pepper rotation ===
        # Highest tier permission — rotation is a fleet-wide cryptographic op.
        "system_rotate_vault_transit_pepper" => "system.fleet.autonomy",

        # === Missing-features slice 6b — GitOps apply path ===
        "system_gitops_apply_proposal" => "system.modules.update",

        # === Provider catalog (per-account) ===
        # Routed-mode QEMU provisioning needs provider.config to carry
        # host_node_instance_id; without these MCP actions operators had
        # to drop to rails runner to inspect/edit provider rows.
        "system_list_providers"        => "system.providers.read",
        "system_get_provider"          => "system.providers.read",
        "system_update_provider"       => "system.providers.update",
        # F8-03 — REST had full provider CRUD but MCP stopped at update, so
        # fleet-expansion missions could not onboard/decommission providers.
        "system_create_provider"       => "system.providers.create",
        "system_delete_provider"       => "system.providers.delete",
        # F4-07 — the provisionable chain needs provider + connected
        # connection + region + instance type; only the provider half had
        # MCP creates. Permission names mirror the REST controllers
        # (provider_connections/provider_regions gate their own families;
        # the instance-types controller gates create on providers.create).
        "system_create_provider_connection"    => "system.connections.create",
        "system_create_provider_region"        => "system.regions.create",
        "system_create_provider_instance_type" => "system.providers.create"
      }.freeze

      # GOVERNANCE DECLARATION (IMP-d410a587d6bf) — the MCP half of instance
      # lifecycle was outside the approval regime entirely. This tool held ZERO
      # Ai::AutonomyGate references while its REST twin
      # (System::NodeInstanceGating#gate_or_execute) gated every lifecycle arm
      # on `system.task.<event>`, so the same operation an operator could not
      # perform from the console without an approval was one MCP call away:
      # #terminate_instance went straight to System::ProvisioningService and
      # destroyed the VM. Neither the service below it
      # (ProvisioningService/InstanceControlService) nor the dispatch above it
      # gated anything.
      #
      # Declared, not hand-placed: Ai::Tools::BaseTool#execute evaluates this.
      # See the registry comment on BaseTool.declare_action for why the gate
      # lives at the chokepoint rather than in the arm.
      #
      # SAME category as the REST twin — "system.task.terminate", seeded
      # require_approval in System::Governance::PolicyDeclarations::
      # MANUAL_OPERATION_POLICIES at scope "global", which is agent-BINDING
      # (Ai::InterventionPolicyService#resolve), so one operator-tuned row
      # governs terminate whether an operator or an agent asks for it.
      #
      # DIFFERENT executor, deliberately. The gate replays `executor_class`
      # after approval, so the executor — not this arm — is the actor on both
      # branches, and it therefore has to do exactly what this arm used to do.
      # ExecuteTask (what REST uses) does NOT: its System::Task lane reaches the
      # instance through InstanceControlService, which carries no
      # SelfManagementFence and no finalize_termination!, dropping INV-1, the
      # SDWAN peer detach, the deploy-key revocation, the terminate meter event
      # and F4-02 idempotency. System::Executors::TerminateInstance calls
      # ProvisioningService.terminate_instance — the identical call this arm
      # made — so gating costs the operation none of its safety controls. See
      # that class for the full rationale.
      #
      # Behaviour therefore changes in exactly one way: the policy is now
      # consulted. On :proceed the response is what it always was
      # (`terminated: true` + the instance); on require_approval it parks.
      #
      # SCOPE, stated so this is not read as more than it is. ONE verb is gated.
      # The same ProvisioningService.terminate_instance call is still reachable
      # UNGATED from sibling verbs on this tool — system_recycle_pool,
      # system_drain_instance_pool and system_return_pooled_instance (all via
      # System::InstancePoolService#terminate_member) and system_reap_agent_fleet
      # (System::AgentFleetMissionService) — plus several skill executors that
      # call the service below this chokepoint entirely. system_recycle_pool is
      # mapped to system.instances.control, the SAME permission this action
      # checks, so a caller holding exactly that credential can still destroy
      # instances with no policy evaluation by naming a different verb. That is
      # the next increment, not a claim this one already covers.
      #
      # system_destroy_instance is NOT declared here. It is a registry-row
      # cascade delete, not a provider terminate: no seeded action_category
      # names it and no executor can replay it (see #destroy_instance). Gating
      # it needs an executor contract this task does not own (IMP-439d31353f9b).
      # Note the interaction: terminate is gated, the row-delete is not, so a
      # caller can still destroy the ROW a parked terminate is waiting on — the
      # approval then fails resolve_scoped rather than terminating anything.
      # IMP-f07be27ba0b0 — declared rather than added to the frozen
      # undeclared-actions snapshot. Both are pure reads, so `mutating: false`
      # makes gated_action? false and #execute takes the same `return
      # call(params)` path an undeclared action takes; the difference is that
      # the surface is now governed and no undeclared-action audit sighting is
      # recorded for it. The five older gitops verbs sit in the snapshot
      # (server/spec/fixtures/governance/undeclared_actions.txt), whose header
      # says that list MAY ONLY SHRINK — adding two more would have been the
      # reviewed decision it warns about, for no gain over declaring them.
      declare_action "system_gitops_get_repository", mutating: false
      declare_action "system_gitops_list_repositories", mutating: false

      declare_action "system_terminate_instance",
                     mutating: true,
                     # Literal, not the executor's ACTION_CATEGORY constant:
                     # this runs at class-body evaluation and must not force an
                     # executor autoload just to read a string. Kept in step by
                     # the gating spec, which asserts the two agree.
                     action_category: "system.task.terminate",
                     executor_class: "System::Executors::TerminateInstance",
                     gate_context: :terminate_instance_gate_context,
                     on_proceed: :terminate_instance_terminated_result

      def self.definition
        {
          name: "system_fleet",
          description: "System extension fleet operations: nodes, instances, templates, modules, tasks, drift",
          parameters: {
            action: { type: "string", required: true, description: "Action to perform" },
            id: { type: "string", required: false, description: "Resource ID (context-dependent)" },
            name: { type: "string", required: false },
            template_id: { type: "string", required: false },
            node_id: { type: "string", required: false },
            instance_id: { type: "string", required: false },
            module_id: { type: "string", required: false },
            module_version_id: { type: "string", required: false },
            module_name: { type: "string", required: false, description: "Module slug as CI publishes it (system_module_publish_target)" },
            gitea_repo: { type: "string", required: false, description: "OCI repo full name; defaults to powernode/<module_name> (system_module_publish_target)" },
            target_state: { type: "string", required: false, description: "Module promotion target: staging|blessed|live|retired" },
            provider_id: { type: "string", required: false },
            provider_region_id: { type: "string", required: false },
            provider_instance_type_id: { type: "string", required: false },
            options: { type: "object", required: false, description: "Per-action option hash" }
          }
        }
      end

      def self.action_definitions
        {
          # === Nodes ===
          "system_list_nodes" => {
            description: "List all nodes for the current account",
            parameters: { template_id: { type: "string", required: false, description: "Optional NodeTemplate UUID to filter nodes by their bound template" } }
          },
          "system_get_node" => {
            description: "Fetch a node by id",
            parameters: { node_id: { type: "string", required: true, description: "UUID of the node to fetch (account-scoped)" } }
          },
          "system_create_node" => {
            description: "Create a new node bound to a template. Accepts the same surface as REST create (minus SSH key material — manage keys via the REST/Vault path).",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new node" },
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to bind the node to" },
              description: { type: "string", required: false, description: "Free-text description for the node" },
              enabled: { type: "boolean", required: false, description: "Create disabled with false (default true)" },
              worker_id: { type: "string", required: false, description: "UUID of the Worker that services this node's tasks" },
              public_address: { type: "string", required: false, description: "Public hostname or IP to reach the node at" },
              allocate_public_ip: { type: "boolean", required: false, description: "When true, request a public IP allocation for the node" },
              config: { type: "object", required: false, description: "Arbitrary node config hash" }
            }
          },
          # F8-07 — REST update parity. Mirrors nodes_controller node_params
          # MINUS ssh_key/ssh_host_key — key material never flows through an
          # MCP tool argument (crypto-safety); rotate keys via the REST/Vault
          # path instead.
          "system_update_node" => {
            description: "Update a node's mutable attributes (rename, enable/disable, retarget template/worker, public-address config). Does NOT accept SSH key material — manage keys via the REST/Vault path.",
            parameters: {
              node_id: { type: "string", required: true, description: "UUID of the node to update (account-scoped)" },
              name: { type: "string", required: false, description: "New display name for the node" },
              description: { type: "string", required: false, description: "New free-text description for the node" },
              enabled: { type: "boolean", required: false, description: "Enable (true) or disable (false) the node" },
              node_template_id: { type: "string", required: false, description: "UUID of a NodeTemplate to retarget the node to" },
              worker_id: { type: "string", required: false, description: "UUID of the Worker that services this node's tasks" },
              public_address: { type: "string", required: false, description: "Public hostname or IP to reach the node at" },
              allocate_public_ip: { type: "boolean", required: false, description: "When true, request a public IP allocation for the node" },
              config: { type: "object", required: false, description: "Arbitrary node config hash (merged into the node record)" }
            }
          },
          "system_delete_node" => {
            description: "Hard-destroy a Node. Cascades node_instances, node_module_assignments, and tasks via dependent:destroy. " \
                         "FK-blocked if instances have unhandled SDWAN/bootstrap_token references — use system_destroy_instance first per instance, then this.",
            parameters: { node_id: { type: "string", required: true, description: "UUID of the node to hard-destroy (account-scoped)" } }
          },
          "system_delete_template" => {
            description: "Delete a NodeTemplate. Restricted: errors if any Node uses this template (System::NodeTemplate has dependent::restrict_with_error on nodes).",
            parameters: { template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to delete (account-scoped)" } }
          },
          "system_clone_template" => {
            description: "Clone a NodeTemplate, copying its module assignments wholesale. The reuse-first move after system_discover_templates finds a near-match: clone, then adjust with system_assign_module_to_template / system_update_template_module rather than rebuilding from scratch. A clone copies conflicts too, so any composition problem is returned under `composition_report` (each entry states its own severity) — the clone still succeeds, and that report is the baseline later assignments must accept.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the source NodeTemplate to clone (account-scoped)" },
              name: { type: "string", required: false, description: "Name for the new template (defaults to '<source name>-copy')" }
            }
          },
          "system_create_template" => {
            description: "Create a new NodeTemplate for the current account. Binds to a NodePlatform via node_platform_id, which the model requires — omitting it fails the create. Lets the model validate the rest (name presence + per-account uniqueness).",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new template (must be unique within the account)" },
              description: { type: "string", required: false, description: "Free-text description for the template" },
              enabled: { type: "boolean", required: false, description: "Whether the template is enabled (selectable for new nodes)" },
              public: { type: "boolean", required: false, description: "Whether the template is shared/public rather than account-private" },
              node_platform_id: { type: "string", required: true, description: "UUID of the NodePlatform the template binds to (System::NodeTemplate belongs_to :node_platform, and the column is NOT NULL)" },
              admin_user: { type: "string", required: false, description: "Default admin username provisioned on instances built from this template" },
              config: { type: "object", required: false, description: "Arbitrary template config hash" }
            }
          },
          "system_update_template" => {
            description: "Update mutable NodeTemplate fields. Accepts everything system_create_template accepts, so nothing set at create time is stranded: name, description, enabled, public, node_platform_id, admin_user, config. `config` REPLACES the stored hash rather than merging into it — read the current value with system_get_template first if you mean to add a key. Omitted fields are left untouched.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to update (account-scoped)" },
              name: { type: "string", required: false, description: "New display name for the template" },
              description: { type: "string", required: false, description: "New free-text description for the template" },
              enabled: { type: "boolean", required: false, description: "Whether the template is enabled (selectable for new nodes)" },
              public: { type: "boolean", required: false, description: "Whether the template is shared/public rather than account-private" },
              node_platform_id: { type: "string", required: false, description: "UUID of a NodePlatform to retarget the template to" },
              admin_user: { type: "string", required: false, description: "Default admin username provisioned on instances built from this template" },
              config: { type: "object", required: false, description: "Template config hash (init_script, boot_mode, sdwan_network_id, …) — REPLACES the stored hash" }
            }
          },
          "system_delete_module" => {
            description: "Delete a NodeModule. Cascades child_modules, versions, node_module_assignments, template_modules, module_puppet_assignments, module_dependencies.",
            parameters: { module_id: { type: "string", required: true, description: "UUID of the NodeModule to delete (account-scoped)" } }
          },
          "system_create_module" => {
            description: "Author a new NodeModule. Same surface as REST create. Spec fields (mask/file_spec/package_spec/dependency_spec/protected_spec) take newline-joined glob strings or already-encoded arrays. REUSE GATE (enforced, not advisory): supplying manifest_yaml for a name the build planner does not already build is authoring a NEW module, and is REFUSED unless you also pass reuse_check. Run system_discover_modules by PURPOSE first; every module you name in reuse_check.considered is verified to exist, so an invented candidate refuses the call. The gate also refuses when the buildable catalog holds ZERO embeddings, because the survey it asks for could not have returned anything.",
            parameters: {
              name: { type: "string", required: true, description: "Module name (unique per account)" },
              node_platform_id: { type: "string", required: true, description: "UUID of the NodePlatform this module targets" },
              category_id: { type: "string", required: false, description: "UUID of the NodeModuleCategory" },
              variety: { type: "string", required: false, description: "Module variety (e.g. subscription, instance)" },
              description: { type: "string", required: false, description: "Free-text description" },
              enabled: { type: "boolean", required: false, description: "Whether the module is enabled" },
              public: { type: "boolean", required: false, description: "Whether the module is publicly visible" },
              priority: { type: "integer", required: false, description: "Composition priority (lower applies first)" },
              copy_path_id: { type: "string", required: false, description: "UUID of a module to copy paths from" },
              lock_spec: { type: "boolean", required: false, description: "Lock the spec fields against further edits" },
              init_start: { type: "string", required: false, description: "Init start command" },
              init_stop: { type: "string", required: false, description: "Init stop command" },
              init_restart: { type: "string", required: false, description: "Init restart command" },
              reboot_required: { type: "boolean", required: false, description: "Whether applying this module requires a reboot" },
              mask: { type: "string", required: false, description: "Mask spec — newline-joined globs or encoded array" },
              file_spec: { type: "string", required: false, description: "File spec — newline-joined globs or encoded array" },
              package_spec: { type: "string", required: false, description: "Package spec — newline-joined names or encoded array" },
              dependency_spec: { type: "string", required: false, description: "Dependency spec — newline-joined entries or encoded array" },
              protected_spec: { type: "string", required: false, description: "Protected-path spec — newline-joined globs or encoded array" },
              consent_budget_per_day: { type: "integer", required: false, description: "Daily ceiling on autonomous decisions for this module (policy; the consumed-count ledger is not settable here)" },
              config: { type: "object", required: false, description: "Module config hash — validated by System::ModuleConfigValidator (verify/restart_after_update/security/daemon_overrides grammar). Replaces the stored config WHOLESALE: omitting a security or verify block the module currently carries is refused; to remove one, state it explicitly (security: null or {}, verify: null)." },
              reuse_check: { type: "object", required: false, description: "REQUIRED when manifest_yaml authors a name the build planner does not already build. Shape: { considered: [{ module: \"<existing module name>\", rejected_because: \"<why it does not serve this purpose>\" }], justification: \"R1\"|\"R2\"|\"R3\", justification_detail: \"<how that prong is satisfied>\" }. R1 = two or more real consumers today or a hard requires: capability edge; R2 = an independent third-party payload with its own version/CVE cadence; R3 = an opt-in heavy payload a node type must be able to exclude. Every considered module is checked against the buildable catalog and every entry needs a non-blank rejected_because — the declaration is verified, not recorded. Persisted to the module's config.reuse_check, together with the catalog_coverage the survey ran against. COVERAGE PRECONDITION: if NOT ONE buildable module in the account carries a search embedding, system_discover_modules returns [] for every intent and the survey could not have found an overlap — the call is REFUSED and names `rake system:catalog:backfill_embeddings`. To author anyway (e.g. the embedding provider is unreachable), add unindexed_catalog_ack: \"<why>\", which records the reuse check as explicitly unverified. An empty catalog does not trigger this. See docs/runbooks/module-authoring.md Phase 0." },
              manifest_yaml: { type: "string", required: false, description: "Raw manifest.yaml. When given it is authoritative for the spec/lifecycle fields (mask/file_spec/package_spec/dependency_spec/protected_spec/init/reboot), which are derived by the same importer the loader seed uses — pass only name/node_platform_id/category_id alongside it. This is what makes an MCP-authored module carry a manifest_yaml and therefore be buildable (visible to the module-build planner)." },
              create_version: { type: "boolean", required: false, description: "With manifest_yaml, also snapshot the imported state into a new NodeModuleVersion (default true on create)" },
              version_changelog: { type: "string", required: false, description: "Changelog recorded on the snapshotted version when create_version is set" }
            }
          },
          "system_update_module" => {
            description: "Update an existing NodeModule's mutable attributes. Accepts the same fields as system_create_module; absent fields are left untouched. Does NOT accept the consent-budget consumed-count ledger — that is maintained by the autonomy gate. Carries the same reuse gate as system_create_module, but only on the authoring case: giving a manifest to a module that has none yet.",
            parameters: {
              module_id: { type: "string", required: true, description: "UUID of the NodeModule to update (account-scoped)" },
              name: { type: "string", required: false, description: "New module name" },
              description: { type: "string", required: false, description: "New description" },
              variety: { type: "string", required: false, description: "New variety" },
              enabled: { type: "boolean", required: false, description: "Enable or disable the module" },
              public: { type: "boolean", required: false, description: "Publicly visible or not" },
              priority: { type: "integer", required: false, description: "Composition priority" },
              node_platform_id: { type: "string", required: false, description: "Retarget to another NodePlatform" },
              category_id: { type: "string", required: false, description: "Recategorize the module" },
              lock_spec: { type: "boolean", required: false, description: "Lock/unlock the spec fields" },
              init_start: { type: "string", required: false, description: "Init start command" },
              init_stop: { type: "string", required: false, description: "Init stop command" },
              init_restart: { type: "string", required: false, description: "Init restart command" },
              reboot_required: { type: "boolean", required: false, description: "Whether applying requires a reboot" },
              mask: { type: "string", required: false, description: "Mask spec" },
              file_spec: { type: "string", required: false, description: "File spec" },
              package_spec: { type: "string", required: false, description: "Package spec" },
              dependency_spec: { type: "string", required: false, description: "Dependency spec" },
              protected_spec: { type: "string", required: false, description: "Protected-path spec" },
              consent_budget_per_day: { type: "integer", required: false, description: "Daily ceiling on autonomous decisions for this module" },
              config: { type: "object", required: false, description: "Module config hash — validated by System::ModuleConfigValidator (verify/restart_after_update/security/daemon_overrides grammar). Replaces the stored config WHOLESALE: omitting a security or verify block the module currently carries is refused; to remove one, state it explicitly (security: null or {}, verify: null)." },
              manifest_yaml: { type: "string", required: false, description: "Raw manifest.yaml to re-import onto this module (authoritative for spec/lifecycle fields; same importer as the loader seed / REST import_manifest). Use to update a module's manifest — e.g. a CVE version bump — over MCP. Re-importing onto a name the build planner ALREADY builds is not gated; giving a manifest to a module that has none yet is authoring, and requires reuse_check exactly as system_create_module does." },
              reuse_check: { type: "object", required: false, description: "REQUIRED only when this update would give a manifest to a module the build planner does not yet build (the bare-create-then-update path — the same authoring event as system_create_module, in two calls). Same shape and same verification as system_create_module's reuse_check. Not needed for an ordinary re-import onto an already-buildable module." },
              create_version: { type: "boolean", required: false, description: "With manifest_yaml, snapshot the imported state into a new NodeModuleVersion (default false on update)" },
              version_changelog: { type: "string", required: false, description: "Changelog recorded on the snapshotted version when create_version is set" }
            }
          },
          "system_unmark_module_canary" => {
            description: "Clear the honeypot canary flag on a NodeModule — the inverse of system_module_mark_canary. Removes the honeypot key from config and leaves the rest untouched.",
            parameters: { module_id: { type: "string", required: true, description: "UUID of the NodeModule to unmark (account-scoped)" } }
          },
          "system_refresh_instance_modules" => {
            description: "Queue a module reconcile on an instance. By DEFAULT this is an ordinary reconcile: it applies drift (a module assigned, removed, or pointed at a new version) and does nothing when the node already matches desired state. That is NOT sufficient to repair a root whose files were deleted underneath an UNCHANGED module version — the 2026-08-07 shape, where an empty artifact's hot-prune whiteout-deleted /usr/local/go and /usr/local/bin/gitleaks while the digest stayed the same. Nothing has drifted in that state, so a plain reconcile correctly concludes there is nothing to do. Pass force_resync: true to re-materialize a module's files regardless of drift; add module_id to narrow it to one module, or omit it to resync every module on the node. Recovery for that incident was a hand bind-mount over a root shell — force_resync is the supported, audited equivalent. Note it re-materializes from whatever version is CURRENT, so if the bad version is still current, roll it back first (system_rollback_module_version).",
            parameters: {
              instance_id:  { type: "string",  required: true,  description: "UUID of the NodeInstance whose modules to reconcile" },
              force_resync: { type: "boolean", required: false, description: "Re-materialize module files even when nothing has drifted. Default false." },
              module_id:    { type: "string",  required: false, description: "With force_resync, resync only this module — the platform NodeModule UUID, which is what the agent keys its attached-module state by (NOT the module slug; a slug is rejected as not-attached). Omit to resync every module on the node." }
            }
          },

          # === Instances ===
          "system_list_instances" => {
            description: "List instances (filterable by node_id or template_id)",
            parameters: {
              node_id: { type: "string", required: false, description: "Optional node UUID to list only that node's instances" },
              template_id: { type: "string", required: false, description: "Optional NodeTemplate UUID to list instances of nodes on that template" }
            }
          },
          "system_get_instance" => {
            description: "Fetch a node instance with its current status + metrics",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to fetch (account-scoped)" } }
          },
          "system_update_instance" => {
            description: "Update mutable NodeInstance metadata: name, description, config, and the IP address fields. " \
                         "Deliberately does NOT expose status/variety/key — status is governed by the AASM lifecycle (use the lifecycle actions), and key is encrypted signing material.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to update (account-scoped)" },
              name: { type: "string", required: false, description: "New display name for the instance" },
              description: { type: "string", required: false, description: "New free-text description for the instance" },
              config: { type: "object", required: false, description: "Instance config hash (replaces the stored config, except the network_profile_source provenance stamp, which survives unless the new hash explicitly sets it)" },
              private_ip_address: { type: "string", required: false, description: "Private/internal IP address of the instance" },
              public_ip_address: { type: "string", required: false, description: "Public IP address of the instance" },
              vpn_ip_address: { type: "string", required: false, description: "SDWAN/VPN overlay IP address of the instance" },
              network_profile: { type: "string", required: false, description: "SDWAN host profile: 'lightweight' (WireGuard-only stack, the default) or 'heavyweight' (adds the OVS/OVN chassis stack — requires ~4GB+ RAM headroom for the daemons). An explicit value is an operator declaration: it wins over and disables the first-heartbeat auto-classification." }
            }
          },
          "system_find_node_with_gpu" => {
            description: "Find live node instances that expose a GPU/accelerator, optionally filtered by gpu_type, a minimum per-GPU VRAM (min_gpu_memory_mb), and a minimum GPU count. GPU is resolved from the instance's provider_instance_type SKU or its agent-reported config[\"gpu\"] hint.",
            parameters: {
              gpu_type: { type: "string", required: false, description: "Filter to a specific GPU/accelerator type (case-insensitive, e.g. 'A100')" },
              min_gpu_memory_mb: { type: "integer", required: false, description: "Minimum per-GPU VRAM in megabytes the instance must have" },
              min_gpu_count: { type: "integer", required: false, description: "Minimum number of GPUs the instance must expose (defaults to 1)" }
            }
          },
          "system_list_instance_types_by_gpu" => {
            description: "List provider instance-type catalog SKUs that carry a GPU, optionally filtered by gpu_type and a minimum GPU count. Use to pick a GPU SKU for provisioning.",
            parameters: {
              gpu_type: { type: "string", required: false, description: "Filter SKUs to a specific GPU/accelerator type" },
              min_gpu_count: { type: "integer", required: false, description: "Minimum number of GPUs the SKU must carry (defaults to 1)" }
            }
          },
          "system_deploy_inference_server" => {
            description: "Deploy an inference runtime (ollama) onto a GPU node and make it consumable: assigns the gpu-<accelerator>-runtime + inference-ollama modules, registers an ollama Ai::Provider at the endpoint (active only once the endpoint answers a health probe — modules apply asynchronously, so re-deploy after the runtime is up to activate), and optionally publishes an SDWAN service offering. Targets a node by instance_id (must be live + GPU-capable unless force), or auto-selects via gpu_type/min_gpu_memory_mb. Pass endpoint_override to point at an existing ollama (e.g. for smoke).",
            parameters: {
              instance_id: { type: "string", required: false, description: "UUID of the target GPU NodeInstance; omit to auto-select via gpu_type/min_gpu_memory_mb" },
              gpu_type: { type: "string", required: false, description: "GPU/accelerator type to match when auto-selecting a target instance" },
              min_gpu_memory_mb: { type: "integer", required: false, description: "Minimum per-GPU VRAM (MB) when auto-selecting a target instance" },
              model: { type: "string", required: false, description: "Inference model tag to pull/serve on the ollama runtime" },
              endpoint_override: { type: "string", required: false, description: "Point the registered ollama provider at an existing endpoint URL instead of deploying (e.g. for smoke tests)" },
              sdwan_network_id: { type: "string", required: false, description: "UUID of an SDWAN network to publish the inference service offering on" },
              vip_cidr: { type: "string", required: false, description: "CIDR for the SDWAN virtual IP to front the published inference service" },
              accelerator: { type: "string", required: false, description: "Runtime accelerator family — selects the gpu-<accelerator>-runtime module (default nvidia)" },
              force: { type: "boolean", required: false, description: "Bypass the terminated/GPU gating on an explicit instance_id" }
            }
          },
          "system_grant_instance_mcp_tools" => {
            description: "Grant an instance-agent the MCP tool-name glob patterns it may invoke on the platform MCP (default-deny: an instance can call nothing until granted). Patterns match the 'platform.<tool>' name, e.g. 'platform.system_*_read' or 'platform.health'. mode: 'replace' (default) or 'add'. The instance must have announced as a peer.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the instance (announced peer) to grant MCP tool access to" },
              tool_patterns: { type: "array", required: true, description: "Glob patterns matching 'platform.<tool>' names the instance may invoke (e.g. ['platform.system_*_read'])" },
              mode: { type: "string", required: false, description: "'replace' (default) to overwrite the grant list, or 'add' to append" }
            }
          },
          "system_grant_instance_peer_skills" => {
            description: "A2A: grant an instance-agent the peer skill-name glob patterns it may invoke on OTHER instances via agent-to-agent MCP (default-deny). Patterns match a peer's offered skill name, e.g. 'embed-*' or 'summarize'. mode: 'replace' (default) or 'add'. The instance must have announced as a peer.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the instance (announced peer) to grant peer-skill call access to" },
              skill_patterns: { type: "array", required: true, description: "Glob patterns matching peer-offered skill names the instance may invoke via A2A (e.g. ['embed-*', 'summarize'])" },
              mode: { type: "string", required: false, description: "'replace' (default) to overwrite the grant list, or 'add' to append" }
            }
          },
          "system_discover_peers" => {
            description: "A2A: list the online, operator-enabled agent peers in the account and the skills they offer (capability discovery). Pass instance_id to discover from a specific caller's perspective (excludes itself). Discovery does not imply call permission — the call is still gated by system_authorize_peer_call.",
            parameters: {
              instance_id: { type: "string", required: false, description: "Optional caller instance UUID to discover from its perspective (excludes itself)" }
            }
          },
          "system_authorize_peer_call" => {
            description: "A2A: decide whether a caller instance may invoke a skill on a target instance via agent-to-agent MCP (three-gate, default-deny: caller granted + target online/enabled + target offers skill + same account). Returns { authorized, reason }. Consulted by the on-node A2A transport before relaying a call.",
            parameters: {
              caller_instance_id: { type: "string", required: true, description: "UUID of the instance attempting the A2A call" },
              target_instance_id: { type: "string", required: true, description: "UUID of the instance the skill would be invoked on" },
              skill: { type: "string", required: true, description: "Name of the peer skill the caller wants to invoke on the target" }
            }
          },
          "system_launch_agent_fleet" => {
            description: "L3: launch an agent-fleet orchestration mission — dynamically provision a fleet of agent-instances, grant them L2 (platform-MCP) + L2.5 (A2A) capabilities, delegate subtasks (hybrid coordinator + peer sub-delegation), aggregate, and reap. Creates an approval-gated Ai::Mission (mission_type: agent_fleet) bound to the system_agent_fleet template and starts it; the operator approves the review_fleet gate before any instances are provisioned. fleet_spec: { size, source('provision'|'pool'), node_id, provider_region_id, provider_instance_type_id, pool_name, grant_mcp_tools[], grant_peer_skills[], member_skills[], subtasks[{id,skill}], delegation('central'|'a2a'|'hybrid'), reap }.",
            parameters: {
              fleet_spec: { type: "object", required: true, description: "Fleet orchestration spec: { size, source, node_id, provider_region_id, provider_instance_type_id, pool_name, grant_mcp_tools[], grant_peer_skills[], member_skills[], subtasks[], delegation, reap }" },
              name: { type: "string", required: false, description: "Display name for the agent-fleet mission" },
              objective: { type: "string", required: false, description: "Free-text objective/goal for the fleet mission" }
            }
          },
          "system_agent_fleet_status" => {
            description: "L3: inspect an agent-fleet mission — returns status, current_phase, error_message, and a summary of the fleet (plan, member/assignment counts, aggregated report, per-member reap actions, reap_incomplete flag).",
            parameters: {
              mission_id: { type: "string", required: true, description: "UUID of the agent-fleet Ai::Mission to inspect" }
            }
          },
          "system_reap_agent_fleet" => {
            description: "L3: re-run reap for a failed/stuck agent-fleet mission — returns pool members, terminates provisioned members, disables their peers. Safe to retry; reports per-member actions and a reap_incomplete flag when any member fails to terminate. Pass force:true to reap a fleet whose plan disabled reaping.",
            parameters: {
              mission_id: { type: "string", required: true, description: "UUID of the agent-fleet Ai::Mission to re-reap" },
              force: { type: "boolean", required: false, description: "Reap even when the fleet plan set reap:false" }
            }
          },
          "system_mint_peer_capability_token" => {
            description: "A2A capability token minting — NOT AVAILABLE on this surface and always refuses, whatever arguments you send (IMP-27cc7dceb97b). A tool result is persisted with the conversation and forwarded to the model provider, so the token's envelope+signature pair (Ed25519 signing material) cannot be delivered here; nothing is minted and no argument changes that. To CHECK whether a call is permitted use system_authorize_peer_call, which runs the same PeerCapabilityService.authorize gates and returns no secret. To PERFORM a CROSS-instance call use system_launch_agent_fleet, which mints the caller->target token server-side inside the delegation descriptor. For a peer to run its OWN offered skill use POST /api/v1/system/node_instance_peers/<peer_id>/execute (needs system.peers.execute).",
            # Deliberately empty: the action refuses unconditionally, so
            # advertising required arguments would only have every model
            # assemble a call before learning it cannot work.
            parameters: {}
          },
          "system_list_isolation_tiers" => {
            description: "L0: list the isolation tiers an agent deployment can request (native | gvisor | kata | firecracker | vm) with their Docker runtime / K8s RuntimeClass mapping, isolation strength, overhead, and host requirements. Pass isolation_tier inside a fleet_spec (system_launch_agent_fleet) to select one (default native).",
            parameters: {}
          },
          "system_provision_instance" => {
            description: "Provision a new cloud instance for a node. SYNCHRONOUS: the call blocks on the " \
                         "provider until the instance row is created or the attempt fails, and it creates NO " \
                         "System::Task — there is no task_id. The MACHINE is still coming up when this " \
                         "returns: the returned status is the provider's create-time status, so poll " \
                         "system_get_instance for boot/enrollment readiness. " \
                         "On success returns provisioned:true and data:{instance:{id, status, ...}, " \
                         "cloud_instance_id} — the id names a real NodeInstance row and status is that row's " \
                         "state at return. On failure the provisioning has ALREADY failed: do not report it " \
                         "as started or in flight. A failure AFTER the row was created returns that same " \
                         "data:{instance, cloud_instance_id} beside the error, normally with the row moved to " \
                         ":error — read both, because a failed provision can strand a live billable cloud " \
                         "resource (system_terminate_instance reclaims it, and is itself approval-gated). A " \
                         "failure BEFORE any row exists — plan quota, unknown region/SKU, an unregistered or " \
                         "instance-incapable provider, an rcp_member_provisioning invariant violation — " \
                         "carries no data.instance. " \
                         "Agents SHOULD send a stable operation_id per logical request — retries carrying " \
                         "the same operation_id reuse the in-flight instance instead of provisioning a duplicate.",
            parameters: {
              node_id: { type: "string", required: true, description: "UUID of the node to provision a cloud instance for" },
              provider_region_id: { type: "string", required: true, description: "UUID of the ProviderRegion to place the instance in" },
              provider_instance_type_id: { type: "string", required: true, description: "UUID of the ProviderInstanceType (SKU) to provision" },
              operation_id: { type: "string", required: false,
                              description: "Stable idempotency key per logical provision request" },
              options: { type: "object", required: false, description: "Per-provider provisioning options passed through to the adapter" }
            }
          },
          "system_terminate_instance" => {
            description: "Terminate an instance (cleanly destroys cloud resource + transitions to :terminated). " \
                         "APPROVAL-GATED (system.task.terminate): when policy requires approval this returns " \
                         "{pending: true} with an approval_request_id and the instance is NOT terminated until " \
                         "an operator approves — do not report a completed termination on that response. " \
                         "Use system_destroy_instance to fully remove a registry row that has no live cloud resource.",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to terminate (destroys the cloud resource)" } }
          },
          # F4-08 — lifecycle control. Cloud + physical (SSH/IPMI) paths via
          # InstanceControlService; AASM start/stop/reboot events.
          "system_start_instance" => {
            description: "Start a stopped instance (cloud adapter or physical SSH/IPMI path). The restart counterpart to system_stop_instance.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to start" },
              operation_id: { type: "string", required: false, description: "System operation id to attribute this control action to" },
              force: { type: "boolean", required: false, description: "Force the start even if the instance is not in a cleanly stopped state" }
            }
          },
          "system_stop_instance" => {
            description: "Stop a running instance WITHOUT terminating it — disk and registry row are retained, compute billing stops on most cloud providers. The cost-control lever for idle GPU instances; restart with system_start_instance.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to stop" },
              operation_id: { type: "string", required: false, description: "System operation id to attribute this control action to" },
              force: { type: "boolean", required: false, description: "Force-stop the instance (hard power-off) instead of a graceful shutdown" }
            }
          },
          "system_reboot_instance" => {
            description: "Reboot a hung or misbehaving instance in place (no reprovision, addresses retained).",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to reboot" },
              operation_id: { type: "string", required: false, description: "System operation id to attribute this control action to" },
              force: { type: "boolean", required: false, description: "Force a hard reset instead of a graceful reboot" }
            }
          },
          "system_upgrade_boot_image" => {
            description: "Trigger an in-place boot-image (UKI) upgrade on a NodeInstance to its platform's currently " \
                         "promoted disk image (campaign 019f505f). Queues an agent task that pulls + cosign-verifies the " \
                         "target UKI, writes the ESP, and reboots — reusing the /persist cert (no re-enroll). Refuses if " \
                         "the platform has no promoted image or cosign trust is not configured. No-op if already current.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to upgrade" },
              force: { type: "boolean", required: false, description: "Queue the upgrade even if the node already reports the promoted git_sha" }
            }
          },
          "system_destroy_instance" => {
            description: "Hard-destroy a NodeInstance registry row, walking known FK dependents " \
                         "(sdwan_peers + sub-tables, system_bootstrap_tokens, system_node_certificates, " \
                         "system_node_modules, system_storage_assignments, billing_provisioning_usage_records, etc.). " \
                         "Use ONLY for ghost rows: cloud_instance_id is null OR the provider resource is already gone. " \
                         "Irreversible. Does NOT call the provider to destroy a live VM — pair with system_terminate_instance for that.",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance registry row to hard-destroy (ghost rows only)" } }
          },
          # IMP-b2f80e6d1c65 — operator ops hold (2026-07-27 incident response:
          # a start raced offline /persist maintenance on ops-hub 30s after
          # stop, truncating a blob under a dual mount). Blocks start/reboot/
          # terminate at the InstanceControlService choke point, pushed to the
          # provider where it can enforce. A LEASE, not a boolean — expiry
          # alerts but never auto-releases.
          "system_instance_hold" => {
            description: "Place an operator ops hold on a NodeInstance: blocks start/reboot/terminate while offline work happens on its disks, and enforces the block at the provider where supported. Records who placed it and why — an unattributed hold is indistinguishable from a bug later. Expiry alerts but never auto-releases; system_stop_instance and force do not override it.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to hold" },
              reason: { type: "string", required: true, description: "Why the hold is being placed, recorded on the instance for the next operator" },
              ttl_hours: { type: "number", required: false, description: "Advisory lease length in hours before the hold is reported expired (default 4)" }
            }
          },
          "system_instance_release_hold" => {
            description: "Release an operator ops hold placed by system_instance_hold, clearing the platform-side flag and any provider-side enforcement.",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the held NodeInstance to release" } }
          },
          "system_instance_hold_status" => {
            description: "Verify a NodeInstance's ops hold by reading provider state directly — never by attempting a start, which on a broken hold would start the very instance the operator needed stopped. Reports drift between what the platform recorded and what the provider actually enforces.",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to check" } }
          },

          # === Templates ===
          "system_list_templates" => {
            description: "List node templates for the current account, optionally narrowed by a name/description substring. For a purpose-based search ('something that serves web traffic') use system_discover_templates instead — this one is a literal filter.",
            parameters: {
              q: { type: "string", required: false, description: "Case-insensitive substring matched against template name OR description" }
            }
          },
          "system_get_template" => {
            description: "Fetch a template with its assigned modules",
            parameters: { template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to fetch (account-scoped)" } }
          },
          "system_assign_module_to_template" => {
            description: "Bind a NodeModule to a NodeTemplate (creates a TemplateModule join). Refuses the assignment when it would introduce an error-severity composition conflict (declared Conflicts: relation, or a second instance-variety module in one category) and names the modules involved; soft protected_spec overlaps come back under `warnings` without blocking. Assigning with enabled=false skips the conflict check, because a disabled join is not expanded onto any instance — enabling it later (system_update_template_module) is what runs the check. Separately, when the target template already carries LIVE nodes the assignment still succeeds but reports its blast radius under `blast_radius` (provisioned_node_count + reason) and records a `system.template_mutation` FleetEvent, because the change reaches those nodes on the template's next apply. Preview first with system_compose_preview_template.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to bind the module to" },
              module_id: { type: "string", required: true, description: "UUID of the NodeModule to assign to the template" },
              priority: { type: "number", required: false, description: "Compose order for this module within the template (higher first; default 0)" },
              enabled: { type: "boolean", required: false, description: "Whether the join ships (default true). false stages the assignment without expanding it onto instances — and skips the conflict check, since a disabled join cannot collide." },
              config: { type: "object", required: false, description: "Per-template config overlay, deep-merged over the module's own config at expansion time" },
              recommends_override: { type: "object", required: false, description: "Recommends resolution for this join: { replace: [...] } to set the exact list, or { included: [...], excluded: [...] } to adjust the module's defaults" }
            }
          },
          "system_update_template_module" => {
            description: "Update an EXISTING TemplateModule join in place: priority, enabled, config, recommends_override. This is the non-destructive way to take a module out of a template — set enabled=false rather than unassigning, because destroying the join nullifies source_template_module_id on every derived NodeModuleAssignment and permanently orphans them. Enabling a disabled join runs the same composition-conflict check as system_assign_module_to_template and refuses when it would introduce an error-severity conflict. Any edit to a join that ships (before or after the edit) on a template with live nodes reports `blast_radius` and records a `system.template_mutation` FleetEvent — disabling included, since that takes the module off live fleet. Omitted fields are left untouched; `config` and `recommends_override` REPLACE the stored hash rather than merging into it.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate holding the join (account-scoped)" },
              module_id: { type: "string", required: true, description: "UUID of the assigned NodeModule — the join is addressed by (template, module), matching system_assign_module_to_template" },
              priority: { type: "number", required: false, description: "New compose order for this module within the template (higher first)" },
              enabled: { type: "boolean", required: false, description: "false disables the join without destroying it (preserving priority/config and derived assignments); true re-enables it, subject to the conflict check" },
              config: { type: "object", required: false, description: "Per-template config overlay — REPLACES the stored hash" },
              recommends_override: { type: "object", required: false, description: "Recommends resolution ({ replace: [...] } or { included: [...], excluded: [...] }) — REPLACES the stored hash" }
            }
          },
          "system_compose_preview_template" => {
            description: "Design-time composition preview for a set of NodeModules — the same analysis the Visual Template Composer shows. Resolves the full dependency closure (explicit picks PLUS transitive requires/recommends) and returns the serialized modules, detected conflicts, footprint estimate, dependency graph, and resolver warnings/errors. Read-only: persists NOTHING, creates no template. Use it before system_create_template + system_assign_module_to_template to see conflicts the assignment path would refuse.",
            parameters: {
              module_ids: { type: "array", required: true, description: "UUIDs of the NodeModules to compose (account-scoped). The operator's explicit picks — dependencies are resolved automatically and flagged auto_resolved in the response." }
            }
          },

          # === Modules + Versions ===
          "system_list_modules" => {
            description: "List node modules (filterable by variety)",
            parameters: { options: { type: "object", required: false, description: "Filter options hash — supports { variety: '<variety>' } to filter modules by variety" } }
          },
          "system_get_module" => {
            description: "Fetch a module with its current_version + assignments",
            parameters: { module_id: { type: "string", required: true, description: "UUID of the NodeModule to fetch (account-scoped)" } }
          },
          "system_list_module_versions" => {
            description: "List versions of a module (newest first)",
            parameters: { module_id: { type: "string", required: true, description: "UUID of the NodeModule whose versions to list" } }
          },

          # === Catalog discovery (IMP-67aea0728774) ===
          "system_discover_modules" => {
            description: "Reuse-first module discovery — describe a PURPOSE ('reverse proxy with TLS', 'metrics scraper') and get existing modules ranked by semantic similarity, with a confidence bucket. Run this BEFORE authoring a new module (the module-authoring runbook's reuse gate). Use system_list_modules instead when you already know the name or just want to browse by variety. Ranking is pure vector similarity over persisted embeddings — there is no keyword fallback, so an unavailable embedding provider fails loudly rather than returning misleading matches. The `coverage` field reports how much of the searched catalog is actually embedded: an empty result with unembedded > 0 means NOT INDEXED, not 'nothing exists' (run rake system:catalog:backfill_embeddings). The `seed_count` field reports how many ranked candidates existed beyond the page you received (capped at top_k x3) — seed_count > results.size means the catalog had more to say, so re-ask with a larger top_k.",
            parameters: {
              intent: { type: "string", required: true, description: "Free-text description of the capability/purpose the module should serve" },
              top_k: { type: "integer", required: false, description: "Max results to return (1-#{::System::CatalogDiscoveryService::MAX_TOP_K}, default #{::System::CatalogDiscoveryService::DEFAULT_TOP_K})" },
              variety: { type: "string", required: false, description: "Restrict to a module variety: config | instance | subscription" },
              platform_id: { type: "string", required: false, description: "Restrict to modules for a specific NodePlatform" },
              include_disabled: { type: "boolean", required: false, description: "Include disabled modules in the search (default false)" }
            }
          },
          "system_discover_templates" => {
            description: "Reuse-first template discovery — describe a WORKLOAD ('public web serving stack', 'nightly batch runner') and get existing NodeTemplates ranked by semantic similarity, with a confidence bucket. A template's embedding folds in its assigned modules' names and descriptions, so the match reflects what the template actually composes, not just its name. Same no-keyword-fallback and `coverage` semantics as system_discover_modules. The `seed_count` field reports how many ranked candidates existed beyond the page you received (capped at top_k x3) — seed_count > results.size means the catalog had more to say, so re-ask with a larger top_k.",
            parameters: {
              intent: { type: "string", required: true, description: "Free-text description of the workload the template should serve" },
              top_k: { type: "integer", required: false, description: "Max results to return (1-#{::System::CatalogDiscoveryService::MAX_TOP_K}, default #{::System::CatalogDiscoveryService::DEFAULT_TOP_K})" },
              platform_id: { type: "string", required: false, description: "Restrict to templates for a specific NodePlatform" },
              include_disabled: { type: "boolean", required: false, description: "Include disabled templates in the search (default false)" }
            }
          },
          "system_promote_module_version" => {
            # IMP-65bea54e4081 — the description is the surface an agent reads
            # BEFORE calling, so the ladder/pointer split has to be stated here
            # too: correcting it only in the response teaches the caller after
            # it has already acted on "promote" meaning "ship it".
            description: "Promote a NodeModuleVersion through its lifecycle (staging|blessed|live|retired). " \
                         "Advances promotion_state ONLY — it does not change which version the fleet serves " \
                         "(NodeModule#current_version_id); check promoted_to_current in the response.",
            parameters: {
              module_version_id: { type: "string", required: true, description: "UUID of the NodeModuleVersion to promote" },
              target_state: { type: "string", required: true, description: "Target promotion state: staging | blessed | live | retired" }
            }
          },

          # === Reconcile / Drift ===
          "system_drift_report" => {
            description: "Compare a node instance's running modules vs assigned",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to compute module drift for" } }
          },

          # === Tasks ===
          "system_list_tasks" => {
            description: "List recent tasks (filterable by node_id or instance_id). Each task carries error_message — the stored failure reason, REDACTED of credential-shaped tokens and truncated to 300 chars on this surface; call system_get_task for the full redacted text.",
            parameters: {
              node_id: { type: "string", required: false, description: "Optional node UUID to list only tasks operating on that node" },
              instance_id: { type: "string", required: false, description: "Optional instance UUID to list only tasks operating on that instance" }
            }
          },
          "system_get_task" => {
            description: "Fetch a single System::Task by id (account-scoped). Returns the task's command, status, progress, operable handle, timestamps, and error_message — the full stored failure reason (16 KB cap, vs 300 chars on system_list_tasks), REDACTED of credential-shaped tokens since it carries raw build/shell output. Not-found errors when the id is unknown or belongs to another account.",
            parameters: { id: { type: "string", required: true, description: "UUID of the System::Task to fetch (account-scoped)" } }
          },
          "system_cancel_task" => {
            description: "Cancel a pending task",
            parameters: { id: { type: "string", required: true, description: "UUID of the pending System::Task to cancel" } }
          },
          # IMP-8153d1952ff8 — the abort AASM event (legal from :running) was
          # exposed only to the worker dispatch chain, leaving a wedged
          # provision/build/ssh task stuck for up to the reaper's 60-min
          # STUCK_RUNNING threshold with no operator recourse.
          "system_abort_task" => {
            description: "Abort a running task (operator recourse on a wedged provision/build/ssh task — errors once the task has already left :running)",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the running System::Task to abort" },
              reason: { type: "string", required: false, description: "Optional reason recorded on the task's error_message/audit events" }
            }
          },

          # === Module diff preview (Track F-11) ===
          "system_module_diff" => {
            description: "Compare two NodeModuleVersions and return added/removed files + package changes — preview before applying assignment changes",
            parameters: {
              version_a_id: { type: "string", required: true, description: "UUID of the first NodeModuleVersion (baseline) to compare" },
              version_b_id: { type: "string", required: true, description: "UUID of the second NodeModuleVersion (candidate) to compare" }
            }
          },

          # === Module publish diagnostics (IMP-b2f80e6d1c65 — 2026-07-27
          # incident: a one-off module held the canonical OCI repo binding, the
          # resolver matched the binding ahead of the name, and
          # ManifestImportService then refused the mismatch — a chain visible
          # nowhere until it produced a 422) ===
          "system_module_publish_target" => {
            description: "Preview where a CI publish for a module slug would land and whether the platform would accept it, without publishing anything. Resolves by name (the same rule ManifestImportService enforces) and flags when a DIFFERENT module holds the target OCI repo binding — drift to clear or rebind, not necessarily a blocker. Read-only: never runs the resolver's auto-create branch.",
            parameters: {
              module_name: { type: "string", required: true, description: "Module slug as CI would publish it" },
              gitea_repo: { type: "string", required: false, description: "OCI repo full name to check for a foreign binding; defaults to powernode/<module_name>" }
            }
          },
          "system_module_publication_integrity" => {
            description: "Detect artifacts that reached the OCI registry but were never recorded on the platform — a build that pushed + cosign-signed successfully, then failed to notify (bad token, wrong API base, unreachable platform, 422). Compares registry tags against recorded NodeModuleVersions. NOT a staleness sweep: source age is never consulted, so a module whose newest build predates its newest commit is normal and not reported. Omit module_name to check every module the platform believes CI publishes for (has a gitea_repo_full_name binding).",
            parameters: {
              module_name: { type: "string", required: false, description: "Restrict the check to a single module by name; omit to check all modules with a repo binding" }
            }
          },

          # === Platform deployment (D3) ===
          # Two-branch tool: with no `mode`, returns a wizard payload
          # the chat UI renders as an inline form. With full args, calls
          # the orchestrator and provisions the new platform.
          "system_deploy_platform" => {
            description: "Deploy a new Powernode platform. Two execution shapes: (1) call with no `mode` to receive a wizard-card payload describing the form fields the operator should fill in — the chat UI renders this inline; (2) call with mode 'standalone' plus full args (name, template_slug) to actually provision a sovereign platform. Federated deployment is NOT available on this surface — it mints a single-use acceptance token, and a tool result reaches the model provider and is persisted with the conversation, so the plaintext cannot be delivered here. Federated spawns go through the operator API (POST /api/v1/system/platform/deployments), which runs the same orchestrator and reveals the acceptance_token once in its HTTP response.",
            parameters: {
              mode: { type: "string", required: false,
                      description: "standalone. Omit to receive the wizard payload. 'federated' is refused on this surface with the operator path to use instead." },
              name: { type: "string", required: false,
                      description: "Display name for the new deployment (required when mode is set)." },
              template_slug: { type: "string", required: false,
                               description: "NodeTemplate to provision from (defaults to powernode-hub)." },
              parent_url: { type: "string", required: false,
                            description: "Federated-only — reachable URL of THIS platform. Supply it on the operator API path; federated mode is refused here." },
              spawn_mode: { type: "string", required: false,
                            description: "Federated-only — one of managed_child, autonomous_peer, cluster_member. Supply it on the operator API path; federated mode is refused here." },
              region: { type: "string", required: false, description: "Provider region to deploy the new platform into" },
              instance_size: { type: "string", required: false, description: "Instance size/SKU hint for the deployment's compute" },
              service_role: { type: "string", required: false, description: "Service role for the deployment (selects the workload profile)" },
              public_dns_hostname: { type: "string", required: false, description: "Public DNS hostname to assign to the new platform" }
            }
          },

          # === Storage volume CRUD (MCP.1) ===
          "system_list_volumes" => {
            description: "List storage volumes for the current account. Filter by status (available/in-use/etc), transport (nfs/iscsi/block), or attached node_instance_id.",
            parameters: {
              status: { type: "string", required: false, description: "Filter volumes by status (e.g. available, in-use)" },
              transport: { type: "string", required: false, description: "Filter volumes by transport (nfs | iscsi | smb | block)" },
              node_instance_id: { type: "string", required: false, description: "Filter to volumes attached to this NodeInstance UUID" },
              unattached_only: { type: "boolean", required: false, description: "When true, return only volumes not attached to any instance" }
            }
          },
          "system_get_volume" => {
            description: "Get full detail on a single storage volume — backing config (NFS server + export path / block device id), attachment state, ACL, capacity.",
            parameters: { id: { type: "string", required: true, description: "UUID of the ProviderVolume to fetch (account-scoped)" } }
          },
          "system_create_volume" => {
            description: "Register a new ProviderVolume. For NFS, pass transport=nfs + nfs_server + nfs_export_path. For block, pass volume_type_id. The platform records the row; on-node mounting happens at attach time.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new ProviderVolume" },
              size_gb: { type: "integer", required: true, description: "Volume capacity in gigabytes" },
              volume_type_id: { type: "string", required: false, description: "ProviderVolumeType id (skip if transport given — we'll find/create the matching type)" },
              transport: { type: "string", required: false, description: "nfs | iscsi | smb | block (default: block)" },
              nfs_server: { type: "string", required: false, description: "Required for transport=nfs — hostname or IP" },
              nfs_export_path: { type: "string", required: false, description: "Required for transport=nfs — path on the server" },
              nfs_version: { type: "string", required: false, description: "Optional — 3 | 4.0 | 4.1 | 4.2 (default 4.1)" },
              provider_id: { type: "string", required: false, description: "Which provider to bind the volume to. REQUIRED when the account has more than one provider — the platform refuses to guess and returns the candidate list" },
              provider_region_id: { type: "string", required: false, description: "Bind to a specific region (implies the provider; takes precedence over provider_id)" },
              description: { type: "string", required: false, description: "Free-text description for the volume" }
            }
          },
          "system_update_volume" => {
            description: "Update a ProviderVolume's mutable fields: name, description, size_gb, status.",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the ProviderVolume to update (account-scoped)" },
              name: { type: "string", required: false, description: "New display name for the volume" },
              description: { type: "string", required: false, description: "New free-text description for the volume" },
              size_gb: { type: "integer", required: false, description: "New volume capacity in gigabytes" },
              status: { type: "string", required: false, description: "New volume status" }
            }
          },
          "system_delete_volume" => {
            description: "Delete a ProviderVolume row. Refuses to delete if currently attached.",
            parameters: { id: { type: "string", required: true, description: "UUID of the ProviderVolume to delete (must be detached)" } }
          },
          "system_attach_volume" => {
            description: "Attach a ProviderVolume to a NodeInstance. For block: assigns next free /dev/vdX. For NFS pools: records the per-deployment binding without flipping pool status.",
            parameters: {
              volume_id: { type: "string", required: true, description: "UUID of the ProviderVolume to attach" },
              node_instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to attach the volume to" },
              deployment_name: { type: "string", required: false, description: "Used for the NFS subpath isolation when applicable" },
              role: { type: "string", required: false, description: "Service role (postgres / redis / etc.) — used for mount point + subpath" }
            }
          },
          "system_detach_volume" => {
            description: "Detach a ProviderVolume. For block volumes: clears node_instance_id + sets status=available. For NFS: clears the per-deployment binding only (pool remains available to other consumers).",
            parameters: {
              volume_id: { type: "string", required: true, description: "UUID of the ProviderVolume to detach" },
              node_instance_id: { type: "string", required: false, description: "Required for NFS volumes to identify which consumer binding to clear" }
            }
          },
          "system_test_nfs_export" => {
            description: "Probe an NFS server + export to verify reachability before recording a ProviderVolume. Runs DNS lookup + TCP probe on 111/2049 + showmount -e. Does NOT actually mount — that's safer when called from chat.",
            parameters: {
              server: { type: "string", required: true, description: "NFS server hostname or IP to probe" },
              export_path: { type: "string", required: false, description: "Optional — when omitted, returns the list of all advertised exports" }
            }
          },
          "system_get_storage_recommendations" => {
            description: "Read the platform-memory-stored storage recommendations — stateful role mount points + recommended size_gb per role. Falls back to defaults if no override exists.",
            parameters: {}
          },
          "system_update_storage_recommendations" => {
            description: "Update the platform-memory storage recommendations. Partial merge — only supplied keys override defaults. Example: { recommended_size_gb_by_role: { postgres: 200 } } leaves redis/etc untouched.",
            parameters: {
              recommendations: { type: "object", required: true, description: "Partial recommendations hash to merge — only supplied keys override defaults (e.g. { recommended_size_gb_by_role: { postgres: 200 } })" }
            }
          },
          "system_migrate_storage_component" => {
            description: "Records intent to migrate a stateful component's data from one ProviderVolume to another. Returns a migration plan (source subpath, target subpath, estimated bytes, recommended rsync command). v1 returns the plan only — actual rsync execution is a follow-up runbook.",
            parameters: {
              node_instance_id: { type: "string", required: true, description: "UUID of the NodeInstance whose stateful component is being migrated" },
              source_volume_id: { type: "string", required: true, description: "UUID of the ProviderVolume currently holding the data" },
              target_volume_id: { type: "string", required: true, description: "UUID of the ProviderVolume to migrate the data to (must differ from source)" },
              role: { type: "string", required: true, description: "Stateful component role being migrated (e.g. postgres, redis) — determines source/target subpaths" }
            }
          },
          # F8-05 — lifecycle of a StorageMigration created by
          # system_migrate_storage_component: operator approves, the on-node
          # agent reports progress/phase transitions, operator may cancel
          # before sync starts.
          "system_list_storage_migrations" => {
            description: "List storage migrations for the account (newest first, capped at 100). Filterable by status, node_instance_id, or active_only.",
            parameters: {
              status: { type: "string", required: false, description: "Filter by migration status" },
              node_instance_id: { type: "string", required: false, description: "Filter to migrations for this NodeInstance UUID" },
              active_only: { type: "boolean", required: false, description: "Only non-terminal migrations" }
            }
          },
          "system_get_storage_migration" => {
            description: "Fetch one storage migration with full details (plan, progress bytes, status history).",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to fetch (account-scoped)" }
            }
          },
          "system_approve_storage_migration" => {
            description: "Approve a planned storage migration so the on-node agent may begin the sync. Errors unless the migration can transition to 'approved'.",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to approve" }
            }
          },
          "system_cancel_storage_migration" => {
            description: "Cancel a storage migration before sync starts (allowed in planned/approved/preparing; errors once the sync is in progress or the migration is terminal).",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to cancel" },
              reason: { type: "string", required: false, description: "Optional reason recorded in the migration's audit log" }
            }
          },
          "system_report_storage_migration_progress" => {
            description: "Report sync progress for a storage migration (called by the on-node agent). Optionally advances status; records bytes copied/total/verified and a note.",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to report progress for" },
              status: { type: "string", required: false, description: "Optional phase transition (must be legal from the current status)" },
              bytes_copied: { type: "integer", required: false, description: "Bytes copied so far" },
              bytes_total: { type: "integer", required: false, description: "Total bytes to copy" },
              bytes_verified: { type: "integer", required: false, description: "Bytes verified after copy" },
              note: { type: "string", required: false, description: "Free-text progress note recorded in the audit log" }
            }
          },
          # Increment 9 (campaign 019f3458) — revert_binding! (R) / cleanup (C).
          "system_revert_storage_migration_binding" => {
            description: "Request the on-node agent re-point the consumer's canonical mount back to the SOURCE volume (inverse of cutover). Reachable from status=failed (any cutover-phase failure), or status=completed when promote_target_binding! silently failed (the half-cutover). Target data is left intact. Records intent only — the node does the actual mount work.",
            # DESCRIPTIVE ONLY — per improvement 019f34a3 ("requires_approval
            # is unenforced on the MCP tools/call dispatch path"), this flag
            # is not currently gated by the generic MCP dispatch layer (that
            # enforcement exists for BaseSkillExecutor-based skills, not raw
            # SystemFleetTool actions like this one). "Explicit operator
            # action" is enforced today the same way cleanup enforces it:
            # nothing in this codebase calls this automatically.
            requires_approval: true,
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to revert" },
              reason: { type: "string", required: false, description: "Optional reason recorded in the migration's audit log" }
            }
          },
          "system_cleanup_storage_migration" => {
            description: "DESTRUCTIVE — deletes the migration's target-side scratch artifacts only: the target_subpath partial copy + snapshot_subpath scratch + node transient mounts. NEVER touches source data, the source/target volume, or sibling subpaths. Reachable only from status=failed or status=cancelled (once preparing was reached). Explicit operator action — never auto-run on failure. Subject to a grace window (system.storage.migration.cleanup_grace_hours, SiteSetting/Account#settings-resolved, default 24h); pass immediate: true to override.",
            # DESCRIPTIVE ONLY — see system_revert_storage_migration_binding's
            # note on improvement 019f34a3. Do not read this flag as an
            # enforced access-control gate.
            requires_approval: true,
            parameters: {
              id: { type: "string", required: true, description: "UUID of the StorageMigration to clean up" },
              reason: { type: "string", required: false, description: "Optional reason recorded in the migration's audit log" },
              immediate: { type: "boolean", required: false, description: "Skip the cleanup grace window and clean up now" }
            }
          },

          # === Lifecycle skill wrappers (MCP.2) ===
          "system_platform_maintenance" => {
            description: "Wraps the platform_maintenance skill executor — op-discriminated: cert_status, cert_rotate, drift_check, health_check. Use `op:` for the sub-action; the MCP dispatcher already owns `action:`.",
            parameters: {
              op: { type: "string", required: true, description: "cert_status | cert_rotate | drift_check | health_check" },
              certificate_id: { type: "string", required: false, description: "UUID of the certificate to act on (for cert_status/cert_rotate)" },
              deployment_id: { type: "string", required: false, description: "UUID of the deployment to scope the maintenance op to" },
              renewal_window_days: { type: "integer", required: false, description: "Days-before-expiry window that flags a cert for rotation" }
            }
          },
          "system_platform_resilience" => {
            description: "Wraps the platform_resilience skill executor — op-discriminated: drain_instance, scale, failover_check.",
            parameters: {
              op: { type: "string", required: true, description: "drain_instance | scale | failover_check" },
              instance_id: { type: "string", required: false, description: "UUID of the instance to drain (for op=drain_instance)" },
              deployment_id: { type: "string", required: false, description: "UUID of the deployment to scale or check failover for" },
              direction: { type: "string", required: false, description: "set | increment | decrement (for op=scale)" },
              target_replicas: { type: "integer", required: false, description: "Replica count for op=scale (used when direction=set)" },
              timeout_seconds: { type: "integer", required: false, description: "Timeout in seconds for the resilience operation" }
            }
          },

          # === Compliance snapshot (M-D2-1) ===
          "system_compliance_snapshot" => {
            description: "Generate a complete compliance evidence document for the current account (nodes, instances, modules, certs, CVE exposures, drift, decisions)",
            parameters: {}
          },

          # === Runbook generation (Track F-16) ===
          "system_runbook_generate" => {
            description: "Generate an operational markdown runbook for a NodeTemplate — boot order, modules, common failure modes, recovery procedures",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to generate an operational runbook for" },
              persist_as_page: { type: "boolean", required: false, description: "When true, persist the generated runbook as a content Page" }
            }
          },

          # === CVE remediation runbook (Phase 10.7) ===
          "system_cve_runbook_generate" => {
            description: "Generate a markdown remediation runbook for a CVE — exposed modules, recommended steps, verification commands. Reads System::CveExposure for the current account.",
            parameters: {
              cve_id: { type: "string", required: true, description: "Canonical CVE id (e.g. CVE-2026-12345) to generate a remediation runbook for" },
              persist_as_page: { type: "boolean", required: false, description: "When true, persist the generated runbook as a content Page" }
            }
          },

          # === CVE triage (M-D2-2 partial) ===
          "system_cve_triage" => {
            description: "Triage a CVE entry against the fleet — risk-scored exposure list and remediation plan. Reads from System::CveExposure when persisted.",
            parameters: {
              cve_id: { type: "string", required: true, description: "Canonical CVE id (e.g. CVE-2026-12345) to triage against the fleet" },
              severity: { type: "string", required: true, description: "CVE severity: critical | high | medium | low | unknown" },
              affected_packages: { type: "array", required: true, description: "Affected package list, e.g. [{name: 'openssl', version: '<3.1.4'}, ...]" },
              persist: { type: "boolean", required: false, description: "Persist a System::Cve row + exposures" }
            }
          },

          # === Observability — recent FleetEvents ===
          "system_recent_signals" => {
            description: "Recent fleet observability events for this account (signals, decisions, ticks). Live feed available via SystemFleetChannel.",
            parameters: {
              limit: { type: "integer", required: false, description: "Max number of events to return (clamped to 1..200, default 50)" },
              kind: { type: "string", required: false, description: "Filter by event kind (e.g. 'system.module_drift')" },
              correlation_id: { type: "string", required: false, description: "Filter to events sharing this correlation id (takes precedence over kind)" }
            }
          },

          # === Attribution — what likely caused an instance failure ===
          "system_attribute_failure" => {
            description: "Given a NodeInstance, rank recent module changes + promotions by likelihood of being the cause of a failure",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance whose failure to attribute" },
              lookback_hours: { type: "integer", required: false, description: "How many hours back to consider module changes/promotions (default 24)" }
            }
          },

          # === Inspect one correlation chain (one tick or one decision) ===
          "system_inspect_correlation" => {
            description: "Walk every FleetEvent sharing a correlation_id — forensic deterministic replay of one tick or one decision flow",
            parameters: {
              correlation_id: { type: "string", required: true, description: "Correlation id whose FleetEvent chain to walk in emission order" }
            }
          },

          # === Slice 7 — pre-warmed instance pools ===
          "system_list_instance_pools" => {
            description: "List instance pools for the current account with size + occupancy stats",
            parameters: {}
          },
          "system_get_instance_pool" => {
            description: "Fetch a single instance pool with full member roster + counts",
            parameters: { id: { type: "string", required: true, description: "UUID of the InstancePool to fetch (account-scoped)" } }
          },
          "system_create_instance_pool" => {
            description: "Create a new pre-warmed instance pool. Reaper will provision target_size warming members on next tick.",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new instance pool" },
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate pool members are provisioned from (fixed at create time)" },
              target_size: { type: "integer", required: true, description: "Target number of warm+ready members" },
              min_size: { type: "integer", required: false, description: "Lower bound (default 0)" },
              max_size: { type: "integer", required: false, description: "Upper bound (default target+10)" },
              lifecycle_class: { type: "string", required: false, description: "ephemeral|spot (default ephemeral)" },
              provider_region_id: { type: "string", required: false, description: "UUID of the ProviderRegion pool members are provisioned in (single-AZ default)" },
              provider_instance_type_id: { type: "string", required: false, description: "UUID of the ProviderInstanceType (SKU) pool members are provisioned as" },
              preferred_regions: { type: "array", required: false, description: "Ordered list of ProviderRegion UUIDs for cross-AZ HA spread — replenishment round-robins members across them by slot and skips regions the sensor marks unhealthy. Overrides provider_region_id when set." }
            }
          },
          # F8-07 — REST update parity (instance_pools_controller update_params).
          # The runbook's pool-tuning operation: adjust min/max/target size,
          # status, region/type, metadata. node_template is NOT mutable on
          # update (create-only), matching the REST controller.
          "system_update_instance_pool" => {
            description: "Tune an existing instance pool: min_size/max_size/target_size, status, provider region/type, metadata. The reaper reconciles to the new sizes on its next tick. (Template is fixed at create time.)",
            parameters: {
              id: { type: "string", required: true, description: "UUID of the InstancePool to update (account-scoped)" },
              description: { type: "string", required: false, description: "New free-text description for the pool" },
              target_size: { type: "integer", required: false, description: "New target number of warm+ready members" },
              min_size: { type: "integer", required: false, description: "New lower bound on pool size" },
              max_size: { type: "integer", required: false, description: "New upper bound on pool size" },
              status: { type: "string", required: false, description: "active | paused | archived" },
              provider_region_id: { type: "string", required: false, description: "UUID of the ProviderRegion to provision future members in" },
              provider_instance_type_id: { type: "string", required: false, description: "UUID of the ProviderInstanceType (SKU) for future members" },
              preferred_regions: { type: "array", required: false, description: "Ordered list of ProviderRegion UUIDs for cross-AZ HA spread (replaces the pool's list; empty array clears it back to single-AZ)" },
              metadata: { type: "object", required: false, description: "Pool metadata hash (e.g. reuse_without_reset)" }
            }
          },
          "system_drain_instance_pool" => {
            description: "Mark a pool draining: terminate ready members, halt replenishment. Claimed members keep running.",
            parameters: { id: { type: "string", required: true, description: "UUID of the InstancePool to drain (account-scoped)" } }
          },
          "system_acquire_pooled_instance" => {
            description: "Atomically claim the oldest ready member from a pool. Returns the NodeInstance immediately (no provision wait).",
            parameters: {
              pool_name: { type: "string", required: false, description: "Specific pool to acquire from" },
              pool_id: { type: "string", required: false, description: "Specific pool by ID" },
              lifecycle_class: { type: "string", required: false, description: "Acquire from any matching pool when name/id absent (e.g. 'ephemeral')" }
            }
          },
          "system_replenish_instance_pool" => {
            description: "Manually trigger replenishment of a pool — provisions warming members up to target_size. Normally the reaper does this every 60s; this is for impatient operators.",
            parameters: { id: { type: "string", required: true, description: "UUID of the InstancePool to replenish (account-scoped)" } }
          },
          "system_recycle_pool" => {
            description: "Recycle stale members of a pool: warming members past warming_timeout_seconds become errored, ready members past ready_ttl_seconds become draining. Returns counts of transitions made. Normally the reaper does this every 60s before replenish; this is for impatient operators or for unwedging a pool that's stuck with zombie warming members blocking the deficit calculation.",
            parameters: { id: { type: "string", required: true, description: "UUID of the InstancePool to recycle stale members for (account-scoped)" } }
          },

          # === Gap remediation slice 1 (Phase 4) ===
          "system_drain_instance" => {
            description: "Initiate graceful drain on a NodeInstance: records drain intent + emits FleetEvent so observability tooling (and future autonomy reconcilers) can act. Workloads remain running; operator should call system_terminate_instance after relocation completes. Idempotent — calling twice updates drain_initiated_at.",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the NodeInstance to mark for graceful drain" },
              timeout_seconds: { type: "integer", required: false, description: "Suggested workload-relocation window (default 600 = 10 min). Stored in metadata for observability; does not auto-terminate." }
            }
          },
          "system_get_silent_instances" => {
            description: "List NodeInstances whose last_heartbeat_at is older than the SILENT_THRESHOLD (3 minutes), or null. Aligned with InstanceStatusSensor. Useful for fleet-health dashboards and pre-upgrade gates.",
            parameters: {
              threshold_seconds: { type: "integer", required: false, description: "Override the 3-minute default; useful for dashboards with custom alert thresholds" }
            }
          },
          "system_validate_module_manifest" => {
            description: "Validate a module manifest YAML against the schema (schema_version, name match, spec field types, init shape, reboot_required boolean) without committing to DB. Returns valid + validation_errors array. Use before pushing manifest changes to CI.",
            parameters: {
              module_id: { type: "string", required: true, description: "Existing NodeModule id to validate against (manifest.name must match)" },
              manifest_yaml: { type: "string", required: true, description: "Raw manifest.yaml contents" }
            }
          },

          # === Gap remediation slice 2 — CVE catalog + module assignment cleanup ===
          "system_get_cve" => {
            description: "Fetch a Cve by its canonical id (e.g. CVE-2026-12345). Cves are global across accounts.",
            parameters: { cve_id: { type: "string", required: true, description: "Canonical CVE id, format CVE-YYYY-NNNN (4+ digits)" } }
          },
          "system_get_cve_exposure" => {
            description: "Fetch the exposure breakdown for a CVE — exposed modules + per-module assignment counts, account-scoped via CveExposure → NodeModuleVersion → NodeModule.",
            parameters: { cve_id: { type: "string", required: true, description: "Canonical CVE id (e.g. CVE-2026-12345) to compute account exposure for" } }
          },
          "system_create_cve" => {
            description: "Manually inject a Cve row (typically for embargoed CVEs not yet in NVD, or for drill-mode runbooks). Idempotent via cve_id uniqueness — re-running updates fields. NOTE: Cve table is GLOBAL (not account-scoped) — created CVEs are visible to all accounts. Requires elevated system.fleet.autonomy permission.",
            parameters: {
              cve_id:            { type: "string", required: true,  description: "Canonical CVE id, format CVE-YYYY-NNNN (4+ digits). Drills should use high-numeric ids like CVE-2026-99001." },
              severity:          { type: "string", required: true,  description: "critical|high|medium|low|unknown" },
              summary:           { type: "string", required: false, description: "Short human-readable summary of the CVE" },
              affected_packages: { type: "array",  required: false, description: "[{name: 'openssl', version: '<3.1.4'}, ...]" },
              published_at:      { type: "string", required: false, description: "ISO8601; defaults to now" },
              reference_url:     { type: "string", required: false, description: "URL to the CVE advisory / reference" },
              feed_source:       { type: "string", required: false, description: "nvd|ghsa|manual (default manual)" }
            }
          },
          "system_delete_cve" => {
            description: "Destroy a Cve row + cascade-delete its CveExposures. Used for drill cleanup. Cves are global; deletion affects all accounts. Requires elevated system.fleet.autonomy permission.",
            parameters: { cve_id: { type: "string", required: true, description: "Canonical CVE id (e.g. CVE-2026-12345) of the global Cve row to delete" } }
          },
          "system_unassign_module_from_template" => {
            description: "Remove a NodeModule from a NodeTemplate (destroys the TemplateModule join). Inverse of system_assign_module_to_template. Idempotent — returns success even when the join doesn't exist. Removing a SHIPPING join from a template with live nodes reports `blast_radius` and records a `system.template_mutation` FleetEvent — it takes the module off every node on the template on next apply. Prefer system_update_template_module with enabled=false: destroying the join nullifies source_template_module_id on derived assignments and orphans them.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to remove the module from" },
              module_id:   { type: "string", required: true, description: "UUID of the NodeModule to unassign from the template" }
            }
          },
          "system_update_module_assignment" => {
            description: "Enable or disable a NodeModuleAssignment (per-(node, module) toggle). enabled=true enables the assignment; enabled=false disables it. The assignment row is preserved either way — disabling drops the module from neighbor union mounts / rsync_spec generation without losing priority/config. Mirrors the NodeModuleAssignmentsController enable/disable member actions. Idempotent.",
            parameters: {
              assignment_id: { type: "string", required: true, description: "UUID of the NodeModuleAssignment to enable/disable (account-scoped via its Node)" },
              enabled:       { type: "boolean", required: true, description: "true → enable, false → disable" }
            }
          },

          # === Gap remediation slice 3 — pool ops + canary marking ===
          "system_return_pooled_instance" => {
            description: "Return a claimed instance back to its pool. Default disposition is 'recycled': the member drains + terminates and the replenisher provisions a fresh one (no cross-mission data residue). Pools with metadata reuse_without_reset=true (same-trust-domain workloads only) instead re-mark the member 'ready' for reuse ('reused' disposition).",
            parameters: {
              instance_id: { type: "string", required: true, description: "UUID of the claimed pool NodeInstance to return to its pool" }
            }
          },
          "system_delete_instance_pool" => {
            description: "Destroy an empty InstancePool row. Errors when pool still has members — drain first via system_drain_instance_pool, then delete.",
            parameters: { id: { type: "string", required: true, description: "UUID of the empty InstancePool to delete (account-scoped)" } }
          },
          "system_module_mark_canary" => {
            description: "Mark a NodeModule as a honeypot canary (config['honeypot']['canary'] = true). Canary modules are decoys — any access triggers a high-severity FleetEvent via honeypot_access_sensor. Idempotent — re-marking is a no-op. RESTRICTED BY DESIGN: placing a decoy is an autonomy decision, so this takes the worker-only system.fleet.autonomy grant; clearing one via system_unmark_module_canary needs only system.modules.update.",
            parameters: {
              module_id: { type: "string", required: true, description: "UUID of the NodeModule to mark as a honeypot canary" },
              lure_kind: { type: "string", required: false, description: "Display label for the canary (default 'credential_store')" }
            }
          },

          # === Gap remediation slice 5 — disk image CI ===
          "system_list_disk_image_publications" => {
            description: "List DiskImagePublications for the account, optionally filtered by node_platform_id and/or status. Returns oldest-first by default.",
            parameters: {
              node_platform_id: { type: "string", required: false, description: "Filter publications to this NodePlatform UUID" },
              status: { type: "string", required: false, description: "queued|verifying|published|failed|retired" },
              limit: { type: "integer", required: false, description: "Default 50" }
            }
          },
          "system_set_default_disk_image_publication" => {
            description: "Promote a published DiskImagePublication as the platform's active disk image — copies its OCI ref + git SHA onto the parent NodePlatform so new instances boot from it. Errors if the publication is not in 'published' state.",
            parameters: {
              publication_id: { type: "string", required: true, description: "UUID of the published DiskImagePublication to set as the platform default" }
            }
          },
          "system_revert_disk_image" => {
            description: "Roll a NodePlatform's disk image back to a prior publication — restores the target publication's file_object onto the platform (and un-soft-deletes it if the target was retired), then retires the previously-active publication. With publication_id, rolls back to that specific publication; without it, auto-selects the most recent prior publication (the newest retired one, else the newest published one that isn't currently active). Refuses purged publications (FileObject hard-deleted) and publications with no file_object. Wraps System::Executors::DiskImage::RollbackPublication — the same transaction the DiskImagePublicationsController#rollback :proceed path uses.",
            parameters: {
              platform_id:    { type: "string", required: true, description: "System::NodePlatform id to roll back" },
              publication_id: { type: "string", required: false, description: "Target DiskImagePublication to restore. Omit to auto-select the previous publication." }
            }
          },
          "system_set_disk_image_retention" => {
            description: "Update the per-NodePlatform retention count (number of historical publications kept before the reaper purges).",
            parameters: {
              node_platform_id: { type: "string", required: true, description: "UUID of the NodePlatform whose disk-image retention count to set" },
              retention_count: { type: "integer", required: true, description: "Number of historical publications to retain (must be ≥1)" }
            }
          },
          "system_provision_ci_worker" => {
            description: "Provision a CI worker (a Worker with the 'ci_worker' role). Returns the worker record only. The plaintext token is NOT returned on this surface — a tool result is persisted with the conversation and forwarded to the model provider. Obtain the token exactly once via POST /api/v1/system/ci_workers/<id>/rotate_token (ungated, one response; needs system.ci_workers.rotate_token, which this action's permission does not imply).",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new CI worker" }
            }
          },
          "system_terminate_ci_worker" => {
            description: "Revoke a CI worker — destroys credentials + marks the worker as revoked. Operator can then unregister the corresponding Gitea Actions runner.",
            parameters: {
              worker_id: { type: "string", required: true, description: "UUID of the CI Worker to revoke (account-scoped)" }
            }
          },
          "system_list_ci_workers" => {
            description: "List CI workers (Workers with role='ci_worker') for the current account.",
            parameters: {}
          },
          "system_lease_ci_runner" => {
            description: "Lease an ephemeral Gitea Act runner from a builder pool: acquire a warm builder instance, correlate it to the Gitea runner it self-registered, and return the lease. The instance is recycled (terminate + backfill) on release so no state bleeds between jobs.",
            parameters: {
              pool_name: { type: "string", required: false, description: "Builder InstancePool name to acquire from (e.g. 'ci-builders-amd64'). One of pool_name/pool_id is required." },
              pool_id: { type: "string", required: false, description: "Builder InstancePool id (alternative to pool_name)" },
              purpose: { type: "string", required: false, description: "generic | module_build | disk_image_build (default generic) — selects the publish-arrival signal the reconciler waits on before release" },
              workflow_run_id: { type: "integer", required: false, description: "Gitea workflow run id this lease serves (set by the build orchestrator; drives auto-release when the run completes)" },
              workflow_run_repo: { type: "string", required: false, description: "owner/repo of the workflow run (needed to poll run state when workflow_run_id is set)" },
              correlate_timeout: { type: "integer", required: false, description: "Seconds to wait for the runner to correlate before returning (default from SiteSetting; 0 = single attempt, the reconciler finishes async)" }
            }
          },
          "system_release_ci_runner" => {
            description: "Release a CI runner lease: deregister the runner from Gitea and recycle its pooled instance (terminate + backfill). Refuses a busy runner unless force is set (never tears down a running build).",
            parameters: {
              lease_id: { type: "string", required: true, description: "UUID of the CiRunnerLease to release (account-scoped)" },
              force: { type: "boolean", required: false, description: "Release even if the runner is currently busy (default false)" }
            }
          },
          "system_list_ci_runner_leases" => {
            description: "List CI runner leases for the current account, optionally filtered by status or active-only.",
            parameters: {
              status: { type: "string", required: false, description: "Filter to a single lease status (leased/registered/busy/releasing/released/errored)" },
              active: { type: "boolean", required: false, description: "When true, return only active (non-terminal) leases" },
              limit: { type: "integer", required: false, description: "Max rows (default 50)" }
            }
          },
          "system_list_disk_image_webhooks" => {
            description: "List DiskImageWebhook rows for the current account (the inbound webhook receivers that ingest publications from Gitea Actions). Returns id, label, status and receive counters — no slice of the HMAC secret (IMP-27cc7dceb97b); the operator UI's secret_preview comes from the REST endpoint GET /api/v1/system/disk_image_webhooks instead.",
            parameters: {}
          },
          "system_dispatch_module_build_batch" => {
            description: "Plan + dispatch a native module-build batch for a base_sha..head_sha range: computes which modules need rebuilding (System::ModuleBuildPlannerService — or every module with force_all), creates the System::ModuleBuildBatch, and leases ephemeral module-forge builders to run each module's ci.module_build task (System::NativeModuleBuildOrchestrator#dispatch!). Returns the batch immediately — planning and the first dispatch pass are synchronous; build/sign/publish completion is tracked asynchronously via the batch's status (see system_list_tasks / system_get_task for the underlying ci.module_build tasks). This planner builds ONLY manifest-backed platform modules (those with a modules/<slug>/ tree); package-origin modules materialized from an upstream apt/rpm package build through a separate package-closure trigger and are never planned here even with force_all — the result lists any it dropped under excluded_modules[] (with a reason each) plus excluded_count, and system_refresh_package_module is how you rebuild those. Requires system.module_builds.dispatch, which core grants explicitly only to the system_worker role by design (bounds a leaked NON-admin token's blast radius) — so ordinary agent/operator principals are denied, but a system.admin holder CAN invoke it (User#has_permission? short-circuits on system.admin, before the role-grant exclusion is consulted). Confirmed live over MCP: an admin operator connector dispatches successfully.",
            parameters: {
              base_sha: { type: "string", required: true, description: "Pre-push commit SHA (diff base) the planner compares from" },
              head_sha: { type: "string", required: true, description: "Post-push commit SHA (diff head); also the source of each build's short tag" },
              force_all: { type: "boolean", required: false, description: "Skip the diff and plan every module with a manifest (manual full rebuild / CVE-driven sweep). Default false." },
              trigger: { type: "string", required: false, description: "push | manual | cve (default manual) — recorded on the batch for audit" },
              source_repo: { type: "string", required: false, description: "\"<owner>/<repo>\" the base_sha..head_sha diff is taken against (default: the ci_build_source_repo manifest repo). Pass the CORE repo (e.g. powernode/powernode-platform) for a core-change build so the planner diffs the tree the change actually lives in. Getting this wrong can no longer plan 0 silently: the shas are usually absent from the other repo (the compare fails and the error names the repo it diffed), and a core range whose paths match no CORE_PATH_MODULES rule now raises rather than reporting a successful build of nothing. A core range touching only docs/CI hygiene still plans 0 legitimately." }
            }
          },

          "system_rollback_module_version" => {
            description: "Repoint a module's current_version back to an earlier version after a bad publish — the undo for auto-promotion, and the forward-repoint when a good build was withheld. Publishing auto-promotes by DEFAULT, but not unconditionally: promotion is withheld when the module sets auto_promote false, when the artifact is below the non-empty floor, or when System::CoreProvenanceGate refuses its core provenance — each emits a high-severity system.module_promotion_withheld event naming the reason. So a build that completed while current_version_number did not move is not necessarily a promote bug: read that event FIRST. Passing an explicit version_id newer than the current one is the supported way to advance the fleet onto a version that was published but withheld. With version_id, rolls back to that specific version; without it, auto-selects the most recent version that is actually USABLE. That distinction is load-bearing: the version immediately preceding a bad build often carries oci_digest null (it was never published), so a naive roll-back-one would point the fleet at something the agent cannot mount — this walks back until it finds a version with a real artifact that also clears the non-empty floor. Refuses when no usable target exists, when the named version has no usable artifact, or when it belongs to another module. Note this changes which version the fleet RUNS; it does not delete or unpublish the bad version, and nodes converge on their next reconcile.",
            parameters: {
              module_id:  { type: "string", required: true,  description: "System::NodeModule id to roll back" },
              version_id: { type: "string", required: false, description: "Explicit System::NodeModuleVersion to roll back to. Omit to auto-select the most recent usable version." },
              reason:     { type: "string", required: false, description: "Operator-supplied reason, recorded in the log line for audit" }
            }
          },

          "system_cancel_module_build_batch" => {
            description: "Stop a running native module-build batch. This is the operator kill switch: it transitions the batch to `cancelled`, cancels every member ci.module_build task that has not already finished, releases the builder leases those tasks held, and — critically — prevents the orchestrator from leasing a builder for any still-queued module. Cancelling a single task via system_cancel_task does NOT stop a batch: the orchestrator advances on every task completion and simply dispatches the next queued module onto a fresh builder. Already-published module versions are NOT rolled back (a batch that published before you cancelled it has already promoted those versions — use the module rollback path for that); this stops further building only. Refuses when the batch has already reached a terminal state.",
            parameters: {
              batch_id: { type: "string", required: true,  description: "System::ModuleBuildBatch id to cancel" },
              reason:   { type: "string", required: false, description: "Operator-supplied reason, recorded on the batch's error_message for audit" }
            }
          },

          # === Missing-features slice 6a — GitOps reconciler MCP surface ===
          "system_gitops_register_repository" => {
            description: "Register a new GitopsRepository pointing at a git remote whose contents describe desired fleet state. The reconciler clones + pulls every 5 min by default; operator can trigger immediately via system_gitops_sync_repository.",
            parameters: {
              name:                  { type: "string",  required: true,  description: "Display name (must be unique within the account; max 64 chars)" },
              repo_url:              { type: "string",  required: true,  description: "HTTPS or SSH URL. Inline credentials (user:pass@) rejected — use vault_credential_path." },
              branch:                { type: "string",  required: false, description: "Default 'main'" },
              vault_credential_path: { type: "string",  required: false, description: "Vault KV path with deploy-key + username/password" },
              path_prefix:           { type: "string",  required: false, description: "Relative path within the repo where fleet.yaml lives (default: repo root)" },
              auto_apply:            { type: "boolean", required: false, description: "When true, approved proposals auto-apply on next reconcile (Phase 6b). Default false." }
            }
          },
          "system_gitops_sync_repository" => {
            description: "Trigger an immediate reconcile run for a registered repository. Creates a GitopsSyncRun row + opens proposals for any diffs found. The reconcile runs SYNCHRONOUSLY — `ok`, `diff_count`, `proposal_ids` and `error` are already final when this returns, so there is nothing to poll for. Returns `sync_run_id`: the id of the GitopsSyncRun this call finalized, for passing to system_gitops_get_sync_run to re-read the full record (timings, diff_summary, error_message) later. CAUTION: on a standby control plane the reconcile is skipped entirely and still returns ok:true with diff_count 0 and no error — indistinguishable from a repository that is fully in sync. Check `diff_summary` for a `skipped` marker before concluding the fleet matches the repo.",
            parameters: {
              id: { type: "string", required: true, description: "GitopsRepository id" }
            }
          },
          "system_gitops_get_sync_run" => {
            description: "Fetch the result of a sync run — diff_count, proposal_ids, status, error_message, diff_summary.",
            parameters: {
              sync_run_id: { type: "string", required: true, description: "UUID of the GitopsSyncRun to fetch the result of (account-scoped)" }
            }
          },
          "system_gitops_get_drift_report" => {
            description: "Compute current drift between a repository's desired state and live platform state — without opening proposals. Read-only diagnostic. Use before sync to preview what would change.",
            parameters: {
              id: { type: "string", required: true, description: "GitopsRepository id" }
            }
          },
          "system_gitops_list_repositories" => {
            description: "List every GitOps repository registered for this account, with the same projection system_gitops_get_repository returns. Use this to discover repository ids — no other verb reports them for a repository this caller did not itself register.",
            parameters: {}
          },
          "system_gitops_get_repository" => {
            description: "Read one registered GitOps repository's configuration and last-sync state: repo_url, branch, path_prefix, auto_apply, enabled, last_status/last_error/last_synced_at, and the credential contract — `vault_credential_path` (the Vault KV path the sync reads) and `required_credential_keys` (the key NAMES that path must carry for this remote's scheme). Key names and the path only, never credential values. To check whether that path actually resolves and holds those keys, use the REST probe POST /api/v1/admin_settings/vault/test { path:, required_keys: } — there is deliberately no MCP verb for it.",
            parameters: {
              id: { type: "string", required: true, description: "GitopsRepository id (account-scoped)" }
            }
          },

          # === Missing-features slice Vault DR-3 — pepper rotation ===
          "system_rotate_vault_transit_pepper" => {
            description: "Rotate the Vault transit pepper that wraps per-account encryption keys. Bumps the key version + walks all accounts with stale transit_key_version, re-wrapping each. Online operation. WARNING: cryptographic — review before invocation. Audit-logged.",
            parameters: {
              reencrypt_existing: { type: "boolean", required: false, description: "When false, only bumps the key version without walking accounts (operators may phase rotation manually). Default true." }
            }
          },

          # === Missing-features slice 6b — GitOps apply path ===
          "system_gitops_apply_proposal" => {
            description: "Apply an approved GitOps proposal — executes the diff against the DB (creates/updates templates, modules, assignments). Errors with stale_conflict if reality drifted post-proposal. v1 supports template/module/assignment kinds; destroy + provider_config remain follow-ups.",
            parameters: {
              proposal_id: { type: "string", required: true, description: "Ai::AgentProposal id (must be in 'approved' status with proposed_changes.source = 'gitops')" }
            }
          },

          # === Provider catalog ===
          "system_list_providers" => {
            description: "List providers for the current account with id, name, type, enabled, config.",
            parameters: {}
          },
          "system_get_provider" => {
            description: "Fetch a single provider with full config hash (used to inspect routed-mode host_node_instance_id wiring etc.).",
            parameters: {
              id: { type: "string", required: true, description: "System::Provider id" }
            }
          },
          "system_update_provider" => {
            description: "Update a provider — supports name + enabled + config. Config is merge-updated (existing keys preserved unless explicitly nilled). Use this to set host_node_instance_id on a routed-mode QEMU provider, swap the bridge_name, etc.",
            parameters: {
              id: { type: "string", required: true, description: "System::Provider id" },
              name: { type: "string", required: false, description: "New display name for the provider" },
              enabled: { type: "boolean", required: false, description: "Enable (true) or disable (false) the provider" },
              config: { type: "object", required: false, description: "Hash of config keys to merge. nil values delete the corresponding key." }
            }
          },
          "system_create_provider" => {
            description: "Create a substrate provider record (e.g. onboard a new local_qemu/libvirt host). OPERABLE PROVIDER TYPES IN THIS BUILD: #{::System::Providers::Registry.available_providers.join(', ')} — any other registered type is refused with a result naming the cloud SDK gem that is not bundled. Credentials are NOT accepted here — attach them afterwards via the Vault-backed provider credential flow (provider connections + BYOC credential test); secret material must never transit tool calls.",
            parameters: {
              name: { type: "string", required: true, description: "Unique provider name within the account" },
              provider_type: { type: "string", required: true, description: "Provider type slug — must be one of the operable types listed in this action's description. A registered-but-inoperable type is refused with a result naming the gem it needs." },
              description: { type: "string", required: false, description: "Free-text description for the provider" },
              enabled: { type: "boolean", required: false, description: "Defaults to true" },
              config: { type: "object", required: false, description: "Non-secret wiring config (e.g. host_node_instance_id, bridge_name)" }
            }
          },
          "system_delete_provider" => {
            description: "Delete a provider record. CASCADES: the provider's regions, connections, instance types, volume types and networks are destroyed with it — decommission instances first.",
            parameters: {
              id: { type: "string", required: true, description: "System::Provider id" }
            }
          },
          "system_create_provider_connection" => {
            description: "Create a ProviderConnection for a provider (status starts 'pending'). Refused with a result naming the missing cloud SDK gem when the provider's type is not operable in this build (same rule as system_create_provider). NO credential parameters are accepted — the adapter layer resolves keys from the Vault-encrypted BYOC ProviderCredential store (saved via the provider Credentials UI/REST) at use time. Set test_connection=true to immediately run the live credential test: on success the connection flips to 'connected' (required before Registry will use it for provisioning).",
            parameters: {
              provider_id: { type: "string", required: true, description: "System::Provider id (account-scoped)" },
              name: { type: "string", required: true, description: "Display name for the provider connection" },
              description: { type: "string", required: false, description: "Free-text description for the connection" },
              endpoint_url: { type: "string", required: false, description: "Provider API endpoint URL for this connection" },
              enabled: { type: "boolean", required: false, description: "Defaults to true" },
              config: { type: "object", required: false, description: "Non-secret wiring config only — never key material" },
              test_connection: { type: "boolean", required: false, description: "Run the live credential test after create (uses BYOC credentials)" }
            }
          },
          "system_create_provider_region" => {
            description: "Create a ProviderRegion under a provider — the placement target referenced by nodes/instances (provider_region_id).",
            parameters: {
              provider_id: { type: "string", required: true, description: "System::Provider id (account-scoped)" },
              name: { type: "string", required: true, description: "Display name for the provider region" },
              region_code: { type: "string", required: false, description: "Provider-native region identifier (e.g. us-east-1, lab-1)" },
              description: { type: "string", required: false, description: "Free-text description for the region" },
              endpoint_url: { type: "string", required: false, description: "Region-specific provider API endpoint URL" },
              enabled: { type: "boolean", required: false, description: "Defaults to true" },
              kernel_image: { type: "string", required: false, description: "Default kernel image reference for instances in this region" },
              machine_image: { type: "string", required: false, description: "Default machine (root disk) image reference for this region" },
              ramdisk_image: { type: "string", required: false, description: "Default ramdisk/initrd image reference for this region" },
              capabilities: { type: "object", required: false, description: "Region capability flags hash" }
            }
          },
          "system_create_provider_instance_type" => {
            description: "Create a ProviderInstanceType (SKU) under a provider — the sizing record referenced at provisioning (provider_instance_type_id).",
            parameters: {
              provider_id: { type: "string", required: true, description: "System::Provider id (account-scoped)" },
              name: { type: "string", required: true, description: "Display name for the instance type (SKU)" },
              instance_type_code: { type: "string", required: false, description: "Provider-native SKU code (e.g. t3.small)" },
              description: { type: "string", required: false, description: "Free-text description for the instance type" },
              vcpus: { type: "integer", required: false, description: "Number of virtual CPUs the SKU provides" },
              memory_mb: { type: "integer", required: false, description: "RAM in megabytes the SKU provides" },
              storage_gb: { type: "integer", required: false, description: "Root storage in gigabytes the SKU provides" },
              hourly_price: { type: "number", required: false, description: "Hourly price for the SKU in account currency" },
              enabled: { type: "boolean", required: false, description: "Defaults to true" },
              specs: { type: "object", required: false, description: "Extended sizing specs (gpu, accelerators, ...)" }
            }
          }
        }
      end

      def self.permitted?(agent:)
        return false unless defined?(::System)
        super
      end

      protected

      # SECURITY (IMP-e89d83547bad): give the instance deny overlay the name of
      # the work that ACTUALLY runs when this tool routes on its own key.
      #
      # An instance principal is authorized by TOOL NAME, and three separate
      # fences read the same :action key to keep the executed action pinned to
      # that name: Mcp::Principal#may_invoke? (first hop), McpPlatformTool
      # Registrar#enforce_action_scope! (pins params[:action]) and
      # Ai::Tools::BaseTool#enforce_instance_deny_overlay! (re-arms at every
      # hop, via BaseTool#effective_action_name, which reads params[:action]).
      #
      # This tool's two lifecycle-skill wrappers route on INNER_ACTION_KEYS
      # instead, so :action stays equal to the granted tool name and every one
      # of those fences saw only a benign composer:
      #
      #   system_platform_resilience  + op: "drain_instance"  -> *drain_*
      #   system_platform_maintenance + op: "cert_rotate"     -> *rotate*
      #
      # Both are names DESTRUCTIVE_TOOL_PATTERNS refuses unconditionally, and
      # neither executor nests a tool — PlatformResilienceExecutor and
      # PlatformMaintenanceExecutor mutate models/services directly — so the
      # nested-depth re-arm can never reach them. A FIRST-HOP gap, and the
      # unattributed destroy the overlay exists to stop: drain_instance stamps
      # config["drain_initiated_by_user_id"] = @user&.id, nil for an instance.
      #
      # Extension-local by construction. Core must never learn an extension's
      # param names (core NEVER depends on an extension), so the tool that
      # invented the key is the thing that must declare it.
      #
      # Returns the destroy-shaped inner op when there is one — so the refusal
      # names the work that would have run — and otherwise defers to the
      # default, leaving every other action's check byte-for-byte unchanged.
      # Checked for EVERY action, not just the two wrappers: a third one added
      # the same way is covered the day it ships, not the day someone
      # remembers. Costs nothing — the caller runs only for an instance
      # principal, and a benign op is simply not destroy-shaped.
      def effective_action_name(params)
        destructive_inner_action(params) || super
      end

      def destructive_inner_action(params)
        return nil unless params.is_a?(Hash)

        INNER_ACTION_KEYS.each do |key|
          value = (params[key] || params[key.to_s]).to_s
          next if value.empty?
          return value if ::Mcp::Principal.destructive_tool?(value)
        end
        nil
      end

      def call(params)
        return error_result(permission_denied_message(params[:action])) unless action_permitted?(params[:action])

        case params[:action]
        when "system_list_nodes"               then list_nodes(params)
        when "system_get_node"                 then get_node(params)
        when "system_create_node"              then create_node(params)
        when "system_update_node"              then update_node(params)
        when "system_delete_node"              then delete_node(params)
        when "system_create_template"          then create_template(params)
        when "system_clone_template"           then clone_template(params)
        when "system_delete_template"          then delete_template(params)
        when "system_update_template"          then update_template(params)
        when "system_create_module"            then create_module(params)
        when "system_update_module"            then update_module(params)
        when "system_unmark_module_canary"     then unmark_module_canary(params)
        when "system_delete_module"            then delete_module(params)
        when "system_refresh_instance_modules" then refresh_instance_modules(params)
        when "system_upgrade_boot_image"       then upgrade_boot_image(params)
        when "system_list_instances"           then list_instances(params)
        when "system_get_instance"             then get_instance(params)
        when "system_update_instance"          then update_instance(params)
        when "system_find_node_with_gpu"       then find_node_with_gpu(params)
        when "system_list_instance_types_by_gpu" then list_instance_types_by_gpu(params)
        when "system_deploy_inference_server"  then deploy_inference_server(params)
        when "system_grant_instance_mcp_tools" then grant_instance_mcp_tools(params)
        when "system_grant_instance_peer_skills" then grant_instance_peer_skills(params)
        when "system_discover_peers"           then discover_peers(params)
        when "system_authorize_peer_call"      then authorize_peer_call(params)
        when "system_launch_agent_fleet"       then launch_agent_fleet(params)
        when "system_agent_fleet_status"       then agent_fleet_status(params)
        when "system_reap_agent_fleet"         then reap_agent_fleet(params)
        when "system_mint_peer_capability_token" then mint_peer_capability_token(params)
        when "system_list_isolation_tiers"     then list_isolation_tiers(params)
        when "system_provision_instance"       then provision_instance(params)
        # Gate-routed (IMP-d410a587d6bf) — see declare_action at the top of the
        # class. This arm exists only so a direct #call fails loudly.
        when "system_terminate_instance"       then gate_routed_only("system_terminate_instance")
        when "system_start_instance"           then control_instance(params, "start")
        when "system_stop_instance"            then control_instance(params, "stop")
        when "system_reboot_instance"          then control_instance(params, "reboot")
        when "system_destroy_instance"         then destroy_instance(params)
        when "system_list_templates"           then list_templates(params)
        when "system_get_template"             then get_template(params)
        when "system_assign_module_to_template" then assign_module_to_template(params)
        when "system_update_template_module"   then update_template_module(params)
        when "system_compose_preview_template" then compose_preview_template(params)
        when "system_list_modules"             then list_modules(params)
        when "system_get_module"               then get_module(params)
        when "system_list_module_versions"     then list_module_versions(params)
        when "system_discover_modules"         then discover_modules(params)
        when "system_discover_templates"       then discover_templates(params)
        when "system_promote_module_version"   then promote_module_version(params)
        when "system_drift_report"             then drift_report(params)
        when "system_list_tasks"               then list_tasks(params)
        when "system_get_task"                 then get_task(params)
        when "system_cancel_task"              then cancel_task(params)
        when "system_abort_task"               then abort_task(params)
        when "system_module_diff"              then module_diff(params)
        when "system_module_publish_target"    then module_publish_target(params)
        when "system_module_publication_integrity" then module_publication_integrity(params)
        when "system_instance_hold_status"     then instance_hold_status(params)
        when "system_instance_hold"            then instance_hold(params)
        when "system_instance_release_hold"    then instance_release_hold(params)
        when "system_deploy_platform"          then deploy_platform(params)
        # Storage volume CRUD (MCP.1) — wraps ProviderVolume + ProviderVolumeType
        when "system_list_volumes"             then list_volumes(params)
        when "system_get_volume"               then get_volume(params)
        when "system_create_volume"            then create_volume(params)
        when "system_update_volume"            then update_volume(params)
        when "system_delete_volume"            then delete_volume(params)
        when "system_attach_volume"            then attach_volume(params)
        when "system_detach_volume"            then detach_volume(params)
        when "system_test_nfs_export"          then test_nfs_export(params)
        when "system_get_storage_recommendations"    then get_storage_recommendations
        when "system_update_storage_recommendations" then update_storage_recommendations(params)
        when "system_migrate_storage_component"      then migrate_storage_component(params)
        when "system_list_storage_migrations"        then list_storage_migrations(params)
        when "system_get_storage_migration"          then get_storage_migration(params)
        when "system_approve_storage_migration"      then approve_storage_migration(params)
        when "system_cancel_storage_migration"       then cancel_storage_migration(params)
        when "system_report_storage_migration_progress" then report_storage_migration_progress(params)
        when "system_revert_storage_migration_binding"   then revert_storage_migration_binding(params)
        when "system_cleanup_storage_migration"          then cleanup_storage_migration(params)
        # Lifecycle skill wrappers (MCP.2)
        when "system_platform_maintenance"     then platform_maintenance(params)
        when "system_platform_resilience"      then platform_resilience(params)
        when "system_compliance_snapshot"      then compliance_snapshot(params)
        when "system_runbook_generate"         then runbook_generate(params)
        when "system_cve_runbook_generate"     then cve_runbook_generate(params)
        when "system_cve_triage"               then cve_triage(params)
        when "system_recent_signals"           then recent_signals(params)
        when "system_attribute_failure"        then attribute_failure(params)
        when "system_inspect_correlation"      then inspect_correlation(params)
        # Slice 7 — instance pools
        when "system_list_instance_pools"      then list_instance_pools(params)
        when "system_get_instance_pool"        then get_instance_pool(params)
        when "system_create_instance_pool"     then create_instance_pool(params)
        when "system_update_instance_pool"     then update_instance_pool(params)
        when "system_drain_instance_pool"      then drain_instance_pool(params)
        when "system_acquire_pooled_instance"  then acquire_pooled_instance(params)
        when "system_replenish_instance_pool"  then replenish_instance_pool(params)
        when "system_recycle_pool"             then recycle_pool(params)
        # Gap remediation slice 1 (Phase 4)
        when "system_drain_instance"           then drain_instance(params)
        when "system_get_silent_instances"     then get_silent_instances(params)
        when "system_validate_module_manifest" then validate_module_manifest(params)
        # Gap remediation slice 2 — CVE catalog + module assignment cleanup
        when "system_get_cve"                       then get_cve(params)
        when "system_get_cve_exposure"              then get_cve_exposure(params)
        when "system_create_cve"                    then create_cve(params)
        when "system_delete_cve"                    then delete_cve(params)
        when "system_unassign_module_from_template" then unassign_module_from_template(params)
        when "system_update_module_assignment"      then update_module_assignment(params)
        # Gap remediation slice 3 — pool ops + canary marking
        when "system_return_pooled_instance"        then return_pooled_instance(params)
        when "system_delete_instance_pool"          then delete_instance_pool(params)
        when "system_module_mark_canary"            then module_mark_canary(params)
        # Gap remediation slice 5 — disk image CI
        when "system_list_disk_image_publications"  then list_disk_image_publications(params)
        when "system_set_default_disk_image_publication" then set_default_disk_image_publication(params)
        when "system_revert_disk_image"             then revert_disk_image(params)
        when "system_set_disk_image_retention"      then set_disk_image_retention(params)
        when "system_provision_ci_worker"           then provision_ci_worker(params)
        when "system_terminate_ci_worker"           then terminate_ci_worker(params)
        when "system_list_ci_workers"               then list_ci_workers(params)
        when "system_lease_ci_runner"               then lease_ci_runner(params)
        when "system_release_ci_runner"             then release_ci_runner(params)
        when "system_list_ci_runner_leases"         then list_ci_runner_leases(params)
        when "system_list_disk_image_webhooks"      then list_disk_image_webhooks(params)
        # Campaign 019f5885 inc9 — native module-build batch orchestration
        when "system_dispatch_module_build_batch"   then dispatch_module_build_batch(params)
        when "system_cancel_module_build_batch"     then cancel_module_build_batch(params)
        when "system_rollback_module_version"       then rollback_module_version(params)
        # Missing-features slice 6a — GitOps reconciler
        when "system_gitops_register_repository"    then gitops_register_repository(params)
        when "system_gitops_sync_repository"        then gitops_sync_repository(params)
        when "system_gitops_get_sync_run"           then gitops_get_sync_run(params)
        when "system_gitops_get_drift_report"       then gitops_get_drift_report(params)
        when "system_gitops_list_repositories"      then gitops_list_repositories(params)
        when "system_gitops_get_repository"         then gitops_get_repository(params)
        # Missing-features slice Vault DR-3
        when "system_rotate_vault_transit_pepper"   then rotate_vault_transit_pepper(params)
        # Missing-features slice 6b — GitOps apply path
        when "system_gitops_apply_proposal"         then gitops_apply_proposal(params)
        # Provider catalog
        when "system_list_providers"                then list_providers(params)
        when "system_get_provider"                  then get_provider(params)
        when "system_update_provider"               then update_provider(params)
        when "system_create_provider"               then create_provider(params)
        when "system_delete_provider"               then delete_provider(params)
        when "system_create_provider_connection"    then create_provider_connection(params)
        when "system_create_provider_region"        then create_provider_region(params)
        when "system_create_provider_instance_type" then create_provider_instance_type(params)
        else error_result("Unknown action: #{params[:action]}")
        end
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      rescue ArgumentError, ::System::NodeModuleVersion::InvalidTransition => e
        error_result(e.message)
      # === REFUSALS, not faults (IMP-a00997333d8f) ===
      #
      # Both classes below are REFUSALS: the platform will not do what was
      # asked, and repeating the call cannot change that. Without these clauses
      # they escaped #call to the core controller's generic handler
      # (StreamableHttpController's `rescue StandardError` in #handle_message,
      # streamable_http_controller.rb:137-139) and surfaced as JSON-RPC -32603
      # "Internal error: <message>" — a JSON-RPC ERROR object, with no `result`
      # at all and therefore no isError. An agent reads -32603 as a TRANSPORT
      # fault and retries; the retry raises identically, so a permanent,
      # operator-correctable condition produced repeated provisioning attempts
      # against the fleet with no explanation surfaced.
      #
      # What fixes that is returning a RESULT instead of an error object: the
      # same controller sets isError from #handle_tools_call's
      #   response_payload[:isError] = true if result.is_a?(Hash) && result[:success] == false
      # (streamable_http_controller.rb:693), and error_result's symbol-keyed
      # { success: false, error: } satisfies it. Same envelope defect the
      # sibling ::Ai::Introspection::RateLimiter::RateLimitExceeded clause in
      # that controller (:656-667) was added to fix, in the opposite DIRECTION:
      # rate limiting is genuinely retryable and was presented as fatal; these
      # are genuinely NOT retryable and were presented as a transient transport
      # fault. What the two share is only error_result's { success:, error: }
      # envelope — the discriminator KEYS differ (that clause uses
      # rate_limited:/retry_after:), so this is a parallel, not a shared
      # contract.
      #
      # refusal_code:/retryable: are ADVISORY: they name the condition for a
      # caller that chooses to read them. Nothing consumes either key today
      # (`command grep '\[:retryable\]'` finds no producer-side reader), so do
      # not credit them with stopping the loop — the result-vs-error-object
      # switch above is what does that. refusal_code:, not refusal:, because
      # Sdwan::FlowExporterDeployer already uses a `refusal:` key in this same
      # extension for a human-prose sentence or nil
      # (flow_exporter_deployer.rb:59-79, 100); one key with two value
      # contracts is exactly the ambiguity a machine-readable discriminator
      # exists to remove.
      #
      # Deliberately NOT a rescue of StandardError, and deliberately per-class: a
      # genuine internal fault (a NoMethodError in an action body, a provider
      # library blowing up) must keep reaching -32603, because it IS one. These
      # arms are global to #call's whole action `case`, so the narrowness is the
      # safety property: ProvisioningService funnels its own non-refusal failures
      # into a Runtime::Result (provisioning_service.rb:236-258) and re-raises
      # only these two plus ArgumentError past that rescue on purpose (:248-249).
      #
      # SCOPE — the PROVISION call site only. #assert_not_self_managed! has a
      # second call site, provisioning_service.rb:270 (terminate), which these
      # arms do NOT cover: system_terminate_instance is declare_action'd
      # mutating: true with an executor_class/gate_context (see :426 below), so
      # BaseTool#execute routes it through Ai::AutonomyGate and it never reaches
      # #call. Its violation is caught by AutonomyGate's own rescue and reaches
      # the caller as "Gate evaluation failed: <message>" — an application-level
      # result, so not the -32603 bug, but still labelled as a gate malfunction
      # rather than a refusal. Tracked separately; do not read these two arms as
      # covering the fence everywhere.
      #
      # ProvisioningError has exactly ONE raise site as of this commit —
      # ProvisioningService#validate_node!, provisioning_service.rb:359, "Node is
      # disabled" — so the class covers refusals only and this clause cannot
      # misclassify a fault. The NAME is generic enough that a future
      # fault-shaped raise would land here wrongly; if one is added, split it out
      # rather than widening this arm.
      rescue ::System::ProvisioningService::ProvisioningError => e
        error_result(e.message).merge(refusal_code: "provisioning_refused", retryable: false)
      # A hard architectural gate (RCP v2 INV-1): the control plane refusing to
      # act on its own hosting node. SelfManagementViolation's own declaration
      # (self_management_fence.rb:61-64) documents it as "a distinct, more severe
      # class of refusal" and made it a StandardError precisely so an
      # ArgumentError rescue would not swallow it — which is also why the clause
      # above does not cover it.
      rescue ::System::Autonomy::SelfManagementFence::SelfManagementViolation => e
        error_result(e.message).merge(refusal_code: "self_management_violation", retryable: false)
      end

      private

      # === Permission gating ===
      # Two bypasses, both EXPLICIT (IMP-9030413bc292):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — for those the
      #                        per-tool grant stands in for authorization. It is
      #                        NAME-scoped, though, and this tool runs the action
      #                        the caller supplies, so it does not bound WHICH
      #                        action runs. Treat it as provenance, not a fence.
      #
      # This used to be one implicit `@user.nil?` bypass, whose premise — that
      # MCP callers always carry a user — predates instance principals and is
      # false for them, so an instance skipped this map entirely (see the same
      # note in core Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS). A nil user
      # with neither flag now fails CLOSED rather than being read as internal.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      # IMP-9e01d1b48f7a — actions whose ACTION_PERMISSIONS entry is
      # deliberately excluded from every human-assignable role's explicit
      # grants (see server/config/permissions.rb's SYSTEM_PERMISSIONS comment
      # and PowernodeSystem::Engine's "Deliberately EXCLUDED" note), granted
      # only to the system_worker role by design to bound the blast radius of
      # a leaked NON-ADMIN token. That's a bound on explicit grants, not on
      # effective access: User#has_permission? short-circuits on system.admin
      # (see app/models/user.rb) and returns true for every permission name
      # before this exclusion is ever consulted, so the super_admin role —
      # the one role whose permissions array actually includes system.admin —
      # still passes action_permitted? for these actions. The plain
      # admin/owner account roles hold neither system.admin nor an explicit
      # grant here, so they're correctly denied (verified empirically, not
      # just by role name — see IMP-36a99b8167f7 in the spec). A denial for a
      # non-admin caller isn't a misconfiguration to fix — it's the intended
      # shape — so the message says so instead of reading like an outage.
      WORKER_ONLY_ACTIONS = {
        "system_dispatch_module_build_batch" => "granted only to the system_worker role by design (bounds a leaked non-admin token's blast radius); ordinary agent/operator principals cannot invoke this action — a system.admin holder still can, via the has_permission? short-circuit",
        # IMP-51296ff7208a — an offer proposed retargeting this to
        # system.modules.update to match REST's mark_canary. Refused: PLACING
        # a decoy is an autonomy decision, not ordinary module editing, and
        # this action is pinned as a deliberate exception in
        # system_fleet_tool_action_permission_spec's LEFT_ON_FLEET_AUTONOMY.
        # The gap was that the deliberate denial did not say it was
        # deliberate. Note the asymmetry is intended: CLEARING a canary
        # (system_unmark_module_canary) takes system.modules.update, so an
        # operator can always silence a decoy that is firing wrongly — REST
        # already permits exactly that, so nothing widens.
        "system_module_mark_canary" => "placing a honeypot decoy is an autonomy decision, so it is granted only to the system_worker role by design; clearing one (system_unmark_module_canary) needs just system.modules.update, which any module editor holds — a system.admin holder can still mark, via the has_permission? short-circuit"
      }.freeze

      def permission_denied_message(action)
        base = "permission denied: #{required_perm_for(action)} required"
        note = WORKER_ONLY_ACTIONS[action]
        note ? "#{base} — #{note}" : base
      end

      # === Nodes ===

      def list_nodes(params)
        scope = account_nodes
        scope = scope.where(node_template_id: params[:template_id]) if params[:template_id].present?
        success_result(
          nodes: scope.order(name: :asc).map { |n| serialize_node(n) },
          count: scope.size
        )
      end

      def get_node(params)
        node = account_nodes.find(params[:node_id])
        success_result(node: serialize_node_full(node))
      end

      # IMP-a5dcb7cfca0a — same surface as REST create (node_params minus
      # ssh_key/ssh_host_key, the F8-07 exclusion update_node documents).
      # Validation failures come back as clean envelopes via the call-level
      # RecordInvalid rescue.
      def create_node(params)
        template = account_templates.find(params[:template_id])
        attrs = params.slice(
          :description, :enabled, :worker_id,
          :public_address, :allocate_public_ip, :config
        ).to_h.compact
        node = ::System::Node.create!(
          attrs.merge(account: @account, node_template: template, name: params[:name])
        )
        success_result(node: serialize_node_full(node))
      end

      # F8-07 — REST update parity (nodes_controller node_params MINUS
      # ssh_key/ssh_host_key, which never flow through an MCP tool argument).
      def update_node(params)
        node = account_nodes.find(params[:node_id])
        attrs = params.slice(
          :name, :description, :enabled, :node_template_id, :worker_id,
          :public_address, :allocate_public_ip, :config
        ).to_h.compact
        return error_result("no mutable fields supplied") if attrs.empty?

        node.update!(attrs)
        success_result(node: serialize_node_full(node.reload))
      rescue ActiveRecord::RecordInvalid => e
        error_result("node validation failed: #{e.record.errors.full_messages.join('; ')}")
      end

      def delete_node(params)
        node = account_nodes.find(params[:node_id])
        name = node.name
        instance_count = node.node_instances.count
        node.destroy!
        success_result(deleted: true, node_id: params[:node_id], name: name, instances_cascaded: instance_count)
      rescue ActiveRecord::InvalidForeignKey => e
        error_result("FK blocks destroy — destroy underlying NodeInstances first via system_destroy_instance: #{e.message}")
      end

      # IMP-259f180d9af6 — the primitive that completes the reuse-first loop:
      # system_discover_templates finds a near-match and, without clone, the
      # agent had to rebuild it with create_template + N assignments.
      # composition_report rides the payload ONLY when non-empty, matching
      # node_templates_controller#clone: a clone copies joins wholesale, so a
      # conflict travels with it and becomes the baseline later assignments
      # must accept — the service reports rather than refusing, and that
      # report must not stop here (IMP-493db0e5c398 names why it is not
      # called "warnings").
      def clone_template(params)
        source = account_templates.find(params[:template_id])
        service = ::System::TemplateCloneService.new(source)
        clone = service.clone!(new_name: params[:name].presence)

        payload = { template: serialize_template(clone) }
        payload[:composition_report] = service.composition_report if service.composition_report.present?
        success_result(payload)
      rescue ::System::TemplateCloneService::CloneError => e
        error_result("Template clone failed: #{e.message}")
      end

      def delete_template(params)
        template = account_templates.find(params[:template_id])
        node_count = template.nodes.count
        if node_count > 0
          return error_result("Template '#{template.name}' is in use by #{node_count} node(s) — reassign or delete those nodes first")
        end
        name = template.name
        template.destroy!
        success_result(deleted: true, template_id: params[:template_id], name: name)
      end

      def create_template(params)
        # node_platform_id is not optional — System::NodeTemplate belongs_to
        # :node_platform and the column is NOT NULL. Caught here rather than
        # left to the model so the message names the PARAMETER the caller
        # passed; the model's own "Node platform must exist" reads like a
        # bad id when the real problem is an absent argument.
        if params[:node_platform_id].blank?
          return error_result("Template create failed: node_platform_id is required — " \
                              "every NodeTemplate binds to a NodePlatform")
        end

        template = account_templates.build(template_attrs(params))
        template.save!
        success_result(template: serialize_template(template))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Template create failed: #{e.record.errors.full_messages.join(', ')}")
      end

      # Accepts the same fields as create — anything set at create time stays
      # correctable. Previously only name/description landed here, so a
      # template created with the wrong config, admin_user, platform or
      # public flag could not be fixed over MCP at all.
      def update_template(params)
        template = account_templates.find(params[:template_id])
        template.update!(template_attrs(params))
        success_result(template: serialize_template(template))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Template update failed: #{e.record.errors.full_messages.join(', ')}")
      end

      # Mirrors NodeTemplatesController#template_params. Absent keys are
      # dropped rather than nil-assigned, so an update touches only what the
      # caller named; booleans test for nil so `false` is a real value.
      def template_attrs(params)
        attrs = {}
        attrs[:name]             = params[:name]             if params[:name].present?
        attrs[:description]      = params[:description]      if params[:description].present?
        attrs[:enabled]          = params[:enabled]          unless params[:enabled].nil?
        attrs[:public]           = params[:public]           unless params[:public].nil?
        attrs[:node_platform_id] = params[:node_platform_id] if params[:node_platform_id].present?
        attrs[:admin_user]       = params[:admin_user]       if params[:admin_user].present?
        attrs[:config]           = params[:config]           if params[:config].is_a?(Hash)
        attrs
      end

      # IMP-0cea3952202c — AI-first parity for the NodeModule resource. An
      # agent could delete a module it had no way to author or repair, and
      # system.modules.create was registered but referenced by no MCP action.
      # Mirrors node_modules_controller's node_module_params, minus
      # consent_budget_used_count / consent_budget_window_start_at: those are
      # the RUNTIME ledger the autonomy gate maintains, and letting an agent
      # write them would let it reset its own consumed budget. The ceiling
      # (consent_budget_per_day) stays settable — that is policy, not ledger.
      MODULE_WRITE_FIELDS = %i[
        name description variety enabled public priority
        node_platform_id category_id copy_path_id
        lock_spec init_start init_stop init_restart reboot_required
        mask file_spec package_spec dependency_spec protected_spec
        consent_budget_per_day config
        auto_promote
      ].freeze

      def module_attrs(params)
        params.slice(*MODULE_WRITE_FIELDS).to_h.compact
      end

      # IMP-01a02f4f3768 — this tool is the MCP twin of node_modules#create/
      # #update, and `config` here is written to NodeModule#config, which is
      # serialized VERBATIM to every node carrying the module and consumed
      # on-node (probe runner, attach-time security policy). The REST twin
      # gates that write through System::ModuleConfigValidator; an ungated
      # MCP path is strictly worse (the caller is an agent, not a human), so
      # both producers run the SAME shared validator.
      #
      # Mutates attrs: the config value is deep-stringified before validating
      # AND before writing, so the validator sees exactly what jsonb will
      # store — validating a stringified copy while writing symbol keys would
      # let a symbol-keyed "security" block slip past the grammar.
      #
      # `existing:` (update only) arms the downgrade-by-omission gate: config
      # is replaced wholesale, so omitting `security` / `verify` must be a
      # stated intent (explicit key, e.g. `"security": null`), never a side
      # effect of a partial payload. See ModuleConfigValidator's REMOVAL
      # CONTRACT.
      def module_config_gate_errors!(attrs, existing: nil)
        key = [ :config, "config" ].find { |k| attrs.key?(k) }
        return [] unless key

        raw = attrs[key]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw = raw.deep_stringify_keys if raw.is_a?(Hash)
        attrs[key] = raw

        errors = ::System::ModuleConfigValidator.errors_for(raw)
        if existing && raw.is_a?(Hash)
          errors += ::System::ModuleConfigValidator.removal_errors_for(raw, existing.config || {})
        end
        errors
      end

      # DB-relational columns a manifest.yaml does NOT carry — the only fields to
      # set directly when the caller supplies a manifest (which is authoritative
      # for everything else and gets applied by ManifestImportService).
      MODULE_RELATIONAL_FIELDS = %i[name node_platform_id category_id variety enabled public priority].freeze

      def create_module(params)
        yaml = params[:manifest_yaml].presence
        # The reuse gate runs BEFORE the row is built: a refused authoring
        # attempt must leave nothing behind, exactly like a rejected manifest.
        refusal, verified_reuse = reuse_gate(name: params[:name], yaml: yaml, params: params)
        return error_result(refusal) if refusal

        # With a manifest, set only the relational columns and let the importer
        # derive the spec/lifecycle fields — otherwise a manifest field and its
        # individual-param twin could disagree.
        base_attrs = yaml ? params.slice(*MODULE_RELATIONAL_FIELDS).to_h.compact : module_attrs(params)

        # Bare-field create is the path that writes `config` directly (with a
        # manifest, config is derived by the importer, which validates). Gate
        # BEFORE the row is built: a refused config must leave nothing behind.
        unless yaml
          config_errors = module_config_gate_errors!(base_attrs)
          return error_result("config failed module validation: #{config_errors.join('; ')}") if config_errors.any?
        end

        node_module = account_modules.build(base_attrs)
        node_module.save!

        return success_result(node_module: serialize_module_full(node_module)) unless yaml

        imported = import_module_manifest(node_module, yaml, params, default_create_version: true)
        unless imported[:ok]
          # A rejected manifest must leave no half-authored row behind.
          node_module.destroy
          return error_result("manifest import failed: #{imported[:error]}")
        end

        record_reuse_check(node_module, verified_reuse)

        payload = {
          node_module: serialize_module_full(node_module.reload),
          node_module_version_id: imported[:version_id],
          resolved_dependencies: imported[:resolved_dependencies]
        }
        disclosure = reuse_survey_disclosure(verified_reuse)
        payload[:reuse_survey] = disclosure if disclosure
        success_result(payload)
      end

      def update_module(params)
        node_module = account_modules.find(params[:module_id])
        yaml = params[:manifest_yaml].presence
        attrs = module_attrs(params)
        return error_result("no mutable fields supplied") if attrs.empty? && yaml.nil?

        # Same gate as create, because the same THING happens here whenever the
        # row is not yet buildable: a bare-field create followed by an update
        # carrying the manifest is the create path in two calls, and gating only
        # create would leave that as a one-hop bypass. Re-importing onto a name
        # the planner already builds (a CVE version bump) is not authoring and
        # is not gated.
        refusal, verified_reuse = reuse_gate(name: params[:name].presence || node_module.name,
                                             yaml: yaml, params: params)
        return error_result(refusal) if refusal

        # Same gate as create, plus the downgrade-by-omission check: update
        # replaces `config` WHOLESALE, so a payload omitting `security` /
        # `verify` while the module carries one must be refused rather than
        # silently stripping on-node confinement fleet-wide. Runs BEFORE the
        # write; the stored config must be untouched by a refused call.
        config_errors = module_config_gate_errors!(attrs, existing: node_module)
        return error_result("config failed module validation: #{config_errors.join('; ')}") if config_errors.any?

        node_module.update!(attrs) if attrs.any?

        if yaml
          imported = import_module_manifest(node_module, yaml, params, default_create_version: false)
          return error_result("manifest import failed: #{imported[:error]}") unless imported[:ok]
          record_reuse_check(node_module, verified_reuse)
        end

        payload = { node_module: serialize_module_full(node_module.reload) }
        disclosure = reuse_survey_disclosure(verified_reuse)
        payload[:reuse_survey] = disclosure if disclosure
        success_result(payload)
      end

      # IMP-a67be4fe9041 — the R1/R2/R3 reuse gate, enforced rather than advised.
      #
      # Manifest authoring over MCP landed 2026-08-06 (f65e72c7). The sprawl gate
      # it was supposed to pass did not land with it: R1/R2/R3 stayed prose in
      # docs/runbooks/module-authoring.md Phase 0 (addressed to a human) and
      # "run system_discover_modules first" stayed prose in this tool's own
      # action description (addressed to nobody the code can hold to it). An
      # agent could therefore mint a duplicate module with no reuse check.
      #
      # NOVELTY is not defined here. It is asked of
      # System::ModuleBuildPlannerService.buildable_module_names — the set the
      # build planner builds from. A manifest import that would ADD a name to
      # that set is authoring a new module; one that lands on a name already in
      # it is a re-import (a CVE bump) and is not gated. Bare-field creates are
      # not gated either: with no manifest the planner cannot build the row, so
      # nothing new is being authored yet.
      #
      # FALSIFIABILITY is the point. The declaration is not free text the caller
      # can fill with anything: every module it claims to have considered is
      # looked up in that same buildable set, so an invented candidate refuses
      # the call by name. A blank rationale, an unrecognised justification, and
      # "I considered nothing" against a non-empty catalog each refuse too.
      REUSE_JUSTIFICATIONS = %w[R1 R2 R3].freeze
      REUSE_RUNBOOK = "docs/runbooks/module-authoring.md Phase 0"

      # IMP-45bda04c6123 — the gate's own precondition, and the escape hatch.
      #
      # Everything the gate checked before this verified the SHAPE of the
      # declaration. Nothing verified that the survey it summarizes COULD have
      # found anything. `considered` is validated against the buildable name
      # set, but the ranking that actually surfaces an overlapping module runs
      # over embeddings, and on 2026-08-25 the live catalog held 42 buildable
      # modules and 0 embeddings. In that state system_discover_modules returns
      # [] for every intent, so the caller reports "no existing module covers
      # this" having searched an index that contains nothing — a positive signal
      # carrying no information, which is worse than no gate. Refusing is the
      # only outcome that keeps "found no overlap" distinguishable from "could
      # not have found one".
      #
      # REFUSE, not warn: the caller here is an agent, and a warning on a
      # successful call is a field nothing is obliged to read — the platform has
      # already been bitten by producer-set fields no consumer consults. The
      # refusal is the only form that cannot be ignored.
      #
      # But refusal alone would strand a deployment whose embedding provider is
      # unreachable (egress-restricted control planes make this ordinary, not
      # hypothetical) with no way to author a module at all. So the caller may
      # proceed by SAYING SO in the declaration, and that statement is persisted
      # with the coverage counts beside it — the record then reads as an
      # explicitly unverified reuse check rather than a clean bill of health.
      REUSE_UNINDEXED_ACK = "unindexed_catalog_ack"

      # Returns [refusal_message_or_nil, verified_declaration_or_nil].
      #
      # The declaration comes back ONLY when the gate actually ran and passed,
      # so nothing unverified is ever persisted: an ungated call (a re-import
      # onto an already-buildable name) may still carry a reuse_check field, and
      # it is ignored rather than recorded as though it had been checked.
      def reuse_gate(name:, yaml:, params:)
        return [ nil, nil ] if yaml.blank?
        # A missing name is the model's own validation to report, not the
        # gate's — refusing here would mask it with a reuse-check message.
        return [ nil, nil ] if name.blank?

        catalog = ::System::ModuleBuildPlannerService.buildable_module_names(@account)
        return [ nil, nil ] if catalog.include?(name.to_s)

        decl = normalize_hash(params[:reuse_check] || params["reuse_check"])
        unless decl
          return [ "authoring \"#{name}\" as a new buildable module requires a declared reuse check. Pass " \
                   "reuse_check: { considered: [{ module:, rejected_because: }], justification: " \
                   "\"R1\"|\"R2\"|\"R3\", justification_detail: } — run system_discover_modules by PURPOSE " \
                   "first, then say which existing modules you rejected and why (#{REUSE_RUNBOOK}).", nil ]
        end

        justification = decl["justification"].to_s.strip
        unless REUSE_JUSTIFICATIONS.include?(justification)
          return [ "reuse_check.justification must be one of R1, R2, R3 (got " \
                   "#{decl['justification'].inspect}) — R1 two or more real consumers or a hard requires: edge, " \
                   "R2 an independent third-party payload with its own CVE cadence, R3 an opt-in heavy payload a " \
                   "node type must be able to exclude. \"It completes a family\" is not a prong " \
                   "(#{REUSE_RUNBOOK}).", nil ]
        end

        if decl["justification_detail"].to_s.strip.empty?
          return [ "reuse_check.justification_detail must state HOW #{justification} is satisfied for " \
                   "\"#{name}\" (#{REUSE_RUNBOOK}).", nil ]
        end

        raw_considered = decl["considered"]
        raw_considered = [ raw_considered ] if raw_considered.is_a?(Hash)
        considered = Array(raw_considered).filter_map { |entry| normalize_hash(entry) }

        if considered.empty? && catalog.any?
          return [ "reuse_check.considered is empty, but #{catalog.size} buildable module(s) already exist in " \
                   "this account. Name the existing modules you evaluated and why each was rejected — " \
                   "system_discover_modules ranks them by purpose (#{REUSE_RUNBOOK}).", nil ]
        end

        unreasoned = considered.select { |entry| entry["rejected_because"].to_s.strip.empty? }
                               .map { |entry| entry["module"].to_s.presence || "(unnamed)" }
        if unreasoned.any?
          return [ "every reuse_check.considered entry needs a non-blank rejected_because — missing for: " \
                   "#{unreasoned.join(', ')}.", nil ]
        end

        # The check that makes the declaration falsifiable rather than
        # decorative: a considered module the catalog does not contain was not
        # considered, it was invented.
        unknown = considered.map { |entry| entry["module"].to_s }.reject { |candidate| catalog.include?(candidate) }
        if unknown.any?
          return [ "reuse_check.considered names module(s) that are not in this account's buildable catalog: " \
                   "#{unknown.join(', ')}. A reuse check is only meaningful if the candidates are real — list " \
                   "names returned by system_discover_modules / system_list_modules.", nil ]
        end

        # The coverage precondition runs LAST, after the declaration is
        # otherwise verified. Order matters for one reason: the refusal names
        # the `unindexed_catalog_ack` escape hatch, and running it earlier would
        # mean a caller whose declaration is pure garbage learns about the
        # bypass before it is told its justification is missing.
        coverage = reuse_catalog_coverage
        if (refusal = unsearchable_catalog_refusal(name: name, decl: decl, coverage: coverage))
          return [ refusal, nil ]
        end

        # The coverage stamp travels with the verified declaration so the
        # persisted record says what the catalog looked like when the survey
        # ran. Without it a survey of a searchable catalog and a survey of an
        # unsearchable one persist identically, and the whole finding is that
        # those two are indistinguishable after the fact.
        [ nil, decl.merge("considered" => considered, "catalog_coverage" => coverage) ]
      end

      # What the reuse survey could actually have seen.
      #
      # `total` is the buildable set — deliberately the same scope
      # ModuleBuildPlannerService.buildable_module_names uses, so this figure
      # always equals the `considered` universe the other prongs enforce.
      #
      # `searchable` is the subset system_discover_modules could actually rank,
      # and it is narrower than "has an embedding" in two ways that both matter:
      #
      #   * DISABLED modules are excluded, because CatalogDiscoveryService
      #     applies `.enabled` before ranking. A catalog of 42 embedded rows,
      #     40 of them disabled, reads as fully indexed while the survey ranked
      #     two — coverage measured as "has a vector" would call that healthy.
      #   * STALE rows are excluded (`embedding_stale`: never embedded, or
      #     edited after the vector was generated). The platform already learned
      #     that a catalog can read 100% embedded while every vector describes
      #     an older row — the backfill's own candidate scope is this same
      #     scope, and the coverage rake task reports `stale` as a first-class
      #     column for exactly this reason. A vector describing a module's
      #     previous purpose is not searchable for its current one.
      def reuse_catalog_coverage
        buildable  = ::System::NodeModule.where(account: @account).where.not(manifest_yaml: [ nil, "" ])
        total      = buildable.count
        return { "total" => 0, "embedded" => 0, "searchable" => 0 } if total.zero?

        {
          "total"      => total,
          "embedded"   => buildable.with_embedding.count,
          "searchable" => buildable.enabled.embedding_fresh.count
        }
      end

      # What CatalogDiscoveryService.discover_modules itself scopes over: every
      # ENABLED module, buildable or not — System::CatalogDiscoveryService
      # applies no manifest_yaml predicate. This is a DIFFERENT, wider
      # denominator than reuse_catalog_coverage's buildable-only figure, and
      # its own `coverage_for` reports this exact scope back to the caller as
      # the `coverage` field on system_discover_modules. Computed separately
      # (not folded into reuse_catalog_coverage) so the persisted
      # catalog_coverage audit stamp keeps its existing shape — this is only
      # ever surfaced in the refusal text, to let an operator reconcile the
      # two numbers instead of finding they simply disagree.
      def discovery_catalog_coverage
        scope = ::System::NodeModule.where(account: @account).enabled
        { "total" => scope.count, "embedded" => scope.with_embedding.count }
      end

      # Returns a refusal message, or nil when the survey could have been real.
      #
      # REFUSE AT ZERO, DISCLOSE ABOVE IT. Zero searchable modules is the state
      # in which the survey carries no information at all: system_discover_modules
      # returns [] for every intent, so "no existing module covers this" is not a
      # finding, it is the absence of one. Partial coverage is different in kind
      # — the survey did rank real candidates and the answer is informative, just
      # incomplete — so it is reported to the caller (see reuse_survey_disclosure)
      # and stamped on the module rather than refused. Refusing on any
      # unsearchable row would be untenable in practice anyway: nothing embeds a
      # NodeModule on save today, so every module authored through this gate
      # lands unsearchable, and a strict predicate would demand a backfill
      # between any two authorings and turn the escape hatch into the normal
      # path, destroying the signal it exists to carry.
      def unsearchable_catalog_refusal(name:, decl:, coverage:)
        # An EMPTY catalog is not an unsearchable one. A fresh account with no
        # buildable modules has nothing to survey and nothing to embed, and the
        # `considered.empty?` prong already lets that case through — refusing
        # here would make the first module in an account unauthorable.
        return nil unless coverage["total"].to_i.positive?
        return nil unless coverage["searchable"].to_i.zero?

        ack = decl[REUSE_UNINDEXED_ACK]
        # A String, specifically. `false`, `0` and `[]` are all `.present?`
        # once stringified, so a truthiness test would let a caller clear the
        # gate with a field whose plain reading is "no, I do not acknowledge"
        # — and would then persist that as the audit record's stated reason.
        return nil if ack.is_a?(String) && ack.strip.present?

        detail = if ack.nil?
                   ""
        else
                   " (reuse_check.#{REUSE_UNINDEXED_ACK} must be a non-blank STRING saying why; " \
                     "got #{ack.inspect})"
        end

        discovery = discovery_catalog_coverage

        "authoring \"#{name}\" cannot clear the reuse gate: none of the #{coverage['total']} buildable " \
          "module(s) in this account are searchable (#{coverage['embedded']} carry an embedding, 0 of those " \
          "are both enabled and current), so a survey scoped to the buildable catalog could not have " \
          "surfaced an overlapping BUILDABLE module — an empty survey against this catalog means NOT " \
          "INDEXED, not \"nothing buildable exists\". This does NOT mean system_discover_modules found " \
          "nothing at all: it ranks every enabled module regardless of buildability, #{discovery['total']} " \
          "enabled module(s) here (#{discovery['embedded']} carrying an embedding) — its own `coverage` " \
          "field reports THAT wider figure, not the buildable count above, so the two numbers will not " \
          "match; they answer different questions and neither one is wrong. Run " \
          "`rake system:catalog:backfill_embeddings` and re-check the `coverage` field on " \
          "system_discover_modules before authoring. If the embedding provider is unreachable and the module " \
          "must be authored anyway, pass reuse_check.#{REUSE_UNINDEXED_ACK}: \"<why>\" — the module is then " \
          "recorded as carrying an explicitly UNVERIFIED reuse check#{detail} (#{REUSE_RUNBOOK})."
      end

      # The partial-coverage half. A successful authoring says, in the response
      # the caller actually reads, how much of the catalog its survey could see
      # — so "found no overlap" is never reported without the denominator that
      # qualifies it. Nil when the survey saw everything (nothing to disclose)
      # or when no gate ran.
      def reuse_survey_disclosure(declaration)
        coverage = declaration.is_a?(Hash) ? declaration["catalog_coverage"] : nil
        return nil unless coverage.is_a?(Hash)

        total      = coverage["total"].to_i
        searchable = coverage["searchable"].to_i
        return nil if total.zero? || searchable >= total

        {
          searchable: searchable,
          total:      total,
          unsearchable: total - searchable,
          warning: "#{total - searchable} of #{total} buildable module(s) were NOT searchable when this " \
                   "reuse check ran (missing, stale, or disabled embeddings), so the survey behind it could " \
                   "not have surfaced an overlap in those. Run `rake system:catalog:backfill_embeddings` to " \
                   "close the gap.",
          acknowledged_unindexed: declaration[REUSE_UNINDEXED_ACK].is_a?(String) ? true : false
        }
      end


      # Persist the VERIFIED outcome on the module so the decision stays auditable
      # after the call that made it — the same config bag the platform already
      # uses for honeypot/last_build metadata.
      #
      # update_columns, NOT update!: `config` is in NodeModule::VERSIONED_ATTRIBUTES,
      # so a normal save here fires after_update :auto_create_version, which would
      # mint a second, artifact-less NodeModuleVersion and re-point current_version
      # at it — immediately after the manifest import deliberately suppressed that
      # very callback to snapshot one clean version. The audit stamp must not move
      # the module's current version.
      def record_reuse_check(node_module, declaration)
        return if declaration.blank?

        config = (node_module.config || {}).deep_dup
        config["reuse_check"] = declaration.deep_stringify_keys.merge("checked_at" => Time.current.iso8601)
        node_module.update_columns(config: config, updated_at: Time.current)
      end

      # MCP params arrive with either symbol or string keys (and possibly as
      # ActionController::Parameters); normalize to string-keyed plain hashes so
      # the gate reads the same value regardless of transport.
      def normalize_hash(value)
        value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        return nil unless value.is_a?(Hash)

        value.transform_keys(&:to_s)
      end

      # Apply a raw manifest.yaml through the SAME importer the loader seed and
      # the REST import_manifest endpoint use, so an MCP-authored/edited module
      # carries the authoritative manifest_yaml (+ derived spec/dependency rows).
      # This is the piece that was missing for end-to-end module authoring over
      # MCP: ModuleBuildPlannerService#known_module_names only builds modules with
      # a non-blank manifest_yaml, so a module created via bare fields alone was
      # invisible to the build planner.
      def import_module_manifest(node_module, yaml, params, default_create_version:)
        cv = params[:create_version]
        result = ::System::ManifestImportService.import!(
          node_module: node_module,
          yaml: yaml,
          create_version: cv.nil? ? default_create_version : ::ActiveModel::Type::Boolean.new.cast(cv),
          version_changelog: params[:version_changelog].presence
        )
        {
          ok: result.ok?,
          error: result.error,
          version_id: result.node_module_version&.id,
          resolved_dependencies: result.resolved_dependencies
        }
      end

      # The inverse of system_module_mark_canary, which had none — an agent
      # could set the honeypot flag and never clear it. Mirrors
      # node_modules_controller#unmark_canary: drop the honeypot key, leave
      # the rest of config alone.
      def unmark_module_canary(params)
        node_module = account_modules.find(params[:module_id])
        if node_module.config&.dig("honeypot")
          new_config = node_module.config.deep_dup
          new_config.delete("honeypot")
          node_module.update!(config: new_config)
        end
        success_result(unmarked: true, module_id: node_module.id,
                       module_name: node_module.name,
                       canary: ::System::Honeypot::CanaryModuleService.canary?(node_module: node_module.reload))
      end

      def delete_module(params)
        node_module = account_modules.find(params[:module_id])
        name = node_module.name
        versions = node_module.versions.count
        assignments = node_module.node_module_assignments.count
        node_module.destroy!
        success_result(deleted: true, module_id: params[:module_id], name: name,
                       versions_cascaded: versions, assignments_cascaded: assignments)
      rescue ActiveRecord::InvalidForeignKey => e
        error_result("FK blocks destroy: #{e.message}")
      end

      def refresh_instance_modules(params)
        instance = account_instances.find(params[:instance_id])
        force = params[:force_resync].to_s == "true" || params[:force_resync] == true
        module_id = params[:module_id].presence

        options = {
          "source" => force ? "mcp_resync" : "mcp_refresh",
          "triggered_by_user_id" => @user&.id,
          "triggered_at" => Time.current.iso8601
        }
        if force
          # The agent clears its attached-state stamps for this scope before
          # reconciling, so files are re-materialized even though nothing has
          # drifted. Without it, a root whose files were deleted underneath an
          # unchanged version is unrepairable by any platform action — the
          # 2026-08-07 incident was recovered by a hand bind-mount over a root
          # shell.
          options["force_resync"] = true
          options["module_id"] = module_id if module_id
        end

        task = ::System::Task.create!(
          account: @account, operable: instance,
          command: "sync_modules", status: "pending",
          initiated_by: @user,
          options: options
        )
        success_result(refreshed: true, resync: force, module_id: module_id,
                       instance_id: instance.id, task_id: task.id, task_status: task.status)
      rescue ActiveRecord::RecordInvalid => e
        error_result("Failed to queue refresh task: #{e.message}")
      end

      # Campaign 019f505f increment 2 — queue an in-place boot-image (UKI)
      # upgrade to the platform's currently-promoted disk image. The agent pulls
      # + cosign-verifies the target UKI, writes the ESP, and reboots. All the
      # fail-closed cosign/UKI guards live in System::BootImage::UpgradeDispatcher
      # (shared with the fleet drift-rollout executor) so an unverifiable boot
      # image can never be dispatched from either path.
      def upgrade_boot_image(params)
        instance = account_instances.find(params[:instance_id])
        force = params[:force].to_s == "true" || params[:force] == true
        result = ::System::BootImage::UpgradeDispatcher.dispatch!(
          instance: instance, source: "mcp_upgrade_boot_image", initiated_by: @user, force: force
        )
        return error_result(result.reason) unless result.ok?

        if result.already_current
          success_result(upgraded: false, already_current: true, instance_id: instance.id, git_sha: result.target_git_sha)
        elsif result.deduplicated
          success_result(upgraded: false, deduplicated: true, instance_id: instance.id,
                         task_id: result.task&.id, task_status: result.task&.status)
        else
          success_result(upgraded: true, instance_id: instance.id, task_id: result.task.id,
                         task_status: result.task.status, target_git_sha: result.target_git_sha)
        end
      end

      # === Instances ===

      def list_instances(params)
        scope = account_instances
        scope = scope.where(node_id: params[:node_id]) if params[:node_id].present?
        if params[:template_id].present?
          node_ids = account_nodes.where(node_template_id: params[:template_id]).pluck(:id)
          scope = scope.where(node_id: node_ids)
        end
        success_result(
          instances: scope.order(created_at: :desc).limit(200).map { |i| serialize_instance(i) },
          count: scope.size
        )
      end

      def get_instance(params)
        instance = account_instances.find(params[:instance_id])
        success_result(instance: serialize_instance_full(instance))
      end

      # Update mutable NodeInstance metadata. status/variety/key are
      # deliberately NOT in the safe attribute set — status transitions go
      # through the AASM lifecycle (system_terminate_instance, etc.), and key
      # is encrypted signing material.
      def update_instance(params)
        instance = account_instances.find(params[:instance_id])
        attrs = {}
        attrs[:name]               = params[:name]               if params[:name].present?
        attrs[:description]        = params[:description]        if params[:description].present?
        if params[:config].is_a?(Hash)
          incoming = params[:config].deep_stringify_keys
          # `config` replaces the stored hash, but the network_profile_source
          # stamp is PROVENANCE, not config: erasing it re-arms first-contact
          # auto-classification, which could then overwrite an explicit
          # operator declaration. It survives any replace that does not
          # explicitly supply its own value.
          existing_stamp = instance.config&.dig("network_profile_source")
          if existing_stamp.present? && !incoming.key?("network_profile_source")
            incoming = incoming.merge("network_profile_source" => existing_stamp)
          end
          attrs[:config] = incoming
        end
        attrs[:private_ip_address] = params[:private_ip_address] if params[:private_ip_address].present?
        attrs[:public_ip_address]  = params[:public_ip_address]  if params[:public_ip_address].present?
        attrs[:vpn_ip_address]     = params[:vpn_ip_address]     if params[:vpn_ip_address].present?

        # IMP-57e9a90598ee — the operator-declared network-profile writer.
        # Until this, the column had no production writer at all, so both OVN
        # serving gates were closed fleet-wide. An explicit value here is a
        # DECLARATION and wins over (and permanently disables) the
        # first-heartbeat auto-classification — recorded via the
        # network_profile_source stamp.
        if params[:network_profile].present?
          profile = params[:network_profile].to_s
          unless ::System::NodeInstance::NETWORK_PROFILES.include?(profile)
            return error_result(
              "network_profile must be one of: #{::System::NodeInstance::NETWORK_PROFILES.join(', ')} (got #{profile.inspect})"
            )
          end
          attrs[:network_profile] = profile
          attrs[:config] = (attrs[:config] || instance.config || {})
                             .merge("network_profile_source" => "operator")
        end

        instance.update!(attrs)
        success_result(instance: serialize_instance(instance))
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result("Instance update failed: #{e.record.errors.full_messages.join(', ')}")
      end

      # GPU discovery (audit P6). GPU is resolved per-instance from the
      # provider_instance_type SKU OR the agent's config["gpu"] hint, so the
      # type/count/vram predicate is applied in Ruby after eager-loading.
      #
      # The hint is produced by the on-node agent's boot-time inventory
      # (IMP-657e05418572, nvidia-smi → lspci, ingested by
      # NodeInstance#record_capabilities!). Bare-metal GPU nodes therefore
      # match an UNTYPED query (min_gpu_count alone) without a bound SKU.
      #
      # TWO KNOWN GAPS for agent-reported nodes, both in the predicate below:
      #   - gpu_type is compared with casecmp? — EXACT equality. The SKU
      #     vocabulary is short ("H100"); the agent reports the firmware's
      #     own string ("NVIDIA H100 PCIe", or "NVIDIA Corporation GA100" on
      #     the lspci path). So a gpu_type: filter still matches only
      #     SKU-bound nodes. Closing this needs either an agreed
      #     canonicalisation on ingest or token matching here — not yet done.
      #   - the lspci fallback cannot read VRAM at all, so such a node
      #     reports no gpu memory_mb and any min_gpu_memory_mb excludes it.
      # Scoped to non-terminated instances — you schedule GPU work on live
      # compute. A SQL/GIN pre-filter is a follow-up if fleet size ever makes
      # this scan material.
      def find_node_with_gpu(params)
        type      = params[:gpu_type].presence
        min_mem   = params[:min_gpu_memory_mb].to_i
        min_count = [ params[:min_gpu_count].to_i, 1 ].max

        matches = account_instances
                  .where.not(status: "terminated")
                  .includes(:provider_instance_type)
                  .select do |i|
                    i.gpu_count >= min_count &&
                      (type.nil? || i.gpu_type.to_s.casecmp?(type)) &&
                      (min_mem.zero? || i.gpu_memory_mb.to_i >= min_mem)
                  end

        success_result(instances: matches.map { |i| serialize_instance(i) }, count: matches.size)
      end

      # GPU catalog discovery (audit P6) — provider instance-type SKUs with a GPU.
      def list_instance_types_by_gpu(params)
        scope = ::System::ProviderInstanceType
                .where(account_id: @account.id)
                .by_gpu(params[:gpu_type].presence, min_count: [ params[:min_gpu_count].to_i, 1 ].max)
        success_result(
          instance_types: scope.order(:gpu_type, :gpu_count).map { |t| serialize_instance_type_gpu(t) },
          count: scope.size
        )
      end

      # Deploy an inference runtime (ollama) onto a GPU node + make it consumable
      # (AI/MCP workload substrate L1).
      def deploy_inference_server(params)
        instance = resolve_inference_target(params)
        return instance if instance.is_a?(Hash) # F4-13 explicit-target validation error
        return error_result("no GPU-capable instance found (pass instance_id, or gpu_type/min_gpu_memory_mb)") unless instance

        result = ::System::InferenceDeploymentService.deploy!(
          account: @account, instance: instance,
          # Carry this call's INSTANCE provenance across the service seam. The
          # service builds a skill executor, which is a hop the tool-side
          # funnel (#build_skill_executor) cannot reach from here — without
          # this the executor reads its nil user as a trusted in-process caller.
          # (IMP-c2e3e5d3cff0)
          instance_authorized: instance_authorized?, node_instance: node_instance,
          model: params[:model].presence,
          endpoint_override: params[:endpoint_override].presence,
          sdwan_network_id: params[:sdwan_network_id].presence,
          vip_cidr: params[:vip_cidr].presence,
          accelerator: params[:accelerator].presence
        )
        success_result(deployment: result.to_h)
      rescue ::System::InferenceDeploymentService::DeploymentError => e
        error_result(e.message)
      end

      # Pick the target GPU instance: explicit instance_id, else the first live
      # GPU-capable instance matching gpu_type / min_gpu_memory_mb.
      def resolve_inference_target(params)
        if params[:instance_id].present?
          instance = account_instances.find_by(id: params[:instance_id])
          return nil unless instance
          return instance if ::ActiveModel::Type::Boolean.new.cast(params[:force])

          # F4-13 — explicit targets get the same gating as discovery:
          # deploying to a terminated or GPU-less instance registers a dead
          # inference endpoint. force: true overrides for intentional cases.
          if instance.status == "terminated"
            return error_result("instance #{instance.id} is terminated — pass force: true to deploy anyway")
          end
          unless instance.gpu?
            return error_result("instance #{instance.id} has no GPU — pass force: true to deploy anyway")
          end

          return instance
        end

        type    = params[:gpu_type].presence
        min_mem = params[:min_gpu_memory_mb].to_i
        account_instances.where.not(status: "terminated").includes(:provider_instance_type).find do |i|
          i.gpu? &&
            (type.nil? || i.gpu_type.to_s.casecmp?(type)) &&
            (min_mem.zero? || i.gpu_memory_mb.to_i >= min_mem)
        end
      end

      # Grant an instance-agent the MCP tool-name glob patterns it may invoke
      # (default-deny authorization; AI/MCP workload substrate L2).
      def grant_instance_mcp_tools(params)
        instance = account_instances.find_by(id: params[:instance_id])
        return error_result("instance not found") unless instance

        peer = ::System::NodeInstancePeer.find_by(node_instance_id: instance.id)
        return error_result("instance has not announced as an agent peer yet") unless peer

        patterns = Array(params[:tool_patterns]).map(&:to_s).reject(&:blank?)
        return error_result("tool_patterns is required") if patterns.empty?

        refusal = grant_widening_refusal(peer: peer, incoming: patterns,
                                         current: peer.granted_mcp_tools,
                                         action: "system_grant_instance_mcp_tools",
                                         subject: "MCP tool")
        return refusal if refusal

        granted = peer.grant_mcp_tools!(patterns, mode: (params[:mode].to_s == "add" ? :add : :replace))
        success_result(instance_id: instance.id, granted_mcp_tools: granted,
                       session_notice: MCP_GRANT_SESSION_NOTICE)
      end

      # A2A: grant an instance-agent the peer skill-name glob patterns it may
      # invoke on OTHER instances (default-deny; AI/MCP workload substrate L2.5).
      def grant_instance_peer_skills(params)
        instance = account_instances.find_by(id: params[:instance_id])
        return error_result("instance not found") unless instance

        peer = ::System::NodeInstancePeer.find_by(node_instance_id: instance.id)
        return error_result("instance has not announced as an agent peer yet") unless peer

        patterns = Array(params[:skill_patterns]).map(&:to_s).reject(&:blank?)
        return error_result("skill_patterns is required") if patterns.empty?

        refusal = grant_widening_refusal(peer: peer, incoming: patterns,
                                         current: peer.granted_peer_skills,
                                         action: "system_grant_instance_peer_skills",
                                         subject: "peer skill")
        return refusal if refusal

        granted = peer.grant_peer_skills!(patterns, mode: (params[:mode].to_s == "add" ? :add : :replace))
        success_result(instance_id: instance.id, granted_peer_skills: granted)
      end

      # SECURITY (IMP-2110c94ad735) — a restricted principal may NARROW a grant,
      # never WIDEN one.
      #
      # For an instance principal the grant glob is documented as the only
      # remaining authorization control (core Mcp::Principal::
      # DESTRUCTIVE_TOOL_PATTERNS: "one over-broad pattern ... is an
      # unattributed, unapproved, unaudited destroy"). The two verbs that
      # REWRITE that grant are, however, ordinary tool names, and every fence
      # above them waves an instance through:
      #
      #   * destructive_tool?("...grant_instance_mcp_tools") is FALSE — the
      #     overlay has *revoke* for removal and nothing at all for widening;
      #   * McpPlatformToolRegistrar#enforce_permission! returns early for an
      #     instance, and #action_permitted? above does the same, so this
      #     action's ACTION_PERMISSIONS entry (system.node_instances.manage) is
      #     never consulted for one;
      #   * enforce_action_scope! pins the executed action to the INVOKED tool
      #     name — and here the invoked name IS the grant-rewriting one, so the
      #     pin holds and grants nothing back.
      #
      # The control was therefore self-mutable: an instance holding
      # `platform.system_*` could grant itself `platform.*` in one call and
      # unlock the whole non-destroy surface. This is the missing rung.
      #
      # DIRECTIONAL, not a blanket refusal of self-writes. Narrowing and
      # de-escalation stay open, so an agent that wants to SHED authority still
      # can (down to one pattern — the pre-existing "tool_patterns is required"
      # validation above still rejects an empty list, so this verb cannot express
      # a total self-revoke); only the widening direction is refused. That is
      # also why this cannot strand a RUNNING instance: no stored grant is read
      # differently, nothing is rewritten, and Mcp::Principal#may_invoke? is
      # untouched — the only behaviour that changes is that one class of WRITE
      # is refused.
      #
      # The operator lane is unaffected: a user principal holding
      # system.node_instances.manage, and an explicit in-process `internal:`
      # caller, both widen exactly as before. An operator working through an
      # INSTANCE-principal MCP session must now widen from a user principal.
      #
      # SCOPE, stated narrowly so nobody reads more coverage into it than it has:
      #
      #   * FIRST HOP ONLY, by design. This rung keys on instance_authorized?,
      #     which BaseTool#mark_instance_provenance carries across a skill-executor
      #     hop but which no OTHER construction sets. It is not the every-depth
      #     re-arm that enforce_instance_deny_overlay! is for the destroy overlay.
      #     An agent-invoked call runs as its CREATOR (a user principal) and is
      #     bounded by that user's permissions, not by this.
      #   * The dev-cell bootstrap floor is a DELIBERATE exception and stays open:
      #     System::DevCellBootstrapService#build_mcp calls the model directly with
      #     a fixed server-defined constant, so a cell re-bootstrapping itself is
      #     re-widened back to that baseline. Bounded (the list is not
      #     caller-supplied), and re-asserting a floor is not escalation past it.
      #
      # Extension-local by construction — core must never learn an extension's
      # models or param names, so the tool that owns the verb owns the rung.
      #
      # @return [Hash, nil] an error_result to refuse, nil to allow.
      def grant_widening_refusal(peer:, incoming:, current:, action:, subject:)
        return nil unless instance_authorized?

        # instance_authorized? is set for every RESTRICTED principal
        # (streamable_http_controller: `current_mcp_principal&.restricted?`),
        # which includes a federation partner — and federation carries no
        # node_instance. A restricted call with no provenance can prove no
        # ownership, so it fails closed rather than reaching the check below
        # with a nil to compare against.
        own = node_instance
        if own.nil?
          return grant_refusal(action, subject, peer,
                               "a restricted principal with no node identity may not rewrite a #{subject} grant")
        end

        unless peer.node_instance_id == own.id
          return grant_refusal(action, subject, peer,
                               "an instance principal may only rewrite its OWN #{subject} grant")
        end

        widened = Array(incoming).reject { |p| grant_pattern_covered?(current, p) }
        return nil if widened.empty?

        grant_refusal(action, subject, peer,
                      "an instance principal may narrow its own #{subject} grant but not widen it; " \
                      "#{widened.join(', ')} #{widened.one? ? 'is' : 'are'} not already authorized by it " \
                      "(express a narrowing as literal names, or as a tighter prefix under a held prefix glob)")
      end

      # LOUD, never raise. A refused escalation attempt is exactly the event an
      # operator needs to be able to QUERY afterwards — the deny overlay this
      # rung backstops is documented as the thing standing between an instance
      # and an "unattributed, unapproved, UNAUDITED" action, and a refusal that
      # exists only in stdout is unattributable in the same way. Same
      # "can't-block-but-can't-hide" shape as InstancePoolService#
      # reset_granted_mcp_tools!. EventBroadcaster.emit! is best-effort by
      # contract (it rescues StandardError and returns nil), so emitting here
      # cannot turn a clean refusal into a 500.
      def grant_refusal(action, subject, peer, reason)
        Rails.logger.warn(
          "[SystemFleetTool] Refused #{subject} grant widening for restricted principal: " \
          "action=#{action} caller_instance=#{node_instance&.id.inspect} " \
          "target_instance=#{peer&.node_instance_id.inspect} reason=#{reason}"
        )

        ::System::Fleet::EventBroadcaster.emit!(
          account: @account,
          kind: "system.mcp_grant_widening_refused",
          severity: :high,
          source: "system_fleet_tool",
          node_instance_id: node_instance&.id,
          payload: {
            "action" => action, "subject" => subject, "reason" => reason,
            "caller_instance_id" => node_instance&.id,
            "target_instance_id" => peer&.node_instance_id
          }
        )

        error_result("#{action} denied: #{reason}")
      end

      # Everything File.fnmatch(..., FNM_EXTGLOB) gives meaning to beyond plain
      # text. The backslash is in here for the ESCAPE it introduces, not for a
      # wildcard: a held pattern like "platform.\*" matches only the literal
      # name "platform.*", so treating "platform.\" as a covering prefix would
      # certify strings it does not actually match. Counting the escape as a
      # metacharacter keeps the prefix rule (case 2 below) honest.
      GRANT_GLOB_META = /[*?\[\]{}\\]/

      # Is `incoming` guaranteed to authorize NOTHING that `current` does not
      # already authorize? Deliberately conservative — it answers "definitely
      # not wider", never "probably not wider", so a pattern it cannot prove
      # safe is refused rather than allowed. Three sound cases:
      #
      #   1. exact re-statement of a pattern already held;
      #   2. a held glob-free PREFIX glob ("platform.system_*") covers anything
      #      whose text starts with that prefix — including narrower globs
      #      ("platform.system_get_*"), since every name the narrower one
      #      matches necessarily starts with the wider prefix too;
      #   3. a LITERAL incoming name (no metacharacters, so it matches exactly
      #      itself) that a held pattern already matches.
      #
      # Case 2 is what keeps the "collapse a broad glob into a tighter one"
      # de-escalation working; without it, narrowing would only be expressible
      # as a list of literal tool names.
      #
      # Case 2 carries ONE correction. fnmatch is not passed FNM_DOTMATCH (not
      # here, not in Mcp::Principal#may_invoke?, not in NodeInstancePeer#
      # may_invoke_peer_skill?), so a wildcard does NOT match a leading period:
      # `fnmatch("*", ".x")` is false while `fnmatch(".x", ".x")` is true. A
      # held `*` would therefore be certified as covering `.x` — a name `*`
      # cannot actually authorize, which is a widening however small. Only the
      # FIRST character is special without FNM_PATHNAME, so requiring the held
      # prefix to lead with the same period closes it exactly.
      def grant_pattern_covered?(current, incoming)
        incoming = incoming.to_s
        incoming_literal = !incoming.match?(GRANT_GLOB_META)

        Array(current).any? do |held|
          held = held.to_s
          next true if held == incoming

          if held.end_with?("*")
            prefix = held[0..-2]
            dot_safe = !incoming.start_with?(".") || prefix.start_with?(".")
            next true if dot_safe && !prefix.match?(GRANT_GLOB_META) && incoming.start_with?(prefix)
          end

          incoming_literal && ::File.fnmatch(held, incoming, ::File::FNM_EXTGLOB)
        end
      end

      # A2A: discover online, operator-enabled peers + the skills they offer.
      def discover_peers(params)
        caller_peer = nil
        if params[:instance_id].present?
          inst = account_instances.find_by(id: params[:instance_id])
          caller_peer = ::System::NodeInstancePeer.find_by(node_instance_id: inst.id) if inst
        end

        peers = ::System::PeerCapabilityService.discoverable_for(account: @account, caller_peer: caller_peer)
        success_result(peers: peers, count: peers.size)
      end

      # A2A: authorize a peer-to-peer skill call (three-gate, default-deny).
      def authorize_peer_call(params)
        caller_inst = account_instances.find_by(id: params[:caller_instance_id])
        target_inst = account_instances.find_by(id: params[:target_instance_id])
        return error_result("caller or target instance not found") unless caller_inst && target_inst

        caller_peer = ::System::NodeInstancePeer.find_by(node_instance_id: caller_inst.id)
        target_peer = ::System::NodeInstancePeer.find_by(node_instance_id: target_inst.id)
        return error_result("caller or target has not announced as a peer") unless caller_peer && target_peer

        decision = ::System::PeerCapabilityService.authorize(
          caller_peer: caller_peer, target_peer: target_peer, skill: params[:skill].to_s
        )
        success_result(authorized: decision.authorized, reason: decision.reason)
      end

      # L3: create + start an agent-fleet orchestration mission. Binds the
      # system_agent_fleet template and stores the operator's fleet_spec, then
      # OrchestratorService#start! dispatches the plan_fleet phase. The mission
      # stops at the review_fleet gate for operator approval before any
      # instances are provisioned.
      def launch_agent_fleet(params)
        return error_result("user context required to launch an agent fleet") unless @user

        spec = params[:fleet_spec] || params["fleet_spec"]
        return error_result("fleet_spec (object) is required") unless spec.is_a?(Hash)

        template = ::Ai::MissionTemplate.find_by(name: "system_agent_fleet", template_type: "system")
        return error_result("system_agent_fleet mission template is not seeded") unless template

        mission = ::Ai::Mission.create!(
          account: @account,
          created_by: @user,
          name: params[:name].presence || "Agent fleet #{Time.current.utc.iso8601}",
          mission_type: "agent_fleet",
          mission_template: template,
          status: "draft",
          objective: params[:objective].presence || "Provision + orchestrate an agent fleet",
          configuration: { "fleet_spec" => spec.deep_stringify_keys }
        )

        ::Ai::Missions::OrchestratorService.new(mission: mission).start!

        success_result(
          mission_id: mission.id,
          status: mission.reload.status,
          current_phase: mission.current_phase,
          template: template.name
        )
      rescue StandardError => e
        error_result("agent fleet launch failed: #{e.message}")
      end

      # L3: read-only fleet mission summary (status + per-phase fleet state).
      def agent_fleet_status(params)
        mission = ::Ai::Mission.where(account_id: @account.id, mission_type: "agent_fleet")
                               .find_by(id: params[:mission_id])
        return error_result("agent_fleet mission not found") unless mission

        fleet = (mission.configuration.is_a?(Hash) ? mission.configuration["fleet"] : nil) || {}
        reaped = Array(fleet["reaped"])
        success_result(
          mission_id: mission.id,
          status: mission.status,
          current_phase: mission.current_phase,
          error_message: mission.error_message,
          fleet: {
            plan: fleet["plan"],
            member_count: Array(fleet["members"]).size,
            assignment_count: Array(fleet["assignments"]).size,
            report: fleet["report"],
            reaped_count: reaped.size,
            # Per-member reap actions — a terminate_failed entry is a leaked,
            # still-running instance, not a reaped one (F1-08).
            reaped: fleet["reaped"],
            reap_incomplete: reaped.any? { |r| r.is_a?(Hash) && r["action"] == "terminate_failed" }
          }
        )
      end

      # L3 lifecycle lever: re-run reap for a failed/stuck fleet (F1-08).
      def reap_agent_fleet(params)
        mission = ::Ai::Mission.where(account_id: @account.id, mission_type: "agent_fleet")
                               .find_by(id: params[:mission_id])
        return error_result("agent_fleet mission not found") unless mission

        result = ::System::AgentFleetMissionService.new(mission: mission)
                                                   .reap!(force: ActiveModel::Type::Boolean.new.cast(params[:force]))
        success_result(mission_id: mission.id, reap: result)
      rescue ::System::AgentFleetMissionService::FleetError => e
        error_result(e.message)
      end

      # A2A: mint an Ed25519 capability token (caller may invoke skill on target).
      #
      # SECRET DISCLOSURE (IMP-27cc7dceb97b). This arm used to return the
      # token's `envelope` AND `signature` — together a complete bearer
      # credential, and an Ed25519 signature produced from Vault-held signing
      # material that PeerCapabilityTokenSigner is explicitly built never to
      # log. An MCP tool result is not a private channel:
      # Ai::AgentToolBridgeService truncates it into `tool_calls_log`, which
      # Api::V1::Ai::ConversationsController persists into
      # ai_messages.processing_metadata (durable jsonb, never re-filtered on
      # read), and forwards the FULL json to the model provider as a
      # role:"tool" message.
      #
      # SUBSTITUTE CHOSEN: a REFUSAL, and deliberately NOT the retrieval path
      # used for the CI-worker token or the out-of-band delivery used for the
      # Gitea PAT.
      #
      #   * There is no retrieval path to name. No endpoint anywhere
      #     re-delivers a minted capability token to a caller. The two places
      #     that mint server-side both keep it: 
      #     Api::V1::System::NodeInstancePeersController#execute mints a
      #     SELF-EDGE token (caller == target — the peer executes its own
      #     offered skill) and hands it to the peer inside a System::Task's
      #     options; System::AgentFleetMissionService#mint_delegation_token
      #     mints the CROSS-instance edge this action was asked for and packages
      #     it into the delegation descriptor. Neither returns it to the HTTP
      #     caller. Advertising a recovery path that does not exist would be its
      #     own defect.
      #   * Returning the envelope while withholding the signature would be
      #     worse than refusing: an artifact that looks like a token, cannot be
      #     used as one, and still consumed the signing key.
      #
      # So this refuses BEFORE minting — nothing is signed, so nothing has to
      # be withheld, and no Vault key is touched on a call that cannot deliver.
      # Nobody is stranded, and the refusal names both real paths in-band. This
      # is the shape Ai::Tools::SdwanTool#propose_federation_peer already holds
      # for its acceptance token.
      #
      # The short DEFAULT_TTL (300s) is not a defense here: the persisted
      # ai_messages row and the provider-side transcript outlive the token, and
      # the disclosure is live for the whole window.
      def mint_peer_capability_token(_params)
        error_result(
          "capability-token minting is not available over the MCP tool surface: a tool result is persisted with " \
          "the conversation and forwarded to the model provider, so the envelope+signature pair cannot be " \
          "delivered here without disclosing signing material. Nothing was minted. To CHECK whether a call is " \
          "permitted, use system_authorize_peer_call — it runs the same PeerCapabilityService.authorize gates " \
          "with the same arguments and returns no secret. To PERFORM a CROSS-instance call, use " \
          "system_launch_agent_fleet: System::AgentFleetMissionService mints the caller->target token server-side " \
          "and packages it into the delegation descriptor. To have a peer run its OWN offered skill (a self-edge, " \
          "caller == target), use POST /api/v1/system/node_instance_peers/<peer_id>/execute (needs " \
          "system.peers.execute, which this action's system.node_instances.manage does not imply); it mints " \
          "internally and delivers the token to the peer inside the dispatched task."
        )
      end

      # L0: discover the isolation tiers + their container-runtime mapping.
      def list_isolation_tiers(_params)
        success_result(tiers: ::System::IsolationTier.catalog, default: ::System::IsolationTier::DEFAULT)
      end

      def provision_instance(params)
        node = account_nodes.find(params[:node_id])
        result = ::System::ProvisioningService.provision_instance(
          node: node,
          provider_region_id: params[:provider_region_id],
          provider_instance_type_id: params[:provider_instance_type_id],
          operation_id: params[:operation_id],
          options: params[:options] || {}
        )
        unless result.success?
          # IMP-2679c830ea1a — the call is synchronous, so a failure here is a
          # COMPLETED failure, and every post-create failure arm of
          # ProvisioningService has already left a NodeInstance row behind in
          # :error (possibly still owning a billable cloud resource). Returning
          # only a message stranded that row: the caller had no id with which to
          # inspect or terminate it. Pre-create failures (quota, unknown
          # region/SKU, unsupported provider) carry no instance in result.data,
          # and the key is omitted rather than sent as nil — a nil under the
          # right key reads as "the row exists and I could not identify it".
          failed = { success: false, error: result.error || "provisioning failed" }
          errored_instance = result.data.is_a?(Hash) ? result.data[:instance] : nil
          if errored_instance
            # Same shape and the same dig path as the success arm
            # (data.instance.id), so a caller does not need two resolutions for
            # one verb — System::Ai::Skills::ProvisionClusterExecutor already
            # reads dig(:data, :instance, :id) on success and had nothing to
            # read on failure. cloud_instance_id rides along because it is what
            # decides whether a live billable resource was stranded:
            # terminate_orphaned_cloud_instance is best-effort and swallows its
            # own failures.
            failed[:data] = { instance: serialize_instance(errored_instance),
                              cloud_instance_id: errored_instance.cloud_instance_id }
          end
          return failed
        end

        instance = result.data[:instance]
        success_result(
          provisioned: true,
          instance: serialize_instance(instance),
          cloud_instance_id: result.data[:cloud_instance_id]
        )
      end

      # === Approval-gated terminate (IMP-d410a587d6bf) ===
      #
      # The inline #terminate_instance that called
      # System::ProvisioningService.terminate_instance is GONE, not wrapped:
      # leaving an ungated writer reachable behind a declaration is how a gate
      # becomes decorative. Ai::Tools::BaseTool#execute routes this action
      # through Ai::AutonomyGate on the strength of the declare_action above,
      # and System::Executors::ExecuteTask is the only actor on either branch.

      # Gate context — resolves the target under the ACCOUNT scope first, so a
      # cross-account id is refused BEFORE any operation is created rather than
      # producing an approval card that names another tenant's instance. The
      # executor re-resolves at approval time (resolve_scoped): the row can be
      # re-parented between parking and approval, and the executor is the half
      # that runs then.
      def terminate_instance_gate_context(params)
        instance = account_instances.find(params[:instance_id])

        {
          executor_params: { instance_id: instance.id },
          description: "Terminate instance '#{instance.name}'",
          source_type: instance.class.name,
          source_id: instance.id
        }
      end

      # :proceed serialization. The gate has already run the executor
      # (Ai::AutonomyGate calls DeferredOperation#execute_now! itself on this
      # branch), so this READS the outcome — it must never repeat the
      # termination. Shape is unchanged from the pre-gate arm.
      def terminate_instance_terminated_result(params, _gate)
        instance = account_instances.find(params[:instance_id])
        success_result(terminated: true, instance: serialize_instance(instance.reload))
      end

      # Tripwire, not a reachable MCP path. #execute gates this action before
      # #call is consulted, so reaching here means something invoked #call
      # directly and would otherwise have terminated a VM with no policy
      # evaluation. Fail loudly instead.
      def gate_routed_only(action)
        error_result(
          "#{action} is approval-gated and must be invoked via " \
          "Ai::Tools::BaseTool#execute, not #call"
        )
      end

      # Hoists this tool's per-action permission check so a gated action — which
      # never reaches #call — is authorized identically to an ungated one.
      def authorization_error(params)
        # routed_action_name, not params[:action]: the registry lookup is
        # key-shape indifferent, and a symbol-only read here would let a
        # string-keyed caller be GATED while its permission check fell back to
        # required_perm_for(nil) — the REQUIRED_PERMISSION floor rather than
        # system.instances.control. The two halves of one call must not
        # disagree about key type, least of all in the permissive direction.
        action = routed_action_name(params)
        return nil if action_permitted?(action)

        error_result(permission_denied_message(action))
      end

      # F4-08 — start/stop/reboot via InstanceControlService: the
      # cost-control lever agents lacked (provision/terminate/drain existed,
      # but not "stop the idle GPU instance overnight").
      def control_instance(params, action)
        instance = account_instances.find(params[:instance_id])
        result = ::System::InstanceControlService.execute(
          instance: instance,
          action: action,
          operation_id: params[:operation_id],
          force: ::ActiveModel::Type::Boolean.new.cast(params[:force]) || false
        )
        return error_result(result.error || "#{action} failed") unless result.success?

        success_result(action: action, instance: serialize_instance(instance.reload))
      end

      # Direct FK dependents of system_node_instances that have NO dependent:destroy
      # on the NodeInstance model. Order doesn't matter inside the set — they're
      # all peers of the same parent.
      DESTROY_INSTANCE_FKS = [
        [ "system_node_modules", "node_instance_id" ],
        [ "system_bootstrap_tokens", "node_instance_id" ],
        [ "system_node_certificates", "node_instance_id" ],
        [ "system_sdwan_ovn_logical_switch_ports", "host_node_instance_id" ],
        [ "system_unclaimed_devices", "claimed_node_instance_id" ],
        [ "system_node_instance_peers", "node_instance_id" ],
        [ "system_storage_assignments", "node_instance_id" ],
        [ "devops_kubernetes_nodes", "node_instance_id" ],
        [ "devops_docker_hosts", "node_instance_id" ],
        [ "system_storage_credentials", "node_instance_id" ],
        [ "system_mount_encryption_keys", "node_instance_id" ],
        [ "business_billing_provisioning_usage_records", "node_instance_id" ],
        [ "ai_provisioning_code_deployments", "node_instance_id" ],
        [ "system_sdwan_host_vrf_assignments", "node_instance_id" ],
        [ "system_sdwan_host_bridges", "node_instance_id" ],
        [ "system_provider_volumes", "node_instance_id" ]
      ].freeze

      # FK dependents of sdwan_peers — those peers are attached to the instance
      # being destroyed and themselves have child rows that must clear first.
      DESTROY_SDWAN_PEER_FKS = [
        [ "system_sdwan_peer_keys", "sdwan_peer_id" ],
        [ "system_sdwan_subnet_advertisements", "sdwan_peer_id" ],
        [ "system_sdwan_virtual_ip_assignments", "sdwan_peer_id" ],
        [ "system_sdwan_bgp_sessions", "sdwan_peer_id" ],
        [ "system_sdwan_bgp_sessions", "neighbor_peer_id" ],
        [ "system_sdwan_port_mappings", "sdwan_peer_id" ],
        [ "system_sdwan_port_mappings", "target_peer_id" ],
        [ "system_sdwan_membership_credentials", "sdwan_peer_id" ]
      ].freeze

      def destroy_instance(params)
        instance = account_instances.find(params[:instance_id])
        inst_id = instance.id
        name = instance.name
        deleted = Hash.new(0)
        peers_destroyed = 0

        ActiveRecord::Base.transaction do
          # Break the circular enrollment_token_id ↔ system_bootstrap_tokens loop:
          # NULL the instance's pointer before deleting its bootstrap_tokens.
          n = ActiveRecord::Base.connection.exec_update(
            "UPDATE system_node_instances SET enrollment_token_id = NULL WHERE id = $1 AND enrollment_token_id IS NOT NULL",
            "null-enrollment-token", [ inst_id ]
          )
          deleted["system_node_instances.enrollment_token_id_nulled"] = n if n > 0

          # SDWAN peers attached to this instance + their child rows
          peer_rows = ActiveRecord::Base.connection.exec_query(
            "SELECT id FROM system_sdwan_peers WHERE node_instance_id = $1",
            "peers_for_inst", [ inst_id ]
          )
          peer_rows.rows.flatten.each do |peer_id|
            DESTROY_SDWAN_PEER_FKS.each do |table, col|
              k = ActiveRecord::Base.connection.exec_delete(
                "DELETE FROM #{table} WHERE #{col} = $1",
                "del-#{table}-#{col}", [ peer_id ]
              )
              deleted["#{table}.#{col}"] += k if k > 0
            end
            k = ActiveRecord::Base.connection.exec_delete(
              "DELETE FROM system_sdwan_peers WHERE id = $1",
              "del-peer", [ peer_id ]
            )
            peers_destroyed += k
          end

          # Direct dependents
          DESTROY_INSTANCE_FKS.each do |table, col|
            k = ActiveRecord::Base.connection.exec_delete(
              "DELETE FROM #{table} WHERE #{col} = $1",
              "del-#{table}-#{col}", [ inst_id ]
            )
            deleted["#{table}.#{col}"] = k if k > 0
          end

          instance.destroy!
        end

        success_result(
          destroyed: true,
          instance_id: inst_id,
          name: name,
          sdwan_peers_destroyed: peers_destroyed,
          dependent_rows_deleted: deleted
        )
      rescue ActiveRecord::InvalidForeignKey => e
        error_result(
          "FK still blocks destroy — extend DESTROY_INSTANCE_FKS or DESTROY_SDWAN_PEER_FKS: #{e.message}"
        )
      end

      # === Templates ===

      # `q` narrows on name OR description. Previously this action took no
      # parameters at all, so an agent looking for one template had to pull the
      # whole catalog and filter client-side.
      def list_templates(params = {})
        templates = account_templates.order(name: :asc)
        if (q = params[:q].to_s.strip).present?
          like = "%#{::ActiveRecord::Base.sanitize_sql_like(q)}%"
          templates = templates.where(
            "system_node_templates.name ILIKE :like OR system_node_templates.description ILIKE :like",
            like: like
          )
        end
        success_result(
          templates: templates.map { |t| serialize_template(t) },
          count: templates.size
        )
      end

      def get_template(params)
        template = account_templates.find(params[:template_id])
        success_result(template: serialize_template_full(template))
      end

      # Conflict detection used to run ONLY in compose_preview, so nothing on
      # this path stopped an agent from composing a template that cannot build.
      # It now runs the same analysis over the module set the assignment would
      # produce: error-severity conflicts refuse the write and name the modules
      # involved, warnings ride the success payload. A clean assignment's
      # payload is unchanged.
      def assign_module_to_template(params)
        template = account_templates.find(params[:template_id])
        node_module = account_modules.find(params[:module_id])
        attrs = template_module_attrs(params)

        # A join assigned disabled is not expanded onto anything
        # (TemplateExpansionService is enabled-only, and assignment_verdict's
        # own baseline already ignores disabled joins), so there is nothing for
        # it to conflict with. Enabling it is the moment it starts shipping,
        # and update_template_module runs the check there.
        verdict = ships?(attrs) ? assignment_verdict(template, node_module) : nil
        return error_result(verdict.message) if verdict&.blocked?

        join = ::System::TemplateModule.create!(
          attrs.merge(node_template: template, node_module: node_module)
        )
        payload = { assigned: true, template_module_id: join.id }
        payload[:warnings] = verdict.warnings if verdict&.warnings&.any?
        # SEPARATE question from the conflict verdict above — see
        # record_template_blast_radius. A join that does not ship reaches no
        # live node, so it carries no blast radius to record either.
        if ships?(attrs) && (radius = record_template_blast_radius(template, node_module, "module_assigned"))
          payload[:blast_radius] = radius
        end
        success_result(payload)
      rescue ArgumentError => e
        # A raised exception from a tool surfaces as a raw protocol error, not
        # a refusal the caller can read — so a malformed `priority` comes back
        # as a clean error_result here, the same shape every other bad-input
        # path in this tool uses. (IMP-280a5abf09dc)
        error_result(e.message)
      end

      # In-place edit of an existing join, addressed by (template, module) like
      # every other TemplateModule action. This is the reachable form of the
      # documented-correct removal: enabled=false keeps the row, so
      # source_template_module_id on the derived NodeModuleAssignments survives
      # — unassigning nullifies it and orphans them permanently.
      def update_template_module(params)
        template = account_templates.find(params[:template_id])
        node_module = account_modules.find(params[:module_id])
        join = ::System::TemplateModule.find_by(node_template: template, node_module: node_module)
        unless join
          return error_result("Module '#{node_module.name}' is not assigned to template " \
                              "'#{template.name}' — assign it first with system_assign_module_to_template")
        end

        attrs = template_module_attrs(params)
        return error_result("nothing to update — pass at least one of priority, enabled, config, recommends_override") if attrs.empty?

        # Only a join that is BECOMING enabled needs the guard: it is the
        # transition that puts the module into what the template ships.
        # Disabling, or editing priority/config on a join whose enabled flag is
        # unchanged, alters no module membership and so introduces no conflict.
        if attrs[:enabled] == true && !join.enabled
          verdict = assignment_verdict(template, node_module)
          return error_result(verdict.message) if verdict.blocked?
        end

        shipped_before = join.enabled
        join.update!(attrs)
        payload = { updated: true, template_module: serialize_template_module(join) }
        # Blast radius covers more transitions than the conflict guard above:
        # DISABLING a shipping join takes a module off live fleet, which the
        # conflict check correctly ignores (it introduces no conflict) but which
        # is exactly the kind of change an operator should see recorded. Editing
        # priority/config on a join that already ships changes what the next
        # apply materializes too. Only an edit that neither shipped before nor
        # ships after is inert.
        if shipped_before || join.enabled
          change = if shipped_before && !join.enabled then "module_disabled"
          elsif !shipped_before && join.enabled then "module_enabled"
          else "join_updated"
          end
          radius = record_template_blast_radius(template, node_module, change)
          payload[:blast_radius] = radius if radius
        end
        success_result(payload)
      rescue ActiveRecord::RecordInvalid => e
        error_result("Template module update failed: #{e.record.errors.full_messages.join(', ')}")
      rescue ArgumentError => e
        error_result(e.message)
      end

      # Absent keys are dropped rather than nil-assigned, so an update touches
      # only what the caller named. `enabled` is cast here rather than left to
      # the model: the conflict guard branches on it BEFORE the write, so a
      # string "true" that AR would happily cast to true must not read as
      # "not literally true, skip the check".
      def template_module_attrs(params)
        attrs = {}
        # Raises ArgumentError on a non-integer; both callers turn that into an
        # error_result. See System::TemplateModule.coerce_priority! for why nil
        # is left alone rather than read as 0.
        attrs[:priority]            = ::System::TemplateModule.coerce_priority!(params[:priority]) unless params[:priority].nil?
        attrs[:config]              = params[:config]              if params[:config].is_a?(Hash)
        attrs[:recommends_override] = params[:recommends_override] if params[:recommends_override].is_a?(Hash)

        enabled = ::ActiveModel::Type::Boolean.new.cast(params[:enabled])
        attrs[:enabled] = enabled unless enabled.nil?
        attrs
      end

      # TemplateModule.enabled defaults to true, so an unspecified flag ships.
      def ships?(attrs)
        attrs.fetch(:enabled, true)
      end

      def assignment_verdict(template, node_module)
        ::System::TemplateCompositionAnalysis
          .new(@account)
          .assignment_verdict(template: template, node_module: node_module)
      end

      # IMP-4d76a6b76146 — blast-radius classification on the template WRITE
      # path. A DIFFERENT concern from assignment_verdict above, deliberately
      # kept as a separate check: that one asks "can this template BUILD?" and
      # refuses an error-severity answer; this one asks "what LIVE FLEET does
      # this template already carry?" — a question with no wrong answer, only a
      # consequential one.
      #
      # Why the write and not the apply. TemplateApplyService is per-NODE and
      # sits on the provisioning path (ProvisioningService materializes a brand
      # new node's assignments through it), so a template-wide check there would
      # fire on every legitimate provision of the 11th node onto a 10-node
      # template. Apply also cannot distinguish a reviewed closure from an
      # unreviewed one — that needs template history, which does not exist yet —
      # so it would gate every apply on every established template forever. The
      # autonomous apply arm is already gated: TemplateClosureDriftSensor
      # computes this same classification and DecisionEngine#force_policy_for
      # forces require_approval off it. The WRITE is what had no classification
      # at all.
      #
      # Why it records instead of refusing. TemplateApprovalPolicy is documented
      # as "a classification a caller consults, not a hard raise", and a raw
      # SystemFleetTool action has no approve-and-proceed door to offer — the
      # definitions' `requires_approval` flag is DESCRIPTIVE ONLY (improvement
      # 019f34a3). A refusal would dead-end the COMMON case (an established
      # template has live nodes by definition), and the way around a dead end is
      # the REST join endpoints, which are watched even less. So the mutation
      # proceeds and leaves a record: on the payload for the caller, and as a
      # FleetEvent for everyone who was not in the room.
      #
      # Returns nil — and adds NOTHING to the payload — when blast radius is
      # zero, so a mutation on a template with no live fleet is byte-for-byte
      # what it was before. The events share
      # `correlation_id: "template_mutation:<template_id>"`, so
      # system_inspect_correlation walks one template's mutation history in
      # emission order.
      def record_template_blast_radius(template, node_module, change)
        classification = ::System::Ai::Skills::TemplateApprovalPolicy.for(template: template)
        return nil unless classification.requires_approval?

        radius = {
          requires_approval: true,
          provisioned_node_count: classification.provisioned_node_count,
          reason: classification.reason
        }

        ::System::Fleet::EventBroadcaster.emit!(
          account: @account,
          kind: "system.template_mutation",
          severity: :medium,
          source: "system_fleet_tool",
          correlation_id: "template_mutation:#{template.id}",
          node_module_id: node_module.id,
          payload: radius.merge(
            change: change,
            template_id: template.id,
            template_name: template.name,
            node_module_name: node_module.name,
            initiated_by: @user&.id || "system"
          )
        )

        radius
      end

      def serialize_template_module(join)
        {
          id: join.id,
          node_template_id: join.node_template_id,
          node_module_id: join.node_module_id,
          enabled: join.enabled,
          priority: join.priority,
          config: join.config,
          recommends_override: join.recommends_override
        }
      end

      # Read-only design-time analysis — the same projection
      # NodeTemplatesController#compose_preview renders for the Visual Template
      # Composer, so an agent designing a template sees the conflicts, footprint
      # and dependency graph an operator does. Persists nothing.
      def compose_preview_template(params)
        ids = Array(params[:module_ids])
        return error_result("module_ids: required") if ids.empty?

        analysis = ::System::TemplateCompositionAnalysis.new(@account)
        requested = analysis.modules_for(ids)
        return error_result("no matching modules") if requested.empty?

        success_result(analysis.preview_for(requested))
      end

      # === Modules ===

      def list_modules(params)
        scope = account_modules
        if (variety = params.dig(:options, :variety))
          scope = scope.where(variety: variety)
        end
        success_result(
          modules: scope.order(name: :asc).map { |m| serialize_module(m) },
          count: scope.size
        )
      end

      def get_module(params)
        node_module = account_modules.find(params[:module_id])
        success_result(node_module: serialize_module_full(node_module))
      end

      def list_module_versions(params)
        node_module = account_modules.find(params[:module_id])
        versions = node_module.versions.order(version_number: :desc)
        success_result(
          versions: versions.map { |v| serialize_version(v) },
          count: versions.size
        )
      end

      # === Catalog discovery (IMP-67aea0728774) ===
      #
      # Both actions delegate ranking to System::CatalogDiscoveryService so the
      # policy (cosine-only, no lexical fallback, shared confidence buckets)
      # lives in one place and a future REST surface reuses it — the same reason
      # PackageSearchService exists behind system_search_packages.

      def discover_modules(params)
        result = ::System::CatalogDiscoveryService.discover_modules(
          account:          @account,
          intent:           params[:intent],
          top_k:            params[:top_k] || ::System::CatalogDiscoveryService::DEFAULT_TOP_K,
          variety:          params[:variety],
          platform_id:      params[:platform_id],
          include_disabled: ::ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
        )

        intent = params[:intent].to_s.strip
        success_result(
          intent:     intent,
          results:    result.records.map { |m| serialize_module_match(m, intent) },
          seed_count: result.seed_count,
          confidence: result.confidence,
          coverage:   result.coverage
        )
      rescue ArgumentError, ::System::CatalogDiscoveryService::EmbeddingUnavailable => e
        error_result(e.message)
      end

      def discover_templates(params)
        result = ::System::CatalogDiscoveryService.discover_templates(
          account:          @account,
          intent:           params[:intent],
          top_k:            params[:top_k] || ::System::CatalogDiscoveryService::DEFAULT_TOP_K,
          platform_id:      params[:platform_id],
          include_disabled: ::ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
        )

        intent = params[:intent].to_s.strip
        success_result(
          intent:     intent,
          results:    result.records.map { |t| serialize_template_match(t, intent) },
          seed_count: result.seed_count,
          confidence: result.confidence,
          coverage:   result.coverage
        )
      rescue ArgumentError, ::System::CatalogDiscoveryService::EmbeddingUnavailable => e
        error_result(e.message)
      end

      # IMP-65bea54e4081 — promotion advances the LADDER and nothing else.
      # NodeModuleVersion#promote_to! writes promotion_state plus AT MOST one
      # timestamp column (a staging->built step is a legal transition that
      # stamps nothing); it does not touch NodeModule#current_version_id, which
      # is the pointer the node-facing download resolves
      # (Api::V1::System::NodeApi::ModulesController#download reads
      # `@module.current_version&.artifact`). So `promoted: true` on its own
      # says a label changed, and is indistinguishable from a fleet change.
      #
      # This verb deliberately does NOT call NodeModule#promote_to_version!:
      # RestartAfterUpdate.arm! fires there, so making promotion move the
      # pointer would restart services fleet-wide.
      #
      # Whether it SHOULD is now DECIDED — no. See
      # docs/design/promotion-ladder-semantics.md (IMP-c7d618b0b72f): the
      # rungs are eligibility labels, `live`/`retired` are historical stamps,
      # and current_version_id stays the sole actuator. So advancing a version
      # to `live` here is a record that it was promoted, NOT a claim about what
      # the fleet serves — which is why the fields below are read back from the
      # row. The second question in that pair — whether publish should stop
      # auto-promoting past the ladder (ModulePublicationProcessor defaults
      # auto_promote? to true, so a never-staged version can become current) —
      # is still open in that note's section 6; it changes every deployment and
      # needs operator sign-off.
      #
      # promote_to_version! is the SANCTIONED writer of current_version_id and
      # the only one that arms a restart — not the only writer. This comment
      # previously named TWO others; re-deriving the set from the COLUMN rather
      # than from this list found SIX in total, the widest being
      # ModuleVersionService#create_version, which NodeModule's
      # `after_update :auto_create_version` callback invokes on any save
      # touching VERSIONED_ATTRIBUTES. The executable census that now fails on a
      # seventh is spec/lint/node_module_current_version_write_seam_spec.rb —
      # read it rather than this sentence, which is the kind that goes stale.
      # That is why the fields below are read back from the row rather than
      # inferred from which method ran.
      #
      # What this reports, modelled on the REST publish path's
      # promoted_to_current (ModulePublicationsController#create):
      #   promoted_to_current     — is this version what the fleet now serves?
      #   current_version_changed — did the served artifact move across this
      #                             call? (a before/after read of the pointer,
      #                             so it states the delta, not causation)
      #   current_version_id      — what the fleet serves, whichever row that is.
      def promote_module_version(params)
        version = ::System::NodeModuleVersion
                  .joins(:node_module)
                  .where(system_node_modules: { account_id: @account.id })
                  .find(params[:module_version_id])
        node_module = version.node_module
        current_before = node_module.current_version_id

        version.promote_to!(params[:target_state])

        current_after = node_module.reload.current_version_id
        success_result(
          promoted: true,
          promoted_to_current: current_after == version.id,
          current_version_changed: current_after != current_before,
          current_version_id: current_after,
          version: serialize_version(version.reload)
        )
      end

      # === Drift ===

      def drift_report(params)
        instance = account_instances.find(params[:instance_id])
        # NodeInstance#module_drift is the single definition of module drift —
        # shared with ModuleDriftSensor and the deployment-scoped drift_check
        # in PlatformMaintenanceExecutor (IMP-0d106a152c47).
        drift = instance.module_drift
        missing    = drift[:missing]
        extra      = drift[:extra]
        mismatched = drift[:mismatched]

        success_result(
          drift: missing.any? || extra.any? || mismatched.any?,
          missing_count: missing.size,
          extra_count: extra.size,
          mismatched_count: mismatched.size,
          missing: missing,
          extra: extra,
          mismatched: mismatched,
          last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
          # Boot-image drift (campaign 019f505f) — is the node running a stale
          # disk image relative to its platform's promoted image? booted is the
          # sha the agent reported booting from; promoted is the currently
          # published image. Either may be nil (older agent / no promotion yet).
          boot_image_drift: instance.boot_image_drifted?,
          booted_image_git_sha: instance.booted_image_git_sha,
          promoted_image_git_sha: instance.promoted_image_git_sha
        )
      end

      # === Tasks ===

      def list_tasks(params)
        scope = ::System::Task.where(account: @account)
        if params[:node_id].present?
          scope = scope.where(operable_type: "System::Node", operable_id: params[:node_id])
        end
        if params[:instance_id].present?
          scope = scope.where(operable_type: "System::NodeInstance", operable_id: params[:instance_id])
        end
        scope = scope.order(created_at: :desc).limit(100)
        success_result(
          tasks: scope.map { |t| serialize_task(t) },
          count: scope.size
        )
      end

      def cancel_task(params)
        task = ::System::Task.where(account: @account).find(params[:id])
        if task.respond_to?(:cancel!) && task.may_cancel?
          task.cancel!
          success_result(cancelled: true, task: serialize_task(task.reload))
        else
          error_result("Task cannot be cancelled from #{task.status}")
        end
      end

      # IMP-8153d1952ff8 — operator recourse on a wedged :running task.
      # Mirrors cancel_task's may_x?/bang shape; the abort AASM event was
      # already legal from :running, just unexposed on this surface.
      def abort_task(params)
        task = ::System::Task.where(account: @account).find(params[:id])
        if task.respond_to?(:abort!) && task.may_abort?
          task.abort!(params[:reason])
          success_result(aborted: true, task: serialize_task(task.reload))
        else
          error_result("Task cannot be aborted from #{task.status}")
        end
      end

      # Single-task fetch — mirrors list_tasks' account scoping + serializer.
      # Not-found bubbles to the shared ActiveRecord::RecordNotFound rescue
      # in #call, which renders the standard error_result.
      def get_task(params)
        task = ::System::Task.where(account: @account).find(params[:id])
        success_result(task: serialize_task(task, full_error: true))
      end

      # === Module diff ===

      # Read-only preview of where a CI publish for `module_name` would land,
      # and whether the platform would then accept it.
      #
      # Exists because diagnosing that took a live 422, a CI log, and a hand
      # query against the platform's database. The failure was that a one-off
      # module held the canonical OCI repo binding, the resolver matched the
      # binding before the name, and ManifestImportService then refused the
      # name mismatch — a chain visible nowhere until it failed.
      #
      # Deliberately does NOT run the resolver's auto-create branch: a preview
      # that creates a NodeModule as a side effect is not a preview.
      def module_publish_target(params)
        module_name = params[:module_name].to_s
        return error_result("module_name required") if module_name.blank?

        gitea_repo = params[:gitea_repo].presence || "powernode/#{module_name}"

        by_name = @account.system_node_modules.find_by(name: module_name)
        by_repo = @account.system_node_modules.find_by(gitea_repo_full_name: gitea_repo)

        # The resolver matches by name; the importer then requires the stored
        # name to equal the manifest's. So a publish is accepted iff the target
        # is the name match (or a fresh module created under that same name).
        would_create = by_name.nil?
        foreign_binding = by_repo && by_repo.name != module_name

        success_result(
          module_name:      module_name,
          gitea_repo:       gitea_repo,
          resolves_to:      by_name && { id: by_name.id, name: by_name.name,
                                         gitea_repo_full_name: by_name.gitea_repo_full_name,
                                         current_version_number: by_name.current_version_number },
          would_auto_create: would_create,
          # True whenever the publish can proceed: either an existing module
          # whose name matches, or a new one created with that name.
          would_be_accepted: true,
          repo_binding_holder: by_repo && { id: by_repo.id, name: by_repo.name },
          foreign_repo_binding: foreign_binding.present?,
          advisory: if foreign_binding
                      "#{by_repo.name} holds #{gitea_repo} but publishes for " \
                      "#{module_name.inspect} resolve by name to " \
                      "#{by_name ? by_name.name : "a module that would be auto-created"}. " \
                      "The binding is stale or belongs on the published module — build " \
                      "dispatch and manifest fetch will fall back to a derived repo name " \
                      "until it is cleared or rebound."
                    elsif would_create
                      "No module named #{module_name.inspect} exists yet; a publish would " \
                      "create one on this account."
                    end
        )
      end

      # === Operator ops hold ===
      #
      # Blocks the platform from starting an instance while offline work is
      # happening on its disks, and pushes the block down to the provider where
      # one exists — a platform-side flag only binds callers that come through
      # the platform, and the start that caused the 2026-07-27 incident was a
      # hypervisor task.
      def instance_hold(params)
        instance = find_instance(params)
        return instance if instance.is_a?(Hash)
        return error_result("reason required — a hold records why, so the next person knows whether to clear it") if params[:reason].blank?

        ttl = params[:ttl_hours].present? ? params[:ttl_hours].to_f.hours : ::System::InstanceOpsHoldService::DEFAULT_TTL
        result = ::System::InstanceOpsHoldService.hold!(
          instance: instance, user: @user, reason: params[:reason].to_s, ttl: ttl
        )
        return error_result(result.error) unless result.ok?

        success_result(
          instance_id: instance.id, name: instance.name,
          provider_enforced: result.provider_enforced, provider_state: result.provider_state,
          expires_at: instance.reload.ops_hold_expires_at&.iso8601,
          message: result.message
        )
      end

      def instance_release_hold(params)
        instance = find_instance(params)
        return instance if instance.is_a?(Hash)

        result = ::System::InstanceOpsHoldService.release!(instance: instance, user: @user)
        return error_result(result.error) unless result.ok?

        success_result(instance_id: instance.id, name: instance.name, message: result.message)
      end

      # Verified by READING provider state — never by attempting a start, which
      # on a broken hold would start the very instance the operator needed
      # stopped. Reports drift between platform intent and provider reality.
      def instance_hold_status(params)
        instance = find_instance(params)
        return instance if instance.is_a?(Hash)

        result = ::System::InstanceOpsHoldService.status(instance: instance)
        success_result(
          instance_id: instance.id, name: instance.name,
          held: instance.ops_held?, expired: instance.ops_hold_expired?,
          reason: instance.ops_hold_reason, held_by: instance.ops_held_by&.email,
          held_at: instance.ops_hold_at&.iso8601,
          expires_at: instance.ops_hold_expires_at&.iso8601,
          provider_enforced: result.provider_enforced, provider_state: result.provider_state,
          summary: result.message, drift: result.error
        )
      end

      def find_instance(params)
        id = params[:instance_id].presence || params[:id].presence
        return error_result("instance_id required") if id.blank?

        account_instances.find_by(id: id) || error_result("instance #{id} not found in this account")
      end

      # Artifacts that reached the OCI registry but never reached the platform.
      #
      # A module build pushes and cosign-signs BEFORE it notifies, so every
      # failure after that point leaves a real signed artifact in the registry
      # that NodeModuleVersion knows nothing about — while the run goes red and
      # reads as "the build broke". Comparing the two sides catches that class
      # whatever the cause (TLS trust, bad token, wrong API base, 422).
      #
      # NOT a staleness sweep: source age is never consulted. A module whose
      # newest build predates its newest commit is normal here and is not
      # reported.
      def module_publication_integrity(params)
        findings = ::System::ModulePublicationIntegrityService
                   .new(account: @account)
                   .check(module_name: params[:module_name].presence)

        unrecorded = findings.reject(&:ok?)
        success_result(
          checked:            findings.length,
          clean:              unrecorded.empty?,
          modules_with_gaps:  unrecorded.length,
          findings:           unrecorded.map(&:to_h),
          all:                findings.map { |f| { module_name: f.module_name, ok: f.ok? } }
        )
      end

      def module_diff(params)
        ver_a = ::System::NodeModuleVersion
                .joins(:node_module)
                .where(system_node_modules: { account_id: @account.id })
                .find(params[:version_a_id])
        ver_b = ::System::NodeModuleVersion
                .joins(:node_module)
                .where(system_node_modules: { account_id: @account.id })
                .find(params[:version_b_id])
        result = ::System::ModuleDiffService.compare(version_a: ver_a, version_b: ver_b)
        return error_result(result.error) unless result.ok?
        success_result(
          unchanged: result.unchanged,
          fingerprint_a: result.fingerprint_a,
          fingerprint_b: result.fingerprint_b,
          file_changes: result.file_changes,
          package_changes: result.package_changes,
          mount_changes: result.mount_changes
        )
      end

      # === Platform deployment (D3) ===
      #
      # Two-branch tool: with no params (or mode missing), returns the
      # wizard payload that the chat UI renders as an inline form. With
      # full params, executes the deployment via the orchestrator.
      #
      # The bridge service (CARD_TOOLS) maps this tool name to the
      # `platform_deployment_wizard` ChatCard kind so the frontend
      # renders the form inline rather than showing the JSON envelope.
      #
      # Federated deployment is NOT available on this surface (IMP-c0687cfb3a05).
      #
      # A federated deploy always mints a single-use federation acceptance
      # token (System::SpawnPlatformService#spawn! — the mint is unconditional,
      # not a flag), and the plaintext came back in the tool result TWICE: once
      # as `acceptance_token` and again inside `spawn_payload`.
      #
      # A tool result does not stop at its caller. Ai::AgentToolBridgeService
      # appends the full result JSON to the conversation as a `role: "tool"`
      # message, which is sent to the model provider on the next iteration of
      # the agent loop. Worse than the sdwan sibling (IMP-3a32dc649043): this
      # action is in that service's CARD_TOOLS map, so the full UNTRUNCATED data
      # payload is also copied into a chat card and written to
      # ai_messages.content_metadata — at-rest persistence, not just transit.
      # Ai::SensitiveParams cannot intervene on either (#filter returns non-Hash
      # input unchanged, and the card payload is never routed through it).
      #
      # The refusal is up front, before the orchestrator runs, and deliberately
      # not a silent omission: minting the token and withholding it would leave
      # a FederationPeer whose only means of acceptance is a secret nobody ever
      # saw, plus a child VM already provisioned against it. Standalone
      # deployment and the wizard payload stay fully supported here; the
      # federated path belongs to the operator API, which renders to an HTTP
      # response rather than into an agent's context.
      #
      # The predicate normalizes rather than comparing to a literal: MCP
      # arguments arrive from JSON with no coercion anywhere on the path (the
      # bridge parses and stringifies keys; BaseTool only checks required-key
      # presence). Normalizing is strictly broader than the executor's own
      # `MODES.include?(mode.to_s)`, so no spelling that would reach the mint
      # can walk past a refusal whose whole contract is that it is loud.
      def deploy_platform(params)
        if federated_mode?(params[:mode])
          return error_result(
            "federated deployment is not available over the MCP tool surface: it mints a " \
            "single-use federation acceptance token, and a tool result is forwarded to the " \
            "model provider and persisted with the conversation, so the plaintext cannot be " \
            "delivered here without disclosing signing material. Deploy federated platforms " \
            "over the operator API instead — POST /api/v1/system/platform/deployments " \
            "(permission system.platform.deploy) runs the same orchestrator and reveals the " \
            "acceptance_token exactly once in its HTTP response. Standalone deployment and " \
            "the wizard payload are supported here."
          )
        end

        executor = build_skill_executor(::System::Ai::Skills::PlatformDeployExecutor)
        # Pass through every relevant param; nil/blank get filtered by the executor.
        # token_ttl_seconds is not forwarded — it only ever tuned the acceptance
        # token's expiry, which this surface no longer mints.
        execute_args = {
          mode: params[:mode].presence,
          name: params[:name].presence,
          template_slug: params[:template_slug].presence,
          parent_url: params[:parent_url].presence,
          spawn_mode: params[:spawn_mode].presence,
          region: params[:region].presence,
          instance_size: params[:instance_size].presence,
          service_role: params[:service_role].presence,
          public_dns_hostname: params[:public_dns_hostname].presence
        }.compact

        result = executor.execute(**execute_args)
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # True for any spelling of "federated" the deploy path would honour.
      # PlatformDeployExecutor matches on `mode.to_s`, so stripping and
      # downcasing here refuses a superset of what could reach the mint.
      def federated_mode?(mode)
        mode.to_s.strip.downcase == "federated"
      end

      # === Storage volume CRUD (MCP.1) ===

      def list_volumes(params)
        scope = ::System::ProviderVolume.where(account: @account)
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
        scope = scope.where(node_instance_id: nil) if params[:unattached_only]
        if params[:transport].present?
          scope = scope.joins(:volume_type).where(
            system_provider_volume_types: { volume_type: params[:transport] }
          )
        end
        success_result(volumes: scope.includes(:volume_type).order(:size_gb, :created_at).map { |v| serialize_volume(v) })
      end

      def get_volume(params)
        v = ::System::ProviderVolume.includes(:volume_type, :node_instance).find_by(
          id: params[:id], account: @account
        )
        return error_result("Volume not found") unless v
        success_result(volume: serialize_volume(v, full: true))
      end

      def create_volume(params)
        transport = (params[:transport].presence || "block").to_s
        unless %w[nfs iscsi smb block].include?(transport)
          return error_result("Invalid transport (allowed: nfs, iscsi, smb, block)")
        end

        region = resolve_volume_region(params)
        return region if region.is_a?(Hash) # error_result passthrough

        provider = region.provider

        volume_type = resolve_or_create_volume_type(params, provider, transport)
        return error_result("Could not resolve volume_type") unless volume_type

        config = build_volume_config(params, transport)

        v = ::System::ProviderVolume.new(
          account: @account,
          name: params[:name].to_s,
          description: params[:description].to_s,
          size_gb: params[:size_gb].to_i,
          status: "available",
          volume_type: volume_type,
          provider_region: region,
          encrypted: false,
          delete_on_termination: false,
          external_id: external_id_for(transport, params),
          config: config
        )
        v.save!
        success_result(volume: serialize_volume(v, full: true))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Volume create failed: #{e.record.errors.full_messages.join(', ')}")
      end

      def update_volume(params)
        v = ::System::ProviderVolume.find_by(id: params[:id], account: @account)
        return error_result("Volume not found") unless v

        attrs = params.slice(:name, :description, :size_gb, :status).to_h.compact
        return error_result("No mutable fields supplied") if attrs.empty?

        v.update!(attrs)
        success_result(volume: serialize_volume(v.reload, full: true))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Update failed: #{e.record.errors.full_messages.join(', ')}")
      end

      def delete_volume(params)
        v = ::System::ProviderVolume.find_by(id: params[:id], account: @account)
        return error_result("Volume not found") unless v
        # Block-volume attach: recorded on the row FK by attach_to!.
        return error_result("Volume is attached — detach first") if v.node_instance_id.present?
        # Network-FS attach (NFS/SMB/iSCSI): a pool, so no row FK is set —
        # the per-consumer binding lives only in NodeInstance.config
        # ["storage_volume"]["volume_id"]. Destroying a volume still mounted by
        # live instances breaks those mounts and orphans data, so guard on it.
        return error_result("Volume is attached — detach first") if volume_attached_via_network_fs?(v)
        v.destroy!
        success_result(deleted: true, id: params[:id])
      end

      # True when any of this account's instances reference the volume through
      # the network-FS storage binding stamped on NodeInstance.config (the path
      # used by attach_volume / PlatformDeploymentOrchestrator for NFS/SMB/iSCSI
      # pools, which never sets ProviderVolume#node_instance_id).
      def volume_attached_via_network_fs?(volume)
        ::System::NodeInstance
          .where(account_id: @account.id)
          .where("config -> 'storage_volume' ->> 'volume_id' = ?", volume.id.to_s)
          .exists?
      end

      def attach_volume(params)
        v = ::System::ProviderVolume.find_by(id: params[:volume_id], account: @account)
        return error_result("Volume not found: #{params[:volume_id]}") unless v
        instance = ::System::NodeInstance.where(account_id: @account.id)
                                          .find_by(id: params[:node_instance_id])
        return error_result("Instance not found: #{params[:node_instance_id]}") unless instance

        # The instance's config["storage_volume"] holds a single binding — a
        # second attach without an explicit detach would otherwise silently
        # overwrite it, unbinding whatever disk is currently mounted.
        existing_binding_id = bound_storage_volume_id(instance)
        if existing_binding_id.present? && existing_binding_id != v.id.to_s
          return error_result("Instance already has a storage_volume binding (volume #{existing_binding_id}) — detach it first")
        end

        vt_kind = v.volume_type&.volume_type.to_s
        is_network_fs = %w[nfs smb iscsi].include?(vt_kind)
        deployment_name = params[:deployment_name].to_s.presence || "manual"
        role = params[:role].to_s.presence || "generic"

        if is_network_fs
          subpath = ::System::Platform::StorageLayout.subpath_for(
            deployment_name: deployment_name, role: role
          )
          binding = {
            volume_id: v.id, volume_name: v.name, size_gb: v.size_gb,
            transport: vt_kind, mount_type: vt_kind,
            mount_point: ::System::Platform::StorageRecommendations.mount_point_for(account: @account, role: role),
            subpath: subpath, role: role, attached_at: Time.current.iso8601,
            vt_kind => v.config[vt_kind]&.merge("subpath" => subpath)
          }
          # Only `storage_volume` — see System::ConfigDocument.
          instance.merge_config!("storage_volume" => binding)
        else
          return error_result("Volume already attached to another instance") if v.attached?
          return error_result("Volume is not available to attach (status: #{v.status})") unless v.can_attach?
          device_name = next_block_device_for(instance)
          return error_result("Attach failed — volume state changed") unless v.attach_to!(instance, device_name)
          binding = {
            volume_id: v.id, volume_name: v.name, size_gb: v.size_gb,
            transport: "block", mount_type: "device",
            device_name: device_name, role: role,
            mount_point: ::System::Platform::StorageRecommendations.mount_point_for(account: @account, role: role),
            attached_at: Time.current.iso8601
          }
          instance.merge_config!("storage_volume" => binding)
        end
        success_result(volume: serialize_volume(v.reload, full: true), binding: binding)
      end

      def detach_volume(params)
        v = ::System::ProviderVolume.find_by(id: params[:volume_id], account: @account)
        return error_result("Volume not found") unless v
        vt_kind = v.volume_type&.volume_type.to_s

        if %w[nfs smb iscsi].include?(vt_kind)
          # Pool semantics — clear the consumer binding on the specified instance only.
          return error_result("node_instance_id is required for shared-pool detach") if params[:node_instance_id].blank?
          instance = ::System::NodeInstance.where(account_id: @account.id)
                                            .find_by(id: params[:node_instance_id])
          return error_result("Instance not found") unless instance
          bound_volume_id = bound_storage_volume_id(instance)
          return error_result("Volume not attached to this instance") unless bound_volume_id == v.id.to_s
          # A key REMOVAL is `config - ARRAY[...]` in Postgres, not a rewrite
          # of the document minus one key — see System::ConfigDocument.
          instance.delete_config_keys!("storage_volume")
          success_result(detached: true, volume_id: v.id, instance_id: instance.id)
        else
          # Block volume — flip pool status back to available.
          return error_result("Volume not currently attached") unless v.attached?
          previous_instance_id = v.node_instance_id
          v.detach!
          # Best-effort: also clear the binding from the instance's config
          instance = ::System::NodeInstance.find_by(id: previous_instance_id)
          if instance
            instance.delete_config_keys!("storage_volume")
          end
          success_result(detached: true, volume_id: v.id, instance_id: previous_instance_id)
        end
      end

      def test_nfs_export(params)
        server = params[:server].to_s.strip
        return error_result("server is required") if server.empty?

        out = {
          server: server,
          dns_resolved: nil,
          port_111_open: nil,
          port_2049_open: nil,
          exports: []
        }

        begin
          addrs = Resolv.getaddresses(server)
          out[:dns_resolved] = addrs.first
        rescue StandardError => e
          out[:dns_error] = e.message
        end

        out[:port_111_open]  = tcp_probe(server, 111, timeout: 3)
        out[:port_2049_open] = tcp_probe(server, 2049, timeout: 3)

        if out[:port_111_open]
          out[:exports] = parse_showmount_exports(server)
        end

        out[:export_path_match] =
          if params[:export_path].present?
            out[:exports].any? { |e| e[:path] == params[:export_path] }
          end

        success_result(probe: out)
      end

      def get_storage_recommendations
        recs = ::System::Platform::StorageRecommendations.fetch(account: @account)
        success_result(recommendations: recs)
      end

      def update_storage_recommendations(params)
        attrs = params[:recommendations]
        return error_result("recommendations object is required") unless attrs.is_a?(Hash)
        ok = ::System::Platform::StorageRecommendations.update!(
          account: @account, attrs: attrs, agent: @agent
        )
        return error_result("Update failed (no writable agent on default pool?)") unless ok
        success_result(recommendations: ::System::Platform::StorageRecommendations.fetch(account: @account))
      end

      # E7.3 — Persists a StorageMigration row capturing intent + plan.
      # The row starts in `planned`; operator advances via
      # system_approve_storage_migration; the on-node agent advances
      # through preparing → syncing → verifying → cutover; the agent
      # reports progress via system_report_storage_migration_progress;
      # the orchestrator marks `completed` once cutover lands.
      def migrate_storage_component(params)
        instance = ::System::NodeInstance.where(account_id: @account.id)
                                          .find_by(id: params[:node_instance_id])
        return error_result("Instance not found") unless instance
        source = ::System::ProviderVolume.find_by(id: params[:source_volume_id], account: @account)
        target = ::System::ProviderVolume.find_by(id: params[:target_volume_id], account: @account)
        return error_result("Source/target volume not found") unless source && target
        return error_result("Source and target must differ") if source.id == target.id

        role = params[:role].to_s
        return error_result("role is required") if role.blank?

        deployment_name = (instance.config&.dig("storage_volume", "deployment_name") ||
                            instance.config&.dig("storage_volume", "volume_name") ||
                            instance.name).to_s

        source_subpath = ::System::Platform::StorageLayout.subpath_for(
          deployment_name: deployment_name, role: role
        )
        target_subpath = ::System::Platform::StorageLayout.subpath_for(
          deployment_name: deployment_name, role: role
        )
        snapshot_subpath = ::System::Platform::StorageLayout.migration_subpath_for(
          deployment_name: deployment_name, role: role
        )

        plan = {
          "deployment_name" => deployment_name,
          "role" => role,
          "source" => {
            "volume_id" => source.id, "volume_name" => source.name,
            "transport" => source.volume_type&.volume_type, "subpath" => source_subpath
          },
          "target" => {
            "volume_id" => target.id, "volume_name" => target.name,
            "transport" => target.volume_type&.volume_type, "subpath" => target_subpath
          },
          "snapshot_path" => snapshot_subpath,
          "agent_contract" => {
            "v" => 1,
            "steps" => %w[mount_target snapshot rsync verify cutover unmount_source]
          }
        }

        migration = ::System::StorageMigration.create!(
          account: @account,
          node_instance: instance,
          source_volume: source,
          target_volume: target,
          initiated_by_user: @user,
          role: role,
          status: "planned",
          source_subpath: source_subpath,
          target_subpath: target_subpath,
          snapshot_subpath: snapshot_subpath,
          plan: plan
        )
        migration.append_audit!(
          message: "Migration planned by #{@user&.email || 'system'}",
          status_after: "planned"
        )

        success_result(storage_migration: serialize_storage_migration(migration))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Migration create failed: #{e.record.errors.full_messages.join(', ')}")
      end

      def list_storage_migrations(params)
        scope = ::System::StorageMigration.where(account: @account).order(created_at: :desc)
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.for_instance(params[:node_instance_id]) if params[:node_instance_id].present?
        scope = scope.active if params[:active_only]
        success_result(storage_migrations: scope.limit(100).map { |m| serialize_storage_migration(m) })
      end

      def get_storage_migration(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m
        success_result(storage_migration: serialize_storage_migration(m, full: true))
      end

      def approve_storage_migration(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m
        return error_result("Cannot approve in status=#{m.status}") unless m.can_transition_to?("approved")
        m.transition_to!(
          "approved",
          message: "Approved by #{@user&.email || 'system'}",
          details: { approved_by_user_id: @user&.id }
        )
        success_result(storage_migration: serialize_storage_migration(m.reload, full: true))
      rescue ArgumentError => e
        error_result(e.message)
      end

      def cancel_storage_migration(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m
        return error_result("Already terminal (#{m.status}) — nothing to cancel") if m.terminal?
        return error_result("Cannot cancel — sync already in progress") unless %w[planned approved preparing].include?(m.status)
        m.cancel!(reason: params[:reason], user: @user)
        success_result(storage_migration: serialize_storage_migration(m.reload, full: true))
      rescue ArgumentError => e
        error_result(e.message)
      end

      # Called by the on-node agent during sync to surface progress.
      def report_storage_migration_progress(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m

        # Optional state transition (agent advancing through phases).
        if params[:status].present?
          unless m.can_transition_to?(params[:status])
            return error_result("Illegal transition #{m.status} → #{params[:status]}")
          end
          m.transition_to!(
            params[:status],
            message: params[:note] || "Agent reported #{params[:status]}",
            details: params.slice(:bytes_copied, :bytes_total, :bytes_verified).to_h.compact
          )
        end

        m.report_progress!(
          bytes_copied: params[:bytes_copied]&.to_i,
          bytes_total: params[:bytes_total]&.to_i,
          bytes_verified: params[:bytes_verified]&.to_i,
          note: params[:note]
        )
        success_result(storage_migration: serialize_storage_migration(m.reload, full: true))
      rescue ArgumentError => e
        error_result(e.message)
      end

      # Increment 9 (R) — records revert intent; the on-node agent
      # (migration.Runner#stepRevert) picks it up on its next poll tick
      # and reports back via node_api's revert_complete.
      def revert_storage_migration_binding(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m
        m.revert_binding!(reason: params[:reason], user: @user)
        success_result(storage_migration: serialize_storage_migration(m.reload, full: true))
      rescue ArgumentError => e
        error_result(e.message)
      end

      # Increment 9 (C) — DESTRUCTIVE, target-side + subpath-scoped
      # only (never source, never the volume). Grace-window resolved
      # via Account#settings override → SiteSetting global default →
      # DEFAULT_CLEANUP_GRACE_HOURS (config-driven-config convention).
      def cleanup_storage_migration(params)
        m = ::System::StorageMigration.find_by(id: params[:id], account: @account)
        return error_result("Migration not found") unless m
        immediate = ActiveModel::Type::Boolean.new.cast(params[:immediate])
        grace_hours = ::System::StorageMigration.cleanup_grace_hours(account: @account)
        m.request_cleanup!(reason: params[:reason], user: @user, grace_hours: grace_hours, immediate: immediate)
        success_result(storage_migration: serialize_storage_migration(m.reload, full: true))
      rescue ArgumentError => e
        error_result(e.message)
      end

      def serialize_storage_migration(m, full: false)
        base = {
          id: m.id,
          status: m.status,
          role: m.role,
          node_instance_id: m.node_instance_id,
          source_volume_id: m.source_volume_id,
          target_volume_id: m.target_volume_id,
          source_subpath: m.source_subpath,
          target_subpath: m.target_subpath,
          bytes_copied: m.bytes_copied,
          bytes_total: m.bytes_total,
          bytes_verified: m.bytes_verified,
          created_at: m.created_at.iso8601,
          approved_at: m.approved_at&.iso8601,
          started_at: m.started_at&.iso8601,
          completed_at: m.completed_at&.iso8601,
          failed_at: m.failed_at&.iso8601,
          cancelled_at: m.cancelled_at&.iso8601,
          error_message: m.error_message
        }
        return base unless full
        base.merge(
          plan: m.plan,
          audit_log: m.audit_log,
          metadata: m.metadata,
          snapshot_subpath: m.snapshot_subpath
        )
      end

      # === Lifecycle skill MCP wrappers (MCP.2) ===

      # Inner-action key is `op:` (not `action:`) because the MCP
      # dispatcher uses `params[:action]` for the tool name itself —
      # using the same key for the sub-action would shadow it.
      def platform_maintenance(params)
        op = params[:op].presence || params[:maintenance_action].presence
        return error_result("op is required (cert_status | cert_rotate | drift_check | health_check)") if op.blank?

        executor = build_skill_executor(::System::Ai::Skills::PlatformMaintenanceExecutor)
        result = executor.execute(
          action: op.to_s,
          certificate_id: params[:certificate_id],
          deployment_id: params[:deployment_id],
          renewal_window_days: params[:renewal_window_days]
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      def platform_resilience(params)
        op = params[:op].presence || params[:resilience_action].presence
        return error_result("op is required (drain_instance | scale | failover_check)") if op.blank?

        executor = build_skill_executor(::System::Ai::Skills::PlatformResilienceExecutor)
        result = executor.execute(
          action: op.to_s,
          instance_id: params[:instance_id],
          deployment_id: params[:deployment_id],
          direction: params[:direction],
          target_replicas: params[:target_replicas],
          timeout_seconds: params[:timeout_seconds]
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === Volume helpers ===

      def serialize_volume(v, full: false)
        base = {
          id: v.id, name: v.name, size_gb: v.size_gb, status: v.status,
          transport: v.volume_type&.volume_type, volume_type_id: v.volume_type_id,
          volume_type_name: v.volume_type&.name,
          attached_to: v.node_instance_id, device_name: v.device_name,
          external_id: v.external_id
        }
        return base unless full
        base.merge(
          description: v.description, encrypted: v.encrypted,
          delete_on_termination: v.delete_on_termination,
          config: v.config, created_at: v.created_at.iso8601
        )
      end

      # F4-11 — never guess the provider on multi-provider accounts: the old
      # order(:created_at).first bound volumes to an arbitrary provider,
      # corrupting Registry.for_volume adapter resolution. Returns a
      # ProviderRegion, or an error_result Hash for the caller to pass
      # through.
      def resolve_volume_region(params)
        if params[:provider_region_id].present?
          region = ::System::ProviderRegion.where(account: @account).find_by(id: params[:provider_region_id])
          return error_result("provider_region_id not found in account") unless region
          if params[:provider_id].present? && region.provider_id != params[:provider_id]
            return error_result("provider_region_id does not belong to provider_id")
          end

          return region
        end

        if params[:provider_id].present?
          provider = ::System::Provider.where(account: @account).find_by(id: params[:provider_id])
          return error_result("provider_id not found in account") unless provider

          region = ::System::ProviderRegion.where(provider: provider).order(:created_at).first
          return error_result("provider #{provider.name} has no regions") unless region

          return region
        end

        providers = ::System::Provider.where(account: @account).order(:created_at).to_a
        case providers.size
        when 0
          error_result("No provider/region available for account")
        when 1
          region = ::System::ProviderRegion.where(provider: providers.first).order(:created_at).first
          region || error_result("No provider/region available for account")
        else
          candidates = providers.map { |p| "#{p.id} (#{p.name})" }.join(", ")
          error_result(
            "Account has #{providers.size} providers — pass provider_id or provider_region_id " \
            "instead of letting the platform guess. Candidates: #{candidates}"
          )
        end
      end

      def resolve_or_create_volume_type(params, provider, transport)
        return ::System::ProviderVolumeType.find_by(id: params[:volume_type_id]) if params[:volume_type_id].present?

        # Find existing matching type — by transport + provider
        existing = ::System::ProviderVolumeType.where(
          account: @account, provider: provider, volume_type: transport
        ).order(:created_at).first
        return existing if existing

        # Auto-create a default type for this transport
        ::System::ProviderVolumeType.create!(
          account: @account, provider: provider,
          name: "#{transport}-default",
          description: "Auto-created #{transport.upcase} volume type",
          volume_type: transport,
          min_size_gb: 1,
          max_size_gb: 100_000,
          enabled: true,
          specs: {}
        )
      end

      def build_volume_config(params, transport)
        case transport
        when "nfs"
          {
            "transport" => "nfs",
            "nfs" => {
              "server" => params[:nfs_server].to_s,
              "export_path" => params[:nfs_export_path].to_s,
              "version" => params[:nfs_version].to_s.presence || "4.1",
              "mount_options" => "nfsvers=#{params[:nfs_version].to_s.presence || '4.1'},hard,rsize=1048576,wsize=1048576,proto=tcp"
            },
            "discovered_via" => "mcp_create_volume"
          }
        else
          { "transport" => transport }
        end
      end

      def external_id_for(transport, params)
        case transport
        when "nfs" then "nfs://#{params[:nfs_server]}#{params[:nfs_export_path]}"
        else nil
        end
      end

      # The volume_id currently bound in this instance's single
      # config["storage_volume"] slot, or nil if unbound. Shared by
      # attach_volume's clobber guard and detach_volume's ownership check.
      def bound_storage_volume_id(instance)
        instance.config&.dig("storage_volume", "volume_id")&.to_s
      end

      def next_block_device_for(instance)
        attached = ::System::ProviderVolume.where(node_instance_id: instance.id).pluck(:device_name).compact
        ("b".."z").each do |letter|
          dev = "/dev/vd#{letter}"
          return dev unless attached.include?(dev)
        end
        "/dev/vdb"
      end

      def tcp_probe(host, port, timeout: 3)
        Socket.tcp(host, port, connect_timeout: timeout) { |sock| sock.close }
        true
      rescue StandardError
        false
      end

      def parse_showmount_exports(server)
        # Open3.capture3 doesn't support :timeout — use Timeout.timeout
        # to bound the call so a hung NFS server doesn't wedge the
        # MCP dispatch indefinitely.
        out = nil
        Timeout.timeout(10) do
          out, _err, status = Open3.capture3("showmount", "-e", "--no-headers", server)
          return [] unless status.success?
        end
        return [] unless out
        out.lines.map(&:strip).reject(&:empty?).map do |line|
          path, acl = line.split(/\s+/, 2)
          { path: path, acl: acl }
        end
      rescue StandardError
        []
      end

      # === Compliance snapshot ===

      def compliance_snapshot(_params)
        result = ::System::Compliance::ComplianceSnapshotService.snapshot!(account: @account)
        return error_result(result.error) unless result.ok?
        success_result(snapshot: result.snapshot, generated_at: result.generated_at.iso8601)
      end

      # === Runbook generation ===

      def runbook_generate(params)
        executor = build_skill_executor(::System::Ai::Skills::RunbookGenerateExecutor)
        result = executor.execute(
          template_id: params[:template_id],
          persist_as_page: params[:persist_as_page] || false
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === CVE remediation runbook (Phase 10.7) ===

      def cve_runbook_generate(params)
        executor = build_skill_executor(::System::Ai::Skills::CveRunbookGenerateExecutor)
        result = executor.execute(
          cve_id: params[:cve_id],
          persist_as_page: params[:persist_as_page] || false
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === CVE triage ===

      def cve_triage(params)
        executor = build_skill_executor(::System::Ai::Skills::CveResponseExecutor)
        result = executor.execute(
          cve_id: params[:cve_id],
          severity: params[:severity],
          affected_packages: Array(params[:affected_packages]),
          summary: params[:summary],
          persist: params[:persist] || false
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === Recent signals (observability surface) ===

      def recent_signals(params)
        scope = ::System::FleetEvent.where(account: @account).recent
        if params[:correlation_id].present?
          scope = scope.by_correlation(params[:correlation_id])
        elsif params[:kind].present?
          scope = scope.by_kind(params[:kind])
        end
        limit = (params[:limit] || 50).to_i.clamp(1, 200)
        events = scope.limit(limit)
        success_result(
          events: events.map(&:as_broadcast),
          count: events.size,
          channel: "system_fleet:#{@account.id}"
        )
      end

      # === Attribution — failure causation ===

      def attribute_failure(params)
        executor = build_skill_executor(::System::Ai::Skills::AttributeFailureExecutor)
        result = executor.execute(
          instance_id: params[:instance_id],
          lookback_hours: params[:lookback_hours] || 24
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === Inspect one correlation chain ===

      def inspect_correlation(params)
        cid = params[:correlation_id].to_s
        return error_result("correlation_id required") if cid.blank?

        events = ::System::FleetEvent
          .where(account: @account, correlation_id: cid)
          .order(:emitted_at)
        success_result(
          correlation_id: cid,
          events: events.map(&:as_broadcast),
          count: events.size,
          duration_seconds: (events.last && events.first ? (events.last.emitted_at - events.first.emitted_at).to_f : 0).round(3)
        )
      end

      # === Scope helpers (account-scoped) ===

      def account_nodes
        ::System::Node.where(account: @account)
      end

      def account_templates
        ::System::NodeTemplate.where(account: @account)
      end

      def account_modules
        ::System::NodeModule.where(account: @account)
      end

      def account_instances
        ::System::NodeInstance.where(account_id: @account.id)
      end

      # === Serializers ===

      def serialize_node(n)
        {
          id: n.id,
          name: n.name,
          template_id: n.node_template_id,
          worker_id: n.worker_id,
          ssh_key_fingerprint: n.ssh_key_fingerprint,
          ssh_key_type: n.ssh_key_type,
          enabled: n.enabled,
          created_at: n.created_at.iso8601
        }
      end

      def serialize_node_full(n)
        serialize_node(n).merge(
          template_name: n.node_template&.name,
          instance_count: n.node_instances.count,
          module_count: n.node_module_assignments.count,
          ssh_host_key_fingerprint: n.ssh_host_key_fingerprint
        )
      end

      def serialize_instance(i)
        {
          id: i.id,
          name: i.name,
          node_id: i.node_id,
          variety: i.variety,
          status: i.status,
          architecture: i.architecture,
          private_ip: i.private_ip_address,
          public_ip: i.public_ip_address,
          last_heartbeat_at: i.last_heartbeat_at&.iso8601,
          mtls_subject: i.mtls_subject,
          agent_version: i.agent_version,
          gpu_count: i.gpu_count,
          gpu_type: i.gpu_type,
          gpu_memory_mb: i.gpu_memory_mb
        }
      end

      def serialize_instance_full(i)
        serialize_instance(i).merge(
          cloud_instance_id: i.cloud_instance_id, # store_accessor on :config
          boot_id: i.boot_id,
          running_module_digests: i.running_module_digests,
          provider_region_id: i.provider_region_id,
          provider_instance_type_id: i.provider_instance_type_id,
          # IMP-b8d5cfa33b79 — the agent's boot/LKG telemetry. This is the
          # surface on which "is this node armed with a valid last-known-good,
          # so its control plane can be decommissioned?" is actually asked, so
          # ingesting the heartbeat without exposing it here would just move
          # the dead end one step later.
          #
          # nil means NO document: the instance has not heartbeated since this
          # ingest existed, or its agent predates #39. nil is therefore NOT
          # "armed" and a decommission gate must treat it as blocking, exactly
          # as it must treat `arm_state: "unreported"` inside the document.
          # Once a document exists the agent refreshes it every tick, so a
          # present document is never older than the last heartbeat (see
          # System::BootLkgStateWriter).
          #
          # Reads the ONE key rather than handing the caller the whole `config`
          # jsonb, which also holds operator- and provider-written material.
          boot_lkg: i.config&.dig(::System::BootLkgStateWriter::CONFIG_KEY)
        )
      end

      def serialize_instance_type_gpu(t)
        {
          id: t.id,
          name: t.name,
          provider_id: t.provider_id,
          instance_type_code: t.instance_type_code,
          vcpus: t.vcpus,
          memory_mb: t.memory_mb,
          gpu_count: t.gpu_count,
          gpu_type: t.gpu_type,
          gpu_memory_mb: t.gpu_memory_mb,
          summary: t.display_name
        }
      end

      def serialize_template(t)
        # NodeTemplate doesn't carry node_architecture_id directly — it lives
        # on NodePlatform (legacy delegation pattern). Walk through if needed.
        {
          id: t.id,
          name: t.name,
          platform_id: t.node_platform_id,
          architecture_id: t.node_platform&.node_architecture_id,
          enabled: t.enabled
        }
      end

      # Carries every field system_update_template can set, so an agent told to
      # "read the current config before replacing it" can actually do that —
      # the write surface used to be wider than anything the read surface
      # returned. Each assigned module reports its JOIN state too: a caller
      # cannot decide what to disable without seeing what is enabled.
      def serialize_template_full(t)
        joins = t.template_modules.includes(:node_module).order(priority: :desc)
        serialize_template(t).merge(
          description: t.description,
          public: t.public,
          admin_user: t.admin_user,
          config: t.config,
          modules: joins.filter_map { |tm|
            next unless tm.node_module

            { id: tm.node_module_id, name: tm.node_module.name, variety: tm.node_module.variety,
              template_module_id: tm.id, enabled: tm.enabled, priority: tm.priority }
          },
          node_count: t.nodes.count
        )
      end

      def serialize_module(m)
        {
          id: m.id,
          name: m.name,
          variety: m.variety,
          priority: m.priority,
          category_id: m.category_id,
          enabled: m.enabled,
          public: m.public,
          locked: m.lock_spec,
          current_version_number: m.current_version_number,
          gitea_repo_full_name: m.gitea_repo_full_name,
          cosign_identity_regexp: m.cosign_identity_regexp,
          cosign_issuer_regexp: m.cosign_issuer_regexp
        }
      end

      # Discovery match payloads. Shaped like discover_packages_by_intent's
      # results (id / name / similarity / reason) so an agent reading both
      # surfaces parses one shape, plus the fields that let it act on the hit
      # without a follow-up system_get_module call.
      def serialize_module_match(m, intent)
        similarity = ::System::CatalogDiscoveryService.similarity_for(m)
        caps = Array(m.capabilities).map(&:to_s).reject(&:empty?).first(3)
        reason = "Semantic match for '#{intent}' (similarity #{similarity})"
        reason += " — provides #{caps.join(', ')}" if caps.any?

        {
          module_id:   m.id,
          name:        m.name,
          variety:     m.variety,
          description: m.description.to_s.truncate(240).presence,
          category_id: m.category_id,
          enabled:     m.enabled,
          similarity:  similarity,
          reason:      reason
        }
      end

      def serialize_template_match(t, intent)
        similarity = ::System::CatalogDiscoveryService.similarity_for(t)
        {
          template_id:  t.id,
          name:         t.name,
          description:  t.description.to_s.truncate(240).presence,
          platform_id:  t.node_platform_id,
          enabled:      t.enabled,
          module_count: t.node_modules.count,
          similarity:   similarity,
          reason:       "Semantic match for '#{intent}' (similarity #{similarity})"
        }
      end

      def serialize_module_full(m)
        serialize_module(m).merge(
          dependant: m.respond_to?(:dependant?) ? m.dependant? : false,
          parent_module_id: m.try(:parent_module_id),
          assignment_count: m.node_module_assignments.count,
          template_count: m.template_modules.count,
          reuse_check: serialize_reuse_check(m)
        )
      end

      # IMP-45bda04c6123 — the recorded reuse check, read back. `config` is not
      # serialized on this surface, so without this the coverage stamp would be
      # write-only over MCP and no agent could ever tell a survey of a searchable
      # catalog from one that saw nothing.
      def serialize_reuse_check(m)
        recorded = (m.config || {})["reuse_check"]
        return nil unless recorded.is_a?(Hash)

        {
          justification:    recorded["justification"],
          checked_at:       recorded["checked_at"],
          catalog_coverage: recorded["catalog_coverage"],
          unindexed_catalog_ack: recorded[REUSE_UNINDEXED_ACK]
        }
      end

      def serialize_version(v)
        {
          id: v.id,
          module_id: v.node_module_id,
          version_number: v.version_number,
          promotion_state: v.promotion_state,
          # IMP-65bea54e4081 — promotion_state is the ladder; `current` is
          # whether the fleet actually serves this row (NodeModuleVersion#
          # current?, i.e. the module's current_version_id). The two are
          # independent: nothing in the promotion path moves the pointer, and
          # publish can make a never-promoted version current. Without this
          # field a "live" version and the served version look the same here.
          current: v.current?,
          oci_digest: v.try(:oci_digest),
          fsverity_root_hash: v.try(:fsverity_root_hash),
          live_at: v.try(:live_at)&.iso8601,
          retired_at: v.try(:retired_at)&.iso8601
        }
      end

      # Max characters of error_message returned by the LIST surface, and by
      # the single-task read. SIZE controls only — redaction runs first and
      # unconditionally, so truncation is never what keeps a secret out of the
      # payload. The single-task cap exists because the column is unbounded
      # `text` written straight from an agent-supplied param
      # (Api::V1::Internal::System::TasksController#fail), so "return the full
      # text" without a ceiling hands a multi-megabyte blob to the MCP
      # transport on the word of the node that failed.
      LIST_ERROR_MESSAGE_LIMIT = 300
      GET_ERROR_MESSAGE_LIMIT  = 16_384

      # `full_error: true` returns the whole (redacted) error_message — the
      # single-task read, where the operator came specifically for the reason.
      # The list surface gets the same redacted text, capped.
      def serialize_task(t, full_error: false)
        {
          id: t.id,
          command: t.command,
          status: t.status,
          progress: t.progress,
          operable_type: t.operable_type,
          operable_id: t.operable_id,
          error_message: task_error_message(t.error_message, full: full_error),
          created_at: t.created_at.iso8601,
          completed_at: t.completed_at&.iso8601
        }
      end

      # IMP-b8af3c3309fe — error_message is populated on every failure
      # transition but was never serialized, so a failed task read as
      # `status: "failed"` with no reason, and diagnosing one required a
      # read-only Postgres breakglass on the control plane.
      #
      # It holds BUILD AND SHELL OUTPUT, which can quote command lines, env
      # and argv, so it is redacted through the extension's own shell-output
      # sanitizer before it leaves the process (CLAUDE.md: never transmit key
      # material in any form). .redact_text rather than .redact because the
      # sanitizer's own log cap must not silently become this surface's size
      # policy — REDACT FIRST, then apply the per-surface limit, so a secret
      # sitting past the cap is gone from BOTH the truncated and the full copy.
      def task_error_message(raw, full:)
        return nil if raw.blank?

        limit = full ? GET_ERROR_MESSAGE_LIMIT : LIST_ERROR_MESSAGE_LIMIT
        # .scrub — the redaction regexes raise ArgumentError on invalid UTF-8,
        # and this is captured node output, not text the platform authored.
        text = raw.to_s.scrub("")

        # Bounding the redaction INPUT (rather than only its output) keeps a
        # list call from running every pattern over 100 unbounded blobs. Safe
        # because everything past `limit` is discarded anyway: a secret cut by
        # this 4x slice lies far outside the returned window, since redaction
        # can only grow a matched run by a small constant factor.
        redacted = ::System::ShellOutputSanitizer.redact_text(text[0, limit * 4])
        return redacted if redacted.length <= limit

        "#{redacted[0, limit]}...[truncated]"
      end

      # Mirrors NodeModuleAssignmentsController#serialize_assignment.
      def serialize_module_assignment(a)
        {
          id: a.id,
          node_id: a.node_id,
          node_module_id: a.node_module_id,
          enabled: a.enabled,
          priority: a.priority,
          config: a.config,
          created_at: a.created_at&.iso8601,
          updated_at: a.updated_at&.iso8601
        }
      end

      # ────────────────────────────────────────────────────────────────
      # Slice 7 — instance pool action handlers
      # ────────────────────────────────────────────────────────────────

      def list_instance_pools(_params)
        pools = ::System::InstancePool.for_account(@account).order(:name)
        success_result(
          pools: pools.map(&:to_summary),
          count: pools.count
        )
      end

      def get_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        success_result(
          pool: pool.to_summary.merge(
            members: pool.node_instances.order(:pool_state, :pool_warming_started_at).limit(50).map do |m|
              {
                id: m.id,
                name: m.name,
                pool_state: m.pool_state,
                status: m.status,
                pool_warming_started_at: m.pool_warming_started_at&.utc&.iso8601,
                pool_acquired_at: m.pool_acquired_at&.utc&.iso8601
              }
            end
          )
        )
      end

      def create_instance_pool(params)
        template = ::System::NodeTemplate.for_account(@account).find(params[:template_id])
        pool = ::System::InstancePool.create!(
          account: @account,
          node_template: template,
          name: params[:name],
          target_size: params[:target_size],
          min_size: params[:min_size] || 0,
          max_size: params[:max_size] || (params[:target_size].to_i + 10),
          lifecycle_class: params[:lifecycle_class] || "ephemeral",
          provider_region_id: params[:provider_region_id],
          provider_instance_type_id: params[:provider_instance_type_id],
          preferred_regions: Array(params[:preferred_regions]).compact_blank
        )
        success_result(pool: pool.to_summary)
      rescue ActiveRecord::RecordInvalid => e
        error_result("instance pool validation failed: #{e.message}")
      end

      # F8-07 — REST update parity (instance_pools_controller update_params).
      # Template is create-only, so it's intentionally not updatable here.
      def update_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        attrs = params.slice(
          :description, :target_size, :min_size, :max_size, :status,
          :provider_region_id, :provider_instance_type_id, :metadata, :preferred_regions
        ).to_h.compact
        # Normalize the cross-AZ list (empty array clears it back to single-AZ).
        attrs[:preferred_regions] = Array(attrs[:preferred_regions]).compact_blank if attrs.key?(:preferred_regions)
        return error_result("no mutable fields supplied") if attrs.empty?

        pool.update!(attrs)
        success_result(pool: pool.reload.to_summary)
      rescue ActiveRecord::RecordInvalid => e
        error_result("instance pool validation failed: #{e.message}")
      end

      def drain_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        result = ::System::InstancePoolService.drain!(pool: pool)
        success_result(pool: pool.reload.to_summary, drain_result: result)
      end

      def acquire_pooled_instance(params)
        instance = ::System::InstancePoolService.acquire!(
          account: @account,
          pool_name: params[:pool_name],
          pool_id: params[:pool_id],
          lifecycle_class: params[:lifecycle_class]
        )
        success_result(
          instance: {
            id: instance.id,
            name: instance.name,
            status: instance.status,
            pool_state: instance.pool_state,
            instance_pool_id: instance.instance_pool_id,
            pool_acquired_at: instance.pool_acquired_at&.utc&.iso8601,
            private_ip_address: instance.private_ip_address,
            public_ip_address: instance.public_ip_address
          }
        )
      rescue ::System::InstancePoolService::NoReadyMembersError => e
        error_result("no ready pool members: #{e.message}")
      rescue ::System::InstancePoolService::PoolError => e
        error_result(e.message)
      end

      # Manual recycle trigger — same call the worker reaper makes every
      # 60s in its 2-phase tick. Lets impatient operators (or AI agents
      # diagnosing a wedged pool) force the recycle phase without
      # waiting for the next tick.
      def recycle_pool(params)
        pool = ::System::InstancePool.where(account_id: @account.id).find(params[:id])
        result = ::System::InstancePoolService.recycle_stale_members!(pool: pool)
        success_result(pool: pool.reload.to_summary, recycle_result: result)
      end

      def replenish_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        result = ::System::InstancePoolService.replenish!(pool: pool)
        success_result(pool: pool.reload.to_summary, replenish_result: result)
      rescue ::System::InstancePoolService::PoolError => e
        error_result(e.message)
      end

      # === Gap remediation slice 1 (Phase 4 — operator-runbook-driven actions) ===

      # Records drain intent on a NodeInstance — emits a FleetEvent so
      # observability tooling and (eventually) autonomy reconcilers can
      # coordinate workload relocation. v1 is observation-only: workloads
      # keep running; operator must call system_terminate_instance after
      # relocation completes. Future versions will integrate K8s cordon
      # + Docker container stop into this same handle.
      def drain_instance(params)
        instance = account_instances.find(params[:instance_id])
        timeout = (params[:timeout_seconds] || 600).to_i
        initiated_at = Time.current.iso8601

        # NodeInstance has `config` (JSONB) but no dedicated `metadata` column.
        # Drain state lives under `config["drain_*"]` keys. Future migration
        # may promote these to a typed column when drain logic gains
        # cordon/stop integration.
        # Two keys only — see System::ConfigDocument. Mutating the loaded
        # document and calling save! writes the WHOLE jsonb back, erasing every
        # heartbeat telemetry key the node wrote since this object was found.
        instance.merge_config!(
          "drain_initiated_at" => initiated_at,
          "drain_timeout_seconds" => timeout
        )

        if defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account: @account,
            kind: "system.instance.drain_initiated",
            severity: "low",
            node_instance_id: instance.id,
            payload: {
              "drain_timeout_seconds" => timeout,
              "initiated_by" => @user&.id || "system"
            },
            correlation_id: SecureRandom.uuid
          )
        end

        success_result(
          drained: true,
          instance: serialize_instance(instance.reload),
          drain_initiated_at: initiated_at,
          drain_timeout_seconds: timeout,
          next_step: "operator should call system_terminate_instance after workloads relocate"
        )
      end

      # Returns NodeInstances whose last_heartbeat_at is older than the
      # silent threshold, or null. Aligned with InstanceStatusSensor
      # (default 3 minutes; configurable via threshold_seconds).
      def get_silent_instances(params)
        threshold = (params[:threshold_seconds] || 180).to_i
        cutoff = Time.current - threshold.seconds
        scope = account_instances.where(
          "last_heartbeat_at < ? OR last_heartbeat_at IS NULL", cutoff
        )

        success_result(
          silent_count: scope.size,
          threshold_seconds: threshold,
          cutoff: cutoff.iso8601,
          instances: scope.order(last_heartbeat_at: :asc).limit(200).map { |i| serialize_instance(i) }
        )
      end

      # Pure-validation entry point for module manifest YAML — no DB writes.
      # Operators lint manifests locally before pushing to CI; AI Concierge
      # uses this to surface schema errors in chat.
      def validate_module_manifest(params)
        node_module = account_modules.find(params[:module_id])
        result = ::System::ManifestImportService.validate_only(
          yaml: params[:manifest_yaml],
          node_module: node_module
        )

        if result.ok?
          success_result(valid: true, validation_errors: [])
        else
          success_result(
            valid: false,
            error: result.error,
            validation_errors: Array(result.validation_errors)
          )
        end
      end

      # === Gap remediation slice 2 — CVE catalog + module assignment cleanup ===

      # Cves are GLOBAL (not account-scoped). All read/write actions on Cve
      # rows operate on the shared catalog. Account-scoping for exposure
      # lookups happens in get_cve_exposure via the CveExposure → NodeModuleVersion → NodeModule chain.

      def get_cve(params)
        cve = ::System::Cve.find_by(cve_id: params[:cve_id])
        return error_result("CVE #{params[:cve_id]} not found") unless cve
        success_result(cve: serialize_cve(cve))
      end

      def get_cve_exposure(params)
        cve = ::System::Cve.find_by(cve_id: params[:cve_id])
        return error_result("CVE #{params[:cve_id]} not found") unless cve

        # Scope exposures to the current account via the NodeModule chain.
        exposures = cve.cve_exposures
                       .joins(node_module_version: :node_module)
                       .where(system_node_modules: { account_id: @account.id })
                       .includes(node_module_version: :node_module)

        # Group by module for the operator-friendly aggregate shape.
        by_module = exposures.group_by { |e| e.node_module_version.node_module }

        exposed_modules = by_module.map do |mod, exps|
          {
            id: mod.id,
            name: mod.name,
            version_number: exps.first.node_module_version.version_number,
            assignment_count: exps.size,
            states: exps.group_by(&:state).transform_values(&:size)
          }
        end

        success_result(
          cve_id: cve.cve_id,
          severity: cve.severity,
          severity_weight: cve.severity_weight,
          exposed_modules: exposed_modules,
          exposed_module_count: exposed_modules.size,
          exposed_instance_count: exposed_modules.sum { |m| m[:assignment_count] }
        )
      end

      def create_cve(params)
        cve = ::System::Cve.find_or_initialize_by(cve_id: params[:cve_id])
        was_new = cve.new_record?

        cve.assign_attributes(
          severity: params[:severity],
          summary: params[:summary],
          affected_packages: Array(params[:affected_packages]),
          feed_source: params[:feed_source].presence || "manual",
          published_at: params[:published_at] || Time.current,
          reference_url: params[:reference_url]
        )
        cve.save!

        success_result(
          created: was_new,
          updated: !was_new,
          cve: serialize_cve(cve)
        )
      end

      def delete_cve(params)
        cve = ::System::Cve.find_by(cve_id: params[:cve_id])
        return error_result("CVE #{params[:cve_id]} not found") unless cve

        cve_id_value = cve.cve_id
        exposure_count = cve.cve_exposures.count
        cve.destroy!

        success_result(
          deleted: true,
          cve_id: cve_id_value,
          cascaded_exposure_count: exposure_count
        )
      end

      def unassign_module_from_template(params)
        template = account_templates.find(params[:template_id])
        node_module = account_modules.find(params[:module_id])

        join = ::System::TemplateModule.where(
          node_template: template,
          node_module: node_module
        ).first

        unless join
          # Idempotent — operator probably retrying after partial state
          return success_result(
            unassigned: false,
            already_absent: true,
            template_id: template.id,
            module_id: node_module.id
          )
        end

        join_id = join.id
        shipped = join.enabled
        join.destroy!

        payload = {
          unassigned: true,
          template_module_id: join_id,
          template_id: template.id,
          module_id: node_module.id
        }
        # Removing a SHIPPING join is the highest-blast-radius join mutation
        # there is — it takes a module off every node on the template. Gating
        # only the assign would have left the more destructive door open.
        if shipped && (radius = record_template_blast_radius(template, node_module, "module_unassigned"))
          payload[:blast_radius] = radius
        end
        success_result(payload)
      end

      # Enable/disable a NodeModuleAssignment — mirrors the
      # NodeModuleAssignmentsController#enable / #disable member actions
      # (same enabled-column toggle, same per-account scope through the
      # owning Node). enabled=true → enable, false → disable. Idempotent.
      def update_module_assignment(params)
        assignment = ::System::NodeModuleAssignment
                     .joins(:node)
                     .where(system_nodes: { account_id: @account.id })
                     .find(params[:assignment_id])

        enabled = params[:enabled]
        if enabled.nil?
          return error_result("enabled is required (true to enable, false to disable)")
        end

        assignment.update!(enabled: enabled)

        success_result(
          updated: true,
          assignment: serialize_module_assignment(assignment)
        )
      end

      def serialize_cve(cve)
        {
          id: cve.id,
          cve_id: cve.cve_id,
          severity: cve.severity,
          severity_weight: cve.severity_weight,
          summary: cve.summary,
          reference_url: cve.reference_url,
          affected_packages: cve.normalized_affected_packages,
          published_at: cve.published_at&.iso8601,
          ingested_at: cve.ingested_at&.iso8601,
          feed_source: cve.feed_source,
          metadata: cve.metadata
        }
      end

      # === Gap remediation slice 3 — pool ops + canary marking ===

      # Returns a claimed pool instance back to its origin pool. F2-03: the
      # default disposition is "recycled" — pool_state flips to 'draining' and
      # the VM is terminated so replenish! provisions a FRESH member, never
      # re-serving the prior consumer's on-disk state / credentials / agent
      # memory to the next mission. Pools whose consumers share one trust
      # domain may opt into reuse via metadata["reuse_without_reset"], which
      # restores the claimed → 'ready' flip ("reused" disposition).
      def return_pooled_instance(params)
        instance = account_instances.find(params[:instance_id])

        unless instance.instance_pool_id
          return error_result("instance #{instance.id} has no instance_pool_id — was never a pool member")
        end

        unless instance.pool_state == "claimed"
          return error_result("instance #{instance.id} is in pool_state=#{instance.pool_state.inspect}, can only return 'claimed' instances")
        end

        pool = ::System::InstancePool.for_account(@account).find(instance.instance_pool_id)
        disposition = ::System::InstancePoolService.release!(instance: instance, pool: pool)

        success_result(
          returned: true,
          disposition: disposition,
          instance: serialize_instance(instance.reload),
          pool: pool.reload.to_summary
        )
      end

      # Destroys an InstancePool. Errors if the pool still has any members
      # (operator must drain first). Idempotent: returns success when the pool
      # is already drained + has zero members.
      def delete_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])

        member_count = pool.node_instances.count
        if member_count.positive?
          return error_result(
            "pool #{pool.name} still has #{member_count} member(s) — drain first via system_drain_instance_pool"
          )
        end

        pool_id = pool.id
        pool_name = pool.name
        pool.destroy!

        success_result(deleted: true, pool_id: pool_id, pool_name: pool_name)
      end

      # Marks a NodeModule as a honeypot canary. Delegates to CanaryModuleService.
      # Idempotent — re-marking is a no-op (CanaryModuleService.mark! returns
      # without touching config).
      def module_mark_canary(params)
        node_module = account_modules.find(params[:module_id])
        lure_kind = params[:lure_kind].presence || "credential_store"

        ::System::Honeypot::CanaryModuleService.mark!(
          node_module: node_module,
          lure_kind: lure_kind
        )

        success_result(
          marked: true,
          module_id: node_module.id,
          module_name: node_module.name,
          lure_kind: lure_kind,
          canary: ::System::Honeypot::CanaryModuleService.canary?(node_module: node_module.reload)
        )
      end

      # === Gap remediation slice 5 — disk image CI ===

      def list_disk_image_publications(params)
        scope = ::System::DiskImagePublication.where(account_id: @account.id)
        scope = scope.where(node_platform_id: params[:node_platform_id]) if params[:node_platform_id].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.order(created_at: :desc).limit((params[:limit] || 50).to_i)

        success_result(
          publications: scope.map { |p| serialize_disk_image_publication(p) },
          count: scope.size
        )
      end

      # "Default" = the publication whose facts are copied onto the parent
      # NodePlatform's disk_image_oci_ref + disk_image_git_sha columns; that's
      # what new instances boot from. Only published publications are eligible.
      def set_default_disk_image_publication(params)
        publication = ::System::DiskImagePublication.where(account_id: @account.id).find(params[:publication_id])

        unless publication.status == "published"
          return error_result(
            "publication #{publication.id} is in status=#{publication.status.inspect}, only 'published' publications can be set as default"
          )
        end

        platform = publication.node_platform
        # Route through the executor so ALL image pointers update atomically +
        # consistently (file_object, sha256, size_bytes, oci_ref, git_sha), and
        # so the prior publication is retired in the same transaction. A partial
        # update here would leave the platform naming one image by git_sha and
        # another by file_object.
        #
        # The UKI pins are deliberately NOT part of this set: they live only on
        # the publication row, which every reader resolves through git_sha
        # (IMP-dbd848ce393c). Mirroring them onto the platform is what used to
        # let a stale pin smear a mismatched (uki, bundle) pair into an upgrade
        # task — see spec/services/system/boot_image/uki_pin_single_source_spec.rb.
        ::System::Executors::DiskImage::PromotePublication.execute(
          { "publication_id" => publication.id }, deferred_operation: nil
        )
        platform.reload

        success_result(
          set_default: true,
          publication_id: publication.id,
          node_platform_id: platform.id,
          oci_ref: platform.disk_image_oci_ref,
          git_sha: platform.disk_image_git_sha
        )
      end

      # Roll a platform's disk image back to a prior publication. Account
      # scoping happens HERE (platform + target resolved within the account)
      # before delegating to the executor, which looks up by raw id. This is
      # the same transaction DiskImagePublicationsController#rollback runs on
      # its :proceed path — both go through System::Executors::DiskImage::RollbackPublication.
      def revert_disk_image(params)
        platform = ::System::NodePlatform.where(account_id: @account.id).find(params[:platform_id])

        target =
          if params[:publication_id].present?
            platform.disk_image_publications.find_by(id: params[:publication_id])
          else
            previous_disk_image_publication(platform)
          end

        unless target
          return error_result(
            params[:publication_id].present? ?
              "DiskImagePublication #{params[:publication_id]} not found for this platform" :
              "No prior publication available to revert to for platform #{platform.id}"
          )
        end

        if target.purged?
          return error_result(
            "Cannot revert to a purged publication — its FileObject was hard-deleted past the grace window. Re-trigger CI to rebuild."
          )
        end

        unless target.file_object_id.present?
          return error_result("Target publication #{target.id} has no file_object — was it ever published?")
        end

        result = ::System::Executors::DiskImage::RollbackPublication.execute(
          { target_publication_id: target.id, platform_id: platform.id },
          deferred_operation: nil
        )

        success_result(
          reverted: true,
          node_platform_id: platform.id,
          activated_publication_id: target.id,
          rolled_back_to: result.dig(:data, :rolled_back_to)
        )
      end

      # Newest "prior" publication for auto-revert: prefer the most recent
      # retired publication; otherwise the most recent published one that
      # isn't the currently-active image.
      def previous_disk_image_publication(platform)
        retired = platform.disk_image_publications
                          .where(status: "retired")
                          .order(created_at: :desc)
                          .first
        return retired if retired

        platform.disk_image_publications
                .where(status: "published")
                .where.not(file_object_id: platform.disk_image_file_object_id)
                .order(created_at: :desc)
                .first
      end

      def set_disk_image_retention(params)
        platform = ::System::NodePlatform.where(account_id: @account.id).find(params[:node_platform_id])
        retention_count = params[:retention_count].to_i

        if retention_count < 1
          return error_result("retention_count must be ≥1 (got #{retention_count})")
        end

        platform.update!(disk_image_retention_count: retention_count)

        success_result(
          updated: true,
          node_platform_id: platform.id,
          disk_image_retention_count: platform.disk_image_retention_count
        )
      end

      # SECRET DISCLOSURE (IMP-27cc7dceb97b). This used to return
      # `token_plaintext: worker.token`. It is the extension-side ALIAS of
      # Ai::Tools::DiskImageOperatorTool#provision_ci_worker, which core fixed
      # the same way in badbaef6c (IMP-fa6cf8ee1eb6) — and this alias is in the
      # production instance grant, so an agent told "provision_ci_worker will
      # not hand you the token" simply reached for this name instead.
      #
      # An MCP tool RESULT is not a private channel the way the HTTP response of
      # Api::V1::System::CiWorkersController#create is.
      # Ai::AgentToolBridgeService writes a 200-char truncation of the result
      # into `tool_calls_log`, which Api::V1::Ai::ConversationsController
      # persists into ai_messages.processing_metadata — a durable jsonb column
      # never re-filtered on read (Ai::SensitiveParams cannot reach it: the
      # value is a String and `.filter` returns non-Hash input unchanged) — and
      # it forwards the FULL json as a role:"tool" message to the model
      # provider on the next turn. So a mint that is correctly "shown once,
      # never stored" over HTTP became here a durable at-rest copy AND an
      # outbound transmission to a third party.
      #
      # SUBSTITUTE CHOSEN: a retrieval path, not a refusal. Nothing is
      # stranded — Api::V1::System::CiWorkersController#rotate_token
      # (routes.rb: `resources :ci_workers ... member { post :rotate_token }`)
      # mints a fresh, immediately usable token and returns it in ONE HTTP 200.
      # It is NOT `gate!`-wrapped, so unlike disk_image_webhooks#rotate_secret
      # it cannot answer `pending` under the default intervention policy; it
      # gates only on the `system.ci_workers.rotate_token` permission, which
      # this action's own `system.ci_workers.create` does not imply.
      #
      # The REST twin is deliberately unchanged and remains the disclosure
      # surface: an HTTP response acquires neither sink.
      def provision_ci_worker(params)
        worker = ::Worker.create_worker!(
          name: params[:name],
          account: @account,
          roles: [ "ci_worker" ]
        )

        # worker.token holds the plaintext (a virtual attribute set by
        # create_worker!). It is deliberately NOT bound into the return.
        success_result(
          ci_worker: ::System::CiWorkerSerializer.new(worker).as_json,
          token_delivery: "not disclosed here — a tool result is persisted with the conversation and forwarded to the " \
                          "model provider. Get the plaintext exactly once at " \
                          "POST /api/v1/system/ci_workers/#{worker.id}/rotate_token (ungated, answers in one response; " \
                          "needs system.ci_workers.rotate_token, which this action's permission does not imply).",
          note: "Fetch the token over the operator API and store it in your CI secrets as POWERNODE_CI_WORKER_TOKEN."
        )
      end

      def terminate_ci_worker(params)
        worker = ::Worker.where(account_id: @account.id).find(params[:worker_id])

        unless worker.has_role?("ci_worker")
          return error_result("worker #{worker.id} is not a ci_worker — refuses to revoke via this action")
        end

        # Worker doesn't have a `revoke!` method (the existing
        # ci_workers_controller#destroy calls `revoke!` but it's
        # undefined; that's a latent bug). Use the documented "revoked"
        # status directly. Token digest is preserved for audit trail
        # but is unusable since status != "active".
        worker.update!(status: "revoked")

        success_result(
          revoked: true,
          worker_id: worker.id
        )
      end

      def list_ci_workers(_params)
        # Worker.roles is a has_many :through (worker_roles → roles), not a
        # Postgres array column — must join + filter on Role.name.
        scope = ::Worker.where(account_id: @account.id)
                        .joins(:roles)
                        .where(roles: { name: "ci_worker" })
                        .distinct

        success_result(
          ci_workers: scope.map { |w| ::System::CiWorkerSerializer.new(w).as_json },
          count: scope.size
        )
      end

      # === Campaign 019f5885 inc3 — ephemeral CI runner leases ===

      def lease_ci_runner(params)
        lease = ::System::CiRunnerLeaseService.lease!(
          account: @account,
          pool_name: params[:pool_name],
          pool_id: params[:pool_id],
          purpose: params[:purpose].presence || "generic",
          workflow_run_id: params[:workflow_run_id],
          workflow_run_repo: params[:workflow_run_repo],
          correlate_timeout: params[:correlate_timeout]
        )
        success_result(ci_runner_lease: serialize_ci_runner_lease(lease))
      rescue ::System::CiRunnerLeaseService::LeaseError => e
        error_result(e.message)
      end

      def release_ci_runner(params)
        lease = ::System::CiRunnerLease.where(account_id: @account.id).find(params[:lease_id])
        ::System::CiRunnerLeaseService.release!(account: @account, lease: lease, force: params[:force] == true)
        success_result(ci_runner_lease: serialize_ci_runner_lease(lease.reload))
      rescue ::System::CiRunnerLeaseService::LeaseError => e
        error_result(e.message)
      end

      def list_ci_runner_leases(params)
        scope = ::System::CiRunnerLease.where(account_id: @account.id)
        scope = scope.by_status(params[:status]) if params[:status].present?
        scope = scope.active if params[:active] == true
        scope = scope.recent.limit((params[:limit].presence || 50).to_i)

        success_result(
          ci_runner_leases: scope.map { |lease| serialize_ci_runner_lease(lease) },
          count: scope.size
        )
      end

      def serialize_ci_runner_lease(lease)
        {
          id: lease.id,
          status: lease.status,
          purpose: lease.purpose,
          node_instance_id: lease.node_instance_id,
          instance_pool_id: lease.instance_pool_id,
          runner_name: lease.runner_name,
          git_runner_id: lease.git_runner_id,
          runner_labels: lease.runner_labels,
          workflow_run_id: lease.workflow_run_id,
          workflow_run_repo: lease.workflow_run_repo,
          build_task_id: lease.build_task_id,
          leased_at: lease.leased_at,
          registered_at: lease.registered_at,
          released_at: lease.released_at,
          expires_at: lease.expires_at,
          error_message: lease.error_message
        }
      end

      # === Campaign 019f5885 inc9 — native module-build batch orchestration ===

      def dispatch_module_build_batch(params)
        base_sha = params[:base_sha].to_s
        head_sha = params[:head_sha].to_s
        return error_result("base_sha and head_sha are required") if base_sha.blank? || head_sha.blank?

        source_repo = params[:source_repo].presence

        planned = ::System::ModuleBuildPlannerService.plan_with_diagnostics(
          base_sha: base_sha, head_sha: head_sha, force_all: params[:force_all] == true,
          source_repo: source_repo
        )

        batch = ::System::ModuleBuildBatch.create_for(
          account: @account, plan: planned.entries, trigger: params[:trigger].presence || "manual",
          base_sha: base_sha, head_sha: head_sha, source_repo: source_repo, excluded: planned.excluded
        )

        dispatch_summary = ::System::NativeModuleBuildOrchestrator.dispatch!(batch: batch)

        payload = {
          module_build_batch: serialize_module_build_batch(batch.reload),
          dispatched: dispatch_summary.dispatched,
          queued: dispatch_summary.queued
        }

        # imp b9e3e05a5119: modules the planner named but did not build (most
        # often package-origin ones, which build via the package-closure
        # trigger instead) — omitted entirely when nothing was dropped, so a
        # clean plan's payload is unchanged. Sampled: a force_all sweep on a
        # fleet carrying package closures can drop hundreds of names, and
        # excluded_count carries the true total.
        if planned.excluded.any?
          payload[:excluded_modules] = planned.excluded.first(EXCLUDED_MODULE_SAMPLE_LIMIT)
          payload[:excluded_count]   = planned.excluded.size
        end

        success_result(payload)
      rescue ::System::ModuleBuildPlannerService::PlanningError => e
        error_result(e.message)
      end

      # The undo for auto-promotion, and the forward-repoint when a good build
      # was withheld. Publishing auto-promotes by default, but ModulePublication
      # Processor withholds it on three conditions (auto_promote disabled, the
      # non-empty artifact floor, core-provenance refusal) — each of which emits
      # system.module_promotion_withheld. Nothing here is limited to moving
      # BACKWARDS: THIS verb reaches promote_to_version! either way, so it arms
      # a restart in both directions. That is a property of this verb, not of
      # the column — the REST rollback route (node_modules#rollback) moves
      # current_version_id through ModuleVersionService and arms nothing. See
      # spec/lint/node_module_current_version_write_seam_spec.rb.
      def rollback_module_version(params)
        module_id = params[:module_id].to_s
        return error_result("module_id is required") if module_id.blank?

        node_module = ::System::NodeModule.where(account: @account).find_by(id: module_id)
        return error_result("Module '#{module_id}' not found") unless node_module

        target =
          if params[:version_id].present?
            explicit_rollback_target(node_module, params[:version_id].to_s)
          else
            node_module.latest_rollback_target
          end

        return target if target.is_a?(Hash) # an error_result from the explicit lookup

        unless target
          return error_result(
            "No usable rollback target for '#{node_module.name}': no other version has a mountable artifact. " \
            "Republish a good build instead."
          )
        end

        previous_version_id = node_module.current_version_id
        node_module.promote_to_version!(target)

        Rails.logger.warn(
          "[SystemFleetTool] rolled back #{node_module.name} from version #{previous_version_id} " \
          "to #{target.id} (v#{target.version_number})#{params[:reason].present? ? " — #{params[:reason]}" : ""}"
        )

        success_result(
          module_id: node_module.id,
          module_name: node_module.name,
          rolled_back_from_version_id: previous_version_id,
          current_version_id: node_module.reload.current_version_id,
          current_version_number: node_module.current_version_number
        )
      end

      # Returns the version, or an error_result Hash the caller passes straight
      # through. Both refusals matter: a foreign version would repoint this
      # module at another module's artifact, and an unusable one recreates the
      # very failure rollback exists to undo.
      def explicit_rollback_target(node_module, version_id)
        version = ::System::NodeModuleVersion.find_by(id: version_id)
        return error_result("Version '#{version_id}' not found") unless version

        unless version.node_module_id == node_module.id
          return error_result("Version '#{version_id}' belongs to a different module")
        end

        unless version.rollback_usable?
          return error_result(
            "Version '#{version_id}' (v#{version.version_number}) has no mountable artifact " \
            "(missing oci_digest, or below the non-empty floor) — rolling back to it would leave the fleet unable to mount the module."
          )
        end

        version
      end

      # The kill switch the 2026-08-07 incident had no equivalent of: aborting
      # the in-flight task freed a builder and the orchestrator leased another
      # ~2min later, so the batch ran on for ~15 more minutes. Deleting the
      # git ref the builders check out did not stop it either.
      def cancel_module_build_batch(params)
        batch_id = params[:batch_id].to_s
        return error_result("batch_id is required") if batch_id.blank?

        batch = ::System::ModuleBuildBatch.where(account: @account).find_by(id: batch_id)
        return error_result("Module build batch '#{batch_id}' not found") unless batch

        result = ::System::NativeModuleBuildOrchestrator.cancel!(batch: batch, reason: params[:reason].presence)

        unless result.ok?
          return error_result("Batch is already #{batch.status} and cannot be cancelled")
        end

        success_result(module_build_batch: serialize_module_build_batch(batch.reload))
      end

      def serialize_module_build_batch(batch)
        {
          id: batch.id,
          status: batch.status,
          trigger: batch.trigger,
          base_sha: batch.base_sha,
          head_sha: batch.head_sha,
          module_slugs: batch.module_slugs,
          planned_count: batch.planned_count,
          succeeded_count: batch.succeeded_count,
          failed_count: batch.failed_count,
          error_message: batch.error_message,
          cancelled_at: batch.cancelled_at&.iso8601
        }
      end

      def list_disk_image_webhooks(_params)
        scope = ::System::DiskImageWebhook.where(account_id: @account.id).order(created_at: :desc)

        success_result(
          webhooks: scope.map { |w| serialize_disk_image_webhook(w) },
          count: scope.size
        )
      end

      def serialize_disk_image_publication(pub)
        {
          id: pub.id,
          node_platform_id: pub.node_platform_id,
          status: pub.status,
          arch: pub.arch,
          git_sha: pub.git_sha,
          oci_ref: pub.oci_ref,
          sha256: pub.sha256,
          size_bytes: pub.size_bytes,
          published_at: pub.created_at&.iso8601,
          retired_at: pub.retired_at&.iso8601
        }
      end

      # SECRET DISCLOSURE (IMP-27cc7dceb97b). `secret_preview` — the first 8
      # characters of the live HMAC webhook secret — was dropped from this
      # serializer. A plain removal, deliberately not a retrieval path or a
      # refusal: this is a READ action, nothing is minted here, so there is
      # nothing to deliver and nobody to strand.
      #
      # The column and the operator UI are untouched: the REST twin
      # (Api::V1::System::DiskImageWebhooksController#index →
      # CiWebhooksTab.tsx) is the surface that field was designed for —
      # "this is the secret you saved earlier" only means something to a human
      # looking at a screen. On the MCP arm nothing read it; `id` and `label`
      # already disambiguate rows. So all it bought here was a partial
      # disclosure into the same two durable sinks as a whole secret — the same
      # reasoning badbaef6c used to delete the 12-char previews from
      # bootstrap_disk_image_ci.
      def serialize_disk_image_webhook(wh)
        {
          id: wh.id,
          label: wh.label,
          status: wh.status,
          received_count: wh.received_count,
          last_received_at: wh.last_received_at&.iso8601,
          created_at: wh.created_at&.iso8601
        }
      end

      # === Missing-features slice 6a — GitOps reconciler MCP surface ===

      def gitops_register_repository(params)
        repo = ::System::GitopsRepository.create!(
          account: @account,
          name: params[:name],
          repo_url: params[:repo_url],
          branch: params[:branch].presence || "main",
          vault_credential_path: params[:vault_credential_path],
          path_prefix: params[:path_prefix].presence || "",
          auto_apply: params[:auto_apply] == true,
          last_status: "pending"
        )

        success_result(repository: serialize_gitops_repository(repo))
      end

      def gitops_sync_repository(params)
        repo = ::System::GitopsRepository.where(account_id: @account.id).find(params[:id])

        # Create the run HERE and hand it to the reconciler, mirroring the
        # REST sync_now action. The reconciler would otherwise create its own
        # (`@sync_run || @repository.schedule_sync!`) and never surface the id,
        # which left system_gitops_get_sync_run unreachable through the MCP
        # surface alone — no verb returned a run id and no verb lists runs
        # (IMP-d4923c10977e). The run is already terminal when this returns:
        # reconcile! is synchronous, so sync_run_id is a handle for fetching
        # the finalized record, not for polling a pending one.
        run = repo.schedule_sync!
        result = ::System::Gitops::Reconciler.reconcile!(repository: repo, sync_run: run)

        success_result(
          repository_id: repo.id,
          sync_run_id: run.id,
          ok: result.ok?,
          diff_count: result.diff_count,
          proposal_ids: result.proposal_ids,
          synced_revision: result.synced_revision,
          diff_summary: result.diff_summary,
          error: result.error
        )
      end

      def gitops_get_sync_run(params)
        run = ::System::GitopsSyncRun.for_account(@account).find(params[:sync_run_id])

        success_result(
          sync_run: {
            id: run.id,
            gitops_repository_id: run.gitops_repository_id,
            status: run.status,
            started_at: run.started_at&.iso8601,
            completed_at: run.completed_at&.iso8601,
            duration_seconds: run.duration_seconds,
            diff_count: run.diff_count,
            proposal_ids: run.proposal_ids,
            synced_revision: run.synced_revision,
            diff_summary: run.diff_summary,
            error_message: run.error_message
          }
        )
      end

      def gitops_get_drift_report(params)
        repo = ::System::GitopsRepository.where(account_id: @account.id).find(params[:id])

        # Run the reconcile pipeline up through diff, but DO NOT open proposals.
        # This gives operators a preview of what sync_repository would do.
        repo_result = ::System::Gitops::RepoSyncService.sync!(repo)
        return error_result("repo_sync failed: #{repo_result.error}") unless repo_result.ok?

        parse_result = ::System::Gitops::DesiredStateParser.parse!(
          work_tree_path: repo_result.work_tree_path,
          path_prefix: repo.path_prefix
        )
        return error_result("parse failed: #{parse_result.error}") unless parse_result.ok?

        diff_result = ::System::Gitops::DiffEngine.diff!(
          account: @account, desired_state: parse_result.desired_state
        )
        return error_result("diff failed: #{diff_result.error}") unless diff_result.ok?

        success_result(
          repository_id: repo.id,
          synced_revision: repo_result.commit_sha,
          drift: diff_result.diffs.any?,
          diff_count: diff_result.diffs.size,
          diffs: diff_result.diffs.map { |d| d.respond_to?(:to_h) ? d.to_h : d }
        )
      end

      # IMP-f07be27ba0b0 — the read half of this surface. Until these two
      # verbs existed, serialize_gitops_repository had exactly one call site,
      # gitops_register_repository, so over MCP a repository's configuration
      # was visible only to the caller that had just created it and supplied
      # the values itself. That left the credential contract added by
      # IMP-0f914db2c7cf (vault_credential_path + required_credential_keys)
      # reachable through REST alone.
      #
      # Both go through serialize_gitops_repository rather than assembling a
      # projection here: the REST and MCP halves drifted precisely because
      # each resource had two shapes, and a second one written here would put
      # the next credential-contract field back out of reach on this side.
      #
      # NO PROBE. The REST surface pairs this read with
      # POST /api/v1/admin_settings/vault/test { path:, required_keys: },
      # which reports whether the path resolves and carries those key names.
      # That probe is deliberately NOT mirrored here — an agent principal
      # naming arbitrary Vault KV paths is a different exposure from an
      # operator doing it in the admin UI, and the decision is pinned in
      # server/spec/services/ai/tools/system_fleet_gitops_repository_read_spec.rb.
      def gitops_list_repositories(_params)
        repos = ::System::GitopsRepository.where(account_id: @account.id).order(:name)

        success_result(repositories: repos.map { |r| serialize_gitops_repository(r) })
      end

      def gitops_get_repository(params)
        repo = ::System::GitopsRepository.where(account_id: @account.id).find(params[:id])

        success_result(repository: serialize_gitops_repository(repo))
      end

      def serialize_gitops_repository(repo)
        {
          id: repo.id,
          name: repo.name,
          repo_url: repo.repo_url,
          branch: repo.branch,
          path_prefix: repo.path_prefix,
          # PATH and key NAMES only, never credential material. See
          # serialize_repo in gitops_repositories_controller.rb for why these
          # are safe and what they pair with (IMP-0f914db2c7cf).
          vault_credential_path: repo.vault_credential_path,
          required_credential_keys: repo.required_credential_keys,
          auto_apply: repo.auto_apply,
          enabled: repo.enabled,
          last_status: repo.last_status,
          last_synced_at: repo.last_synced_at&.iso8601,
          last_synced_revision: repo.last_synced_revision,
          last_diff_count: repo.last_diff_count,
          last_error: repo.last_error,
          created_at: repo.created_at&.iso8601
        }
      end

      # === Missing-features slice Vault DR-3 — pepper rotation ===

      def rotate_vault_transit_pepper(params)
        result = ::Security::CredentialRestorationService.rotate_transit_pepper!(
          reencrypt_existing: params.fetch(:reencrypt_existing, true) != false
        )

        if result.ok?
          success_result(
            rotated: true,
            latest_version: result.latest_version,
            rotated_count: result.rotated_count,
            skipped_count: result.skipped_count,
            failed_count: result.failed_count,
            errors: result.errors
          )
        else
          error_result(result.error || "rotation failed")
        end
      end

      # === Missing-features slice 6b — GitOps apply path ===

      def gitops_apply_proposal(params)
        proposal = ::Ai::AgentProposal.where(account_id: @account.id).find(params[:proposal_id])
        result = ::System::Gitops::ApplyService.apply!(proposal: proposal)

        if result.ok?
          success_result(
            applied: true,
            applied_action: result.applied_action,
            resource_id: result.resource_id,
            proposal_id: proposal.id,
            proposal_status: proposal.reload.status
          )
        else
          # IMP-4a3a45df69bc — a proposal that did NOT apply is a refusal, and a
          # refusal must not ride the success channel. This arm previously
          # returned success_result(applied: false, ...) so that "the operator
          # can read the conflict reason without it looking like an error"; but
          # the reason travels on the failure shape too (`error`), so nothing
          # was bought but the label, and the price was the only field an
          # autonomous caller can branch on. A stale conflict is precisely the
          # case where such a caller must STOP: reality drifted, the fleet does
          # not match the repository, and the operator has to re-sync for a
          # fresh proposal. `success: true` told it to carry on.
          #
          # The distinguishing fields keep their dig paths under `data` (the
          # same shape and depth as the success arm, per provision_instance's
          # failure arm), so anything already reading data.stale_conflict /
          # data.applied is unaffected. The reason itself MOVES: it was
          # data.error and is now top-level `error`, which is where
          # error_result puts it and where the MCP transport looks — the
          # tools/call payload now also carries isError (streamable_http_
          # controller.rb, `result[:success] == false`), so the refusal is
          # visible at protocol level and not only in the body.
          failed = { success: false, error: result.error || "apply failed" }
          failed[:data] = { applied: false, proposal_id: proposal.id }
          failed[:data][:stale_conflict] = true if result.stale_conflict
          failed
        end
      end

      # === Provider catalog ===

      def list_providers(_params)
        providers = ::System::Provider.where(account_id: @account.id).order(:name)
        success_result(
          providers: providers.map { |p| serialize_provider(p) },
          count: providers.size
        )
      end

      def get_provider(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:id])
        success_result(provider: serialize_provider(provider))
      end

      # Config is merge-updated: existing keys are preserved unless the
      # caller passes a key with an explicit nil value, in which case
      # that key is deleted from the stored config. This keeps callers
      # from having to re-send the entire config on every update.
      def update_provider(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:id])

        attrs = {}
        attrs[:name]    = params[:name]    if params.key?(:name)
        attrs[:enabled] = params[:enabled] unless params[:enabled].nil?

        if params[:config].is_a?(Hash)
          merged = (provider.config || {}).merge(params[:config].transform_keys(&:to_s))
          merged.delete_if { |_, v| v.nil? }
          attrs[:config] = merged
        end

        provider.update!(attrs)
        success_result(provider: serialize_provider(provider.reload))
      end

      # F8-03 — mirrors REST ProvidersController#create. Credentials are
      # deliberately NOT accepted: secret material must never transit tool
      # calls — attach credentials afterwards via the Vault-backed provider
      # credential flow.
      def create_provider(params)
        # APO-7: refuse a provider type whose adapter cannot run in this
        # build BEFORE writing the row. Creating it succeeded happily and the
        # first provisioning call then raised a bare NameError from inside
        # the adapter, which an MCP caller sees as -32603 rather than as a
        # refusal naming the gem it is missing.
        provider_type = params[:provider_type].to_s
        registry = ::System::Providers::Registry
        if registry.supported?(provider_type) && !registry.sdk_available?(provider_type)
          return error_result(registry.sdk_missing_message(provider_type))
        end

        provider = ::System::Provider.new(
          account_id: @account.id,
          name: params[:name],
          description: params[:description],
          provider_type: params[:provider_type],
          enabled: params[:enabled].nil? ? true : params[:enabled],
          config: params[:config].is_a?(Hash) ? params[:config].transform_keys(&:to_s) : {}
        )

        if provider.save
          success_result(provider: serialize_provider(provider))
        else
          error_result("Validation failed: #{provider.errors.full_messages.join(', ')}")
        end
      end

      # Destroy cascades to the provider's regions/connections/instance
      # types/volume types/networks (model-level dependent: :destroy) —
      # the definition warns agents to decommission instances first.
      def delete_provider(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:id])

        if provider.destroy
          success_result(deleted: true, id: provider.id)
        else
          error_result("Failed to delete provider: #{provider.errors.full_messages.join(', ')}")
        end
      end

      def serialize_provider(p)
        {
          id: p.id,
          account_id: p.account_id,
          name: p.name,
          provider_type: p.provider_type,
          enabled: p.enabled,
          config: p.config,
          created_at: p.created_at&.iso8601,
          updated_at: p.updated_at&.iso8601
        }
      end

      # === F4-07 — provider chain creates =================================
      # The provisionable chain is provider + connected connection + region +
      # instance type. F8-03 added the provider half; these complete it so an
      # agent can self-serve onboard a substrate end-to-end. Crypto-safety:
      # create_provider_connection accepts NO key material — the adapter layer
      # (BaseProvider) resolves credentials from the Vault-encrypted BYOC
      # System::ProviderCredential store at use time.

      def create_provider_connection(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:provider_id])

        # APO-7: the MCP twin of the guarded REST create. A refusal that lives
        # only in ProviderConnectionsController is bypassable by exactly the
        # caller class the guard exists for — an agent holding
        # system.connections.create reaches this action directly. Refuse
        # BEFORE the write: test_connection! below only reports the later
        # failure, by which point the dead row has already landed.
        provider_type = provider.provider_type.to_s
        registry = ::System::Providers::Registry
        if registry.supported?(provider_type) && !registry.sdk_available?(provider_type)
          return error_result(registry.sdk_missing_message(provider_type))
        end

        connection = ::System::ProviderConnection.new(
          account_id: @account.id,
          provider_id: provider.id,
          name: params[:name],
          description: params[:description],
          endpoint_url: params[:endpoint_url],
          enabled: params[:enabled].nil? ? true : params[:enabled],
          config: params[:config].is_a?(Hash) ? params[:config].transform_keys(&:to_s) : {}
        )

        unless connection.save
          return error_result("Validation failed: #{connection.errors.full_messages.join(', ')}")
        end

        payload = { provider_connection: ::System::ProviderConnectionSerializer.new(connection).as_json }
        # Optional immediate credential test (same call as REST POST .../test):
        # resolves keys via the BYOC fallback and flips status to 'connected'
        # on success — the state Registry requires before provisioning.
        payload[:test_result] = connection.test_connection! if params[:test_connection]
        payload[:provider_connection] = ::System::ProviderConnectionSerializer.new(connection.reload).as_json

        success_result(payload)
      end

      def create_provider_region(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:provider_id])

        region = provider.provider_regions.new(
          account_id: @account.id,
          name: params[:name],
          description: params[:description],
          region_code: params[:region_code],
          endpoint_url: params[:endpoint_url],
          enabled: params[:enabled].nil? ? true : params[:enabled],
          kernel_image: params[:kernel_image],
          machine_image: params[:machine_image],
          ramdisk_image: params[:ramdisk_image],
          capabilities: params[:capabilities].is_a?(Hash) ? params[:capabilities].transform_keys(&:to_s) : {}
        )

        if region.save
          success_result(region: serialize_region(region))
        else
          error_result("Validation failed: #{region.errors.full_messages.join(', ')}")
        end
      end

      def create_provider_instance_type(params)
        provider = ::System::Provider.where(account_id: @account.id).find(params[:provider_id])

        instance_type = provider.provider_instance_types.new(
          account_id: @account.id,
          name: params[:name],
          description: params[:description],
          instance_type_code: params[:instance_type_code],
          vcpus: params[:vcpus],
          memory_mb: params[:memory_mb],
          storage_gb: params[:storage_gb],
          hourly_price: params[:hourly_price],
          enabled: params[:enabled].nil? ? true : params[:enabled],
          specs: params[:specs].is_a?(Hash) ? params[:specs].transform_keys(&:to_s) : {}
        )

        if instance_type.save
          success_result(instance_type: serialize_instance_type_record(instance_type))
        else
          error_result("Validation failed: #{instance_type.errors.full_messages.join(', ')}")
        end
      end

      def serialize_region(r)
        {
          id: r.id,
          provider_id: r.provider_id,
          account_id: r.account_id,
          name: r.name,
          region_code: r.region_code,
          enabled: r.enabled,
          capabilities: r.capabilities,
          created_at: r.created_at&.iso8601
        }
      end

      def serialize_instance_type_record(t)
        {
          id: t.id,
          provider_id: t.provider_id,
          account_id: t.account_id,
          name: t.name,
          instance_type_code: t.instance_type_code,
          vcpus: t.vcpus,
          memory_mb: t.memory_mb,
          storage_gb: t.storage_gb,
          hourly_price: t.hourly_price,
          enabled: t.enabled,
          specs: t.specs,
          created_at: t.created_at&.iso8601
        }
      end
    end
  end
end
