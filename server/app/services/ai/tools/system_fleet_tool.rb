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

      # Per-action permission map. Aligned with the platform's seeded
      # `system.<resource>.<action>` naming (per
      # extensions/system/server/db/migrate/20260429120000_seed_system_extension_permissions_and_flags.rb).
      # Internal callers (system services, autonomy reconcilers) bypass
      # this check by passing user: nil to .new.
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
        "system_list_templates"         => "system.nodes.read",
        "system_get_template"           => "system.nodes.read",
        "system_list_modules"           => "system.modules.read",
        "system_get_module"             => "system.modules.read",
        "system_list_module_versions"   => "system.modules.read",
        "system_drift_report"           => "system.node_instances.read",
        "system_list_tasks"             => "system.infra_tasks.read",
        "system_get_task"               => "system.infra_tasks.read",

        # Mutate
        "system_create_node"            => "system.nodes.create",
        "system_update_node"            => "system.nodes.update",
        "system_delete_node"            => "system.nodes.delete",
        "system_create_template"        => "system.templates.create",
        "system_delete_template"        => "system.nodes.delete",
        "system_update_template"        => "system.nodes.update",
        "system_update_instance"        => "system.instances.update",
        "system_delete_module"          => "system.modules.delete",
        "system_refresh_instance_modules" => "system.node_instances.manage",
        "system_upgrade_boot_image"     => "system.node_instances.manage",
        "system_assign_module_to_template" => "system.modules.update",
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
        "system_compliance_snapshot"    => "system.fleet.autonomy",
        "system_runbook_generate"       => "system.modules.read",
        "system_cve_runbook_generate"   => "system.modules.read",
        "system_cve_triage"             => "system.modules.read",

        # Observability + attribution
        "system_recent_signals"         => "system.fleet.autonomy",
        "system_attribute_failure"      => "system.node_instances.read",
        "system_inspect_correlation"    => "system.fleet.autonomy",

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
        "system_unassign_module_from_template" => "system.modules.update",
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
        "system_list_disk_image_webhooks"            => "system.modules.read",

        # === Missing-features slice 6a — GitOps reconciler MCP surface ===
        "system_gitops_register_repository" => "system.modules.update",
        "system_gitops_sync_repository"     => "system.modules.update",
        "system_gitops_get_sync_run"        => "system.modules.read",
        "system_gitops_get_drift_report"    => "system.modules.read",

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
            description: "Create a new node bound to a template",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new node" },
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to bind the node to" }
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
          "system_create_template" => {
            description: "Create a new NodeTemplate for the current account. Binds to a NodePlatform via node_platform_id (required by the model). Lets the model validate (name presence + per-account uniqueness).",
            parameters: {
              name: { type: "string", required: true, description: "Display name for the new template (must be unique within the account)" },
              description: { type: "string", required: false, description: "Free-text description for the template" },
              enabled: { type: "boolean", required: false, description: "Whether the template is enabled (selectable for new nodes)" },
              public: { type: "boolean", required: false, description: "Whether the template is shared/public rather than account-private" },
              node_platform_id: { type: "string", required: false, description: "UUID of the NodePlatform the template binds to" },
              admin_user: { type: "string", required: false, description: "Default admin username provisioned on instances built from this template" },
              config: { type: "object", required: false, description: "Arbitrary template config hash" }
            }
          },
          "system_update_template" => {
            description: "Update mutable NodeTemplate fields: name, description.",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to update (account-scoped)" },
              name: { type: "string", required: false, description: "New display name for the template" },
              description: { type: "string", required: false, description: "New free-text description for the template" }
            }
          },
          "system_delete_module" => {
            description: "Delete a NodeModule. Cascades child_modules, versions, node_module_assignments, template_modules, module_puppet_assignments, module_dependencies.",
            parameters: { module_id: { type: "string", required: true, description: "UUID of the NodeModule to delete (account-scoped)" } }
          },
          "system_refresh_instance_modules" => {
            description: "Force re-apply all assigned modules to an instance — queues a reconcile task. Useful when instance has drifted from desired template state.",
            parameters: { instance_id: { type: "string", required: true, description: "UUID of the NodeInstance whose modules to re-apply" } }
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
              config: { type: "object", required: false, description: "Instance config hash (replaces the stored config)" },
              private_ip_address: { type: "string", required: false, description: "Private/internal IP address of the instance" },
              public_ip_address: { type: "string", required: false, description: "Public IP address of the instance" },
              vpn_ip_address: { type: "string", required: false, description: "SDWAN/VPN overlay IP address of the instance" }
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
            description: "A2A: mint an Ed25519-signed capability token proving caller_instance may invoke `skill` on target_instance via agent-to-agent MCP. GATED on the 4-gate A2A policy (PeerCapabilityService.authorize) — only issued if the call is authorized. The on-node A2A MCP server verifies the token's signature OFFLINE against the advertised public key (no per-call platform round-trip). Short-lived (default 5 min). Returns { envelope, signature, handle, public_key, expires_at, sub, aud, skill, jti }.",
            parameters: {
              caller_instance_id: { type: "string", required: true, description: "UUID of the instance the token authorizes to make the call (token subject)" },
              target_instance_id: { type: "string", required: true, description: "UUID of the instance the token authorizes the call against (token audience)" },
              skill: { type: "string", required: true, description: "Name of the peer skill the minted token authorizes" },
              ttl_seconds: { type: "integer", required: false, description: "Default 300; clamped to 1..3600 (MAX_TTL_SECONDS) — revocation propagates via the agents' capability_keys pull, so token lifetime is hard-capped" }
            }
          },
          "system_list_isolation_tiers" => {
            description: "L0: list the isolation tiers an agent deployment can request (native | gvisor | kata | firecracker | vm) with their Docker runtime / K8s RuntimeClass mapping, isolation strength, overhead, and host requirements. Pass isolation_tier inside a fleet_spec (system_launch_agent_fleet) to select one (default native).",
            parameters: {}
          },
          "system_provision_instance" => {
            description: "Provision a new cloud instance for a node (asynchronous; returns task_id). " \
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
            description: "Terminate an instance (cleanly destroys cloud resource + transitions to :terminated). Use system_destroy_instance to fully remove a registry row that has no live cloud resource.",
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

          # === Templates ===
          "system_list_templates" => {
            description: "List node templates for the current account",
            parameters: {}
          },
          "system_get_template" => {
            description: "Fetch a template with its assigned modules",
            parameters: { template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to fetch (account-scoped)" } }
          },
          "system_assign_module_to_template" => {
            description: "Bind a NodeModule to a NodeTemplate (creates a TemplateModule join)",
            parameters: {
              template_id: { type: "string", required: true, description: "UUID of the NodeTemplate to bind the module to" },
              module_id: { type: "string", required: true, description: "UUID of the NodeModule to assign to the template" }
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
          "system_promote_module_version" => {
            description: "Promote a NodeModuleVersion through its lifecycle (staging|blessed|live|retired)",
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
            description: "List recent tasks (filterable by node_id or instance_id)",
            parameters: {
              node_id: { type: "string", required: false, description: "Optional node UUID to list only tasks operating on that node" },
              instance_id: { type: "string", required: false, description: "Optional instance UUID to list only tasks operating on that instance" }
            }
          },
          "system_get_task" => {
            description: "Fetch a single System::Task by id (account-scoped). Returns the task's command, status, progress, operable handle, and timestamps. Not-found errors when the id is unknown or belongs to another account.",
            parameters: { id: { type: "string", required: true, description: "UUID of the System::Task to fetch (account-scoped)" } }
          },
          "system_cancel_task" => {
            description: "Cancel a pending task",
            parameters: { id: { type: "string", required: true, description: "UUID of the pending System::Task to cancel" } }
          },

          # === Module diff preview (Track F-11) ===
          "system_module_diff" => {
            description: "Compare two NodeModuleVersions and return added/removed files + package changes — preview before applying assignment changes",
            parameters: {
              version_a_id: { type: "string", required: true, description: "UUID of the first NodeModuleVersion (baseline) to compare" },
              version_b_id: { type: "string", required: true, description: "UUID of the second NodeModuleVersion (candidate) to compare" }
            }
          },

          # === Platform deployment (D3) ===
          # Two-branch tool: with no `mode`, returns a wizard payload
          # the chat UI renders as an inline form. With full args, calls
          # the orchestrator and provisions the new platform.
          "system_deploy_platform" => {
            description: "Deploy a new Powernode platform. Two execution shapes: (1) call with no `mode` to receive a wizard-card payload describing the form fields the operator should fill in — the chat UI renders this inline; (2) call with full args (mode, name, template_slug, [parent_url, spawn_mode for federated]) to actually provision. Standalone = sovereign platform; federated = peers back with this platform via P6 spawn flow. Federated mode returns a single-use acceptance_token that must be captured immediately.",
            parameters: {
              mode: { type: "string", required: false,
                      description: "standalone | federated. Omit to receive the wizard payload." },
              name: { type: "string", required: false,
                      description: "Display name for the new deployment (required when mode is set)." },
              template_slug: { type: "string", required: false,
                               description: "NodeTemplate to provision from (defaults to powernode-hub)." },
              parent_url: { type: "string", required: false,
                            description: "Required for federated mode — reachable URL of THIS platform." },
              spawn_mode: { type: "string", required: false,
                            description: "Required for federated mode — one of managed_child, autonomous_peer, cluster_member." },
              region: { type: "string", required: false, description: "Provider region to deploy the new platform into" },
              instance_size: { type: "string", required: false, description: "Instance size/SKU hint for the deployment's compute" },
              service_role: { type: "string", required: false, description: "Service role for the deployment (selects the workload profile)" },
              public_dns_hostname: { type: "string", required: false, description: "Public DNS hostname to assign to the new platform" },
              token_ttl_seconds: { type: "integer", required: false, description: "TTL (seconds) for the single-use federated acceptance_token" }
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
            description: "Remove a NodeModule from a NodeTemplate (destroys the TemplateModule join). Inverse of system_assign_module_to_template. Idempotent — returns success even when the join doesn't exist.",
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
            description: "Mark a NodeModule as a honeypot canary (config['honeypot']['canary'] = true). Canary modules are decoys — any access triggers a high-severity FleetEvent via honeypot_access_sensor. Idempotent — re-marking is a no-op.",
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
            description: "Provision a CI worker (a Worker with the 'ci_worker' role). Returns the worker plus a one-time-shown plaintext token. Token is NOT recoverable — operator must store immediately.",
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
          "system_list_disk_image_webhooks" => {
            description: "List DiskImageWebhook rows for the current account (the inbound webhook receivers that ingest publications from Gitea Actions).",
            parameters: {}
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
            description: "Trigger an immediate reconcile run for a registered repository. Creates a GitopsSyncRun row + opens proposals for any diffs found. Returns the sync_run_id for polling.",
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
            description: "Create a substrate provider record (e.g. onboard a new local_qemu/libvirt host). Credentials are NOT accepted here — attach them afterwards via the Vault-backed provider credential flow (provider connections + BYOC credential test); secret material must never transit tool calls.",
            parameters: {
              name: { type: "string", required: true, description: "Unique provider name within the account" },
              provider_type: { type: "string", required: true, description: "Provider type slug (e.g. local_qemu, proxmox, aws, pro_cloud)" },
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
            description: "Create a ProviderConnection for a provider (status starts 'pending'). NO credential parameters are accepted — the adapter layer resolves keys from the Vault-encrypted BYOC ProviderCredential store (saved via the provider Credentials UI/REST) at use time. Set test_connection=true to immediately run the live credential test: on success the connection flips to 'connected' (required before Registry will use it for provisioning).",
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

      def call(params)
        return error_result("permission denied: #{required_perm_for(params[:action])} required") unless action_permitted?(params[:action])

        case params[:action]
        when "system_list_nodes"               then list_nodes(params)
        when "system_get_node"                 then get_node(params)
        when "system_create_node"              then create_node(params)
        when "system_update_node"              then update_node(params)
        when "system_delete_node"              then delete_node(params)
        when "system_create_template"          then create_template(params)
        when "system_delete_template"          then delete_template(params)
        when "system_update_template"          then update_template(params)
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
        when "system_terminate_instance"       then terminate_instance(params)
        when "system_start_instance"           then control_instance(params, "start")
        when "system_stop_instance"            then control_instance(params, "stop")
        when "system_reboot_instance"          then control_instance(params, "reboot")
        when "system_destroy_instance"         then destroy_instance(params)
        when "system_list_templates"           then list_templates
        when "system_get_template"             then get_template(params)
        when "system_assign_module_to_template" then assign_module_to_template(params)
        when "system_list_modules"             then list_modules(params)
        when "system_get_module"               then get_module(params)
        when "system_list_module_versions"     then list_module_versions(params)
        when "system_promote_module_version"   then promote_module_version(params)
        when "system_drift_report"             then drift_report(params)
        when "system_list_tasks"               then list_tasks(params)
        when "system_get_task"                 then get_task(params)
        when "system_cancel_task"              then cancel_task(params)
        when "system_module_diff"              then module_diff(params)
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
        when "system_list_disk_image_webhooks"      then list_disk_image_webhooks(params)
        # Missing-features slice 6a — GitOps reconciler
        when "system_gitops_register_repository"    then gitops_register_repository(params)
        when "system_gitops_sync_repository"        then gitops_sync_repository(params)
        when "system_gitops_get_sync_run"           then gitops_get_sync_run(params)
        when "system_gitops_get_drift_report"       then gitops_get_drift_report(params)
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
      end

      private

      # === Permission gating ===
      # Internal callers (autonomy services, system runtime) call .new with
      # user: nil and bypass per-action checks. MCP-invoked callers always
      # carry @user from the dispatch layer.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if @user.nil? # internal/system bypass
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
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

      def create_node(params)
        template = account_templates.find(params[:template_id])
        node = ::System::Node.create!(
          account: @account,
          node_template: template,
          name: params[:name]
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
        attrs = {}
        attrs[:name]             = params[:name]             if params[:name].present?
        attrs[:description]      = params[:description]      if params[:description].present?
        attrs[:enabled]          = params[:enabled]          unless params[:enabled].nil?
        attrs[:public]           = params[:public]           unless params[:public].nil?
        attrs[:node_platform_id] = params[:node_platform_id] if params[:node_platform_id].present?
        attrs[:admin_user]       = params[:admin_user]       if params[:admin_user].present?
        attrs[:config]           = params[:config]           if params[:config].is_a?(Hash)

        template = account_templates.build(attrs)
        template.save!
        success_result(template: serialize_template(template))
      rescue ActiveRecord::RecordInvalid => e
        error_result("Template create failed: #{e.record.errors.full_messages.join(', ')}")
      end

      def update_template(params)
        template = account_templates.find(params[:template_id])
        attrs = {}
        attrs[:name] = params[:name] if params[:name].present?
        attrs[:description] = params[:description] if params[:description].present?
        template.update!(attrs)
        success_result(template: serialize_template(template))
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
        task = ::System::Task.create!(
          account: @account, operable: instance,
          command: "sync_modules", status: "pending",
          initiated_by: @user,
          options: { "source" => "mcp_refresh", "triggered_by_user_id" => @user&.id, "triggered_at" => Time.current.iso8601 }
        )
        success_result(refreshed: true, instance_id: instance.id, task_id: task.id, task_status: task.status)
      rescue ActiveRecord::RecordInvalid => e
        error_result("Failed to queue refresh task: #{e.message}")
      end

      # Campaign 019f505f increment 2 — queue an in-place boot-image (UKI)
      # upgrade to the platform's currently-promoted disk image. The agent
      # pulls + cosign-verifies the target UKI, writes the ESP, and reboots.
      # Guards, in order: (1) the instance must resolve to a platform; (2) that
      # platform must have a promoted image; (3) cosign trust MUST be configured
      # — we refuse to dispatch an unverifiable boot image (a malicious UKI is
      # full node compromise); (4) no-op when the node already booted the target
      # (unless force); (5) dedup against an in-flight upgrade so re-issuing is
      # idempotent.
      def upgrade_boot_image(params)
        instance = account_instances.find(params[:instance_id])
        platform = instance.node&.node_platform
        return error_result("Instance has no resolvable node platform") if platform.nil?

        target_sha = platform.disk_image_git_sha
        if target_sha.blank? || platform.disk_image_oci_ref.blank?
          return error_result("Platform has no promoted disk image to upgrade to")
        end
        if platform.disk_image_uki_oci_ref.blank?
          return error_result(
            "Promoted image has no standalone UKI artifact (built before the in-place-upgrade CI) — " \
            "republish/promote a newer image to enable boot-image upgrades"
          )
        end
        unless platform.cosign_trust_configured?
          return error_result(
            "Refusing boot-image upgrade: cosign trust (identity/issuer) is not configured for this platform — " \
            "the node could not verify the pulled UKI"
          )
        end

        force = params[:force].to_s == "true" || params[:force] == true
        if !force && instance.booted_image_git_sha.present? && instance.booted_image_git_sha == target_sha
          return success_result(upgraded: false, already_current: true, instance_id: instance.id, git_sha: target_sha)
        end

        existing = ::System::Task
                   .where(account: @account, operable: instance, command: "upgrade_boot_image")
                   .where(status: %w[pending scheduled running])
                   .order(created_at: :desc).first
        if existing
          return success_result(upgraded: false, deduplicated: true, instance_id: instance.id,
                                task_id: existing.id, task_status: existing.status)
        end

        task = ::System::Task.create!(
          account: @account, operable: instance,
          command: "upgrade_boot_image", status: "pending",
          initiated_by: @user,
          options: {
            "target_git_sha"         => target_sha,
            # The agent pulls + cosign-verifies the standalone UKI (the exact
            # bytes it writes to the ESP), not the full disk image.
            "uki_oci_ref"            => platform.disk_image_uki_oci_ref,
            "uki_sha256"             => platform.disk_image_uki_sha256,
            "cosign_identity_regexp" => platform.cosign_identity_regexp,
            "cosign_issuer_regexp"   => platform.cosign_issuer_regexp,
            "download_path"          => "/api/v1/system/node_api/boot_image/download",
            "source"                 => "mcp_upgrade_boot_image",
            "triggered_by_user_id"   => @user&.id,
            "triggered_at"           => Time.current.iso8601
          }
        )
        success_result(upgraded: true, instance_id: instance.id, task_id: task.id,
                       task_status: task.status, target_git_sha: target_sha)
      rescue ActiveRecord::RecordInvalid => e
        error_result("Failed to queue boot-image upgrade: #{e.message}")
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
        attrs[:config]             = params[:config]             if params[:config].is_a?(Hash)
        attrs[:private_ip_address] = params[:private_ip_address] if params[:private_ip_address].present?
        attrs[:public_ip_address]  = params[:public_ip_address]  if params[:public_ip_address].present?
        attrs[:vpn_ip_address]     = params[:vpn_ip_address]     if params[:vpn_ip_address].present?

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

        granted = peer.grant_mcp_tools!(patterns, mode: (params[:mode].to_s == "add" ? :add : :replace))
        success_result(instance_id: instance.id, granted_mcp_tools: granted)
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

        granted = peer.grant_peer_skills!(patterns, mode: (params[:mode].to_s == "add" ? :add : :replace))
        success_result(instance_id: instance.id, granted_peer_skills: granted)
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
      # Gated on PeerCapabilityService.authorize via the signer.
      def mint_peer_capability_token(params)
        caller_inst = account_instances.find_by(id: params[:caller_instance_id])
        target_inst = account_instances.find_by(id: params[:target_instance_id])
        return error_result("caller or target instance not found") unless caller_inst && target_inst

        # F2-04 — clamp to MAX_TTL here as well as in the signer: the MCP
        # surface must never accept an effectively-permanent token request.
        ttl = params[:ttl_seconds].present? ? params[:ttl_seconds].to_i : ::System::PeerCapabilityTokenSigner::DEFAULT_TTL_SECONDS
        ttl = ttl.clamp(1, ::System::PeerCapabilityTokenSigner::MAX_TTL_SECONDS)
        token = ::System::PeerCapabilityTokenSigner.mint!(
          caller_instance: caller_inst, target_instance: target_inst, skill: params[:skill].to_s, ttl_seconds: ttl
        )
        success_result(
          token: {
            envelope: token.envelope_json,
            signature: token.signature_b64,
            handle: token.handle,
            public_key: token.public_key_b64,
            expires_at: Time.at(token.claims["exp"]).utc.iso8601,
            sub: token.claims["sub"], aud: token.claims["aud"], skill: token.claims["skill"], jti: token.claims["jti"]
          }
        )
      rescue ::System::PeerCapabilityTokenSigner::NotAuthorizedError => e
        error_result("not authorized: #{e.message}")
      rescue ::System::PeerCapabilityTokenSigner::SigningError => e
        error_result("token minting failed: #{e.message}")
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
        return error_result(result.error || "provisioning failed") unless result.success?

        instance = result.data[:instance]
        success_result(
          provisioned: true,
          instance: serialize_instance(instance),
          cloud_instance_id: result.data[:cloud_instance_id]
        )
      end

      def terminate_instance(params)
        instance = account_instances.find(params[:instance_id])
        result = ::System::ProvisioningService.terminate_instance(instance: instance)
        return error_result(result.error || "termination failed") unless result.success?

        success_result(terminated: true, instance: serialize_instance(instance.reload))
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
        [ "system_instance_mount_points", "node_instance_id" ],
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

      def list_templates
        templates = account_templates.order(name: :asc)
        success_result(
          templates: templates.map { |t| serialize_template(t) },
          count: templates.size
        )
      end

      def get_template(params)
        template = account_templates.find(params[:template_id])
        success_result(template: serialize_template_full(template))
      end

      def assign_module_to_template(params)
        template = account_templates.find(params[:template_id])
        node_module = account_modules.find(params[:module_id])
        join = ::System::TemplateModule.create!(node_template: template, node_module: node_module)
        success_result(assigned: true, template_module_id: join.id)
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

      def promote_module_version(params)
        version = ::System::NodeModuleVersion
                  .joins(:node_module)
                  .where(system_node_modules: { account_id: @account.id })
                  .find(params[:module_version_id])
        version.promote_to!(params[:target_state])
        success_result(promoted: true, version: serialize_version(version.reload))
      end

      # === Drift ===

      def drift_report(params)
        instance = account_instances.find(params[:instance_id])
        running = instance.running_module_digests || {}
        assigned = instance.node.node_modules.includes(:current_version).each_with_object({}) do |m, acc|
          digest = m.current_version&.oci_digest
          acc[m.id] = digest if digest
        end

        missing = assigned.reject { |id, _| running.key?(id.to_s) || running.key?(id) }
        extra   = running.reject { |id, _| assigned.key?(id) || assigned.key?(id.to_s) }
        mismatched = assigned.each_with_object({}) do |(id, want), acc|
          have = running[id.to_s] || running[id]
          acc[id] = { want: want, have: have } if have && have != want
        end

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

      # Single-task fetch — mirrors list_tasks' account scoping + serializer.
      # Not-found bubbles to the shared ActiveRecord::RecordNotFound rescue
      # in #call, which renders the standard error_result.
      def get_task(params)
        task = ::System::Task.where(account: @account).find(params[:id])
        success_result(task: serialize_task(task))
      end

      # === Module diff ===

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
      def deploy_platform(params)
        executor = ::System::Ai::Skills::PlatformDeployExecutor.new(
          account: @account, agent: @agent, user: @user
        )
        # Pass through every relevant param; nil/blank get filtered by the executor
        execute_args = {
          mode: params[:mode].presence,
          name: params[:name].presence,
          template_slug: params[:template_slug].presence,
          parent_url: params[:parent_url].presence,
          spawn_mode: params[:spawn_mode].presence,
          region: params[:region].presence,
          instance_size: params[:instance_size].presence,
          service_role: params[:service_role].presence,
          public_dns_hostname: params[:public_dns_hostname].presence,
          token_ttl_seconds: params[:token_ttl_seconds].presence
        }.compact

        result = executor.execute(**execute_args)
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
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
          instance.update!(config: (instance.config || {}).merge("storage_volume" => binding))
        else
          return error_result("Volume already attached to another instance") if v.attached?
          device_name = next_block_device_for(instance)
          v.attach_to!(instance, device_name)
          binding = {
            volume_id: v.id, volume_name: v.name, size_gb: v.size_gb,
            transport: "block", mount_type: "device",
            device_name: device_name, role: role,
            mount_point: ::System::Platform::StorageRecommendations.mount_point_for(account: @account, role: role),
            attached_at: Time.current.iso8601
          }
          instance.update!(config: (instance.config || {}).merge("storage_volume" => binding))
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
          new_config = (instance.config || {}).except("storage_volume")
          instance.update!(config: new_config)
          success_result(detached: true, volume_id: v.id, instance_id: instance.id)
        else
          # Block volume — flip pool status back to available.
          return error_result("Volume not currently attached") unless v.attached?
          previous_instance_id = v.node_instance_id
          v.detach!
          # Best-effort: also clear the binding from the instance's config
          instance = ::System::NodeInstance.find_by(id: previous_instance_id)
          if instance
            instance.update!(config: (instance.config || {}).except("storage_volume"))
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

        executor = ::System::Ai::Skills::PlatformMaintenanceExecutor.new(
          account: @account, agent: @agent, user: @user
        )
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

        executor = ::System::Ai::Skills::PlatformResilienceExecutor.new(
          account: @account, agent: @agent, user: @user
        )
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
        executor = ::System::Ai::Skills::RunbookGenerateExecutor.new(
          account: @account, agent: @agent, user: @user
        )
        result = executor.execute(
          template_id: params[:template_id],
          persist_as_page: params[:persist_as_page] || false
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === CVE remediation runbook (Phase 10.7) ===

      def cve_runbook_generate(params)
        executor = ::System::Ai::Skills::CveRunbookGenerateExecutor.new(
          account: @account, agent: @agent, user: @user
        )
        result = executor.execute(
          cve_id: params[:cve_id],
          persist_as_page: params[:persist_as_page] || false
        )
        return error_result(result[:error]) unless result[:success]
        success_result(result[:data])
      end

      # === CVE triage ===

      def cve_triage(params)
        executor = ::System::Ai::Skills::CveResponseExecutor.new(
          account: @account, agent: @agent, user: @user
        )
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
        executor = ::System::Ai::Skills::AttributeFailureExecutor.new(
          account: @account, agent: @agent, user: @user
        )
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
          provider_instance_type_id: i.provider_instance_type_id
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

      def serialize_template_full(t)
        serialize_template(t).merge(
          modules: t.node_modules.map { |m| { id: m.id, name: m.name, variety: m.variety } },
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

      def serialize_module_full(m)
        serialize_module(m).merge(
          dependant: m.respond_to?(:dependant?) ? m.dependant? : false,
          parent_module_id: m.try(:parent_module_id),
          assignment_count: m.node_module_assignments.count,
          template_count: m.template_modules.count
        )
      end

      def serialize_version(v)
        {
          id: v.id,
          module_id: v.node_module_id,
          version_number: v.version_number,
          promotion_state: v.promotion_state,
          oci_digest: v.try(:oci_digest),
          fsverity_root_hash: v.try(:fsverity_root_hash),
          live_at: v.try(:live_at)&.iso8601,
          retired_at: v.try(:retired_at)&.iso8601
        }
      end

      def serialize_task(t)
        {
          id: t.id,
          command: t.command,
          status: t.status,
          progress: t.progress,
          operable_type: t.operable_type,
          operable_id: t.operable_id,
          created_at: t.created_at.iso8601,
          completed_at: t.completed_at&.iso8601
        }
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
        success_result(data: {
          pools: pools.map(&:to_summary),
          count: pools.count
        })
      end

      def get_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        success_result(data: {
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
        })
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
        success_result(data: { pool: pool.to_summary })
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
        success_result(data: { pool: pool.reload.to_summary })
      rescue ActiveRecord::RecordInvalid => e
        error_result("instance pool validation failed: #{e.message}")
      end

      def drain_instance_pool(params)
        pool = ::System::InstancePool.for_account(@account).find(params[:id])
        result = ::System::InstancePoolService.drain!(pool: pool)
        success_result(data: { pool: pool.reload.to_summary, drain_result: result })
      end

      def acquire_pooled_instance(params)
        instance = ::System::InstancePoolService.acquire!(
          account: @account,
          pool_name: params[:pool_name],
          pool_id: params[:pool_id],
          lifecycle_class: params[:lifecycle_class]
        )
        success_result(data: {
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
        })
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
        success_result(data: { pool: pool.reload.to_summary, replenish_result: result })
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
        instance.config ||= {}
        instance.config["drain_initiated_at"] = initiated_at
        instance.config["drain_timeout_seconds"] = timeout
        instance.save!

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
        join.destroy!

        success_result(
          unassigned: true,
          template_module_id: join_id,
          template_id: template.id,
          module_id: node_module.id
        )
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
        platform.update!(
          disk_image_oci_ref: publication.oci_ref,
          disk_image_git_sha: publication.git_sha,
          disk_image_publication_status: "published",
          disk_image_publication_error: nil
        )

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

      def provision_ci_worker(params)
        worker = ::Worker.create_worker!(
          name: params[:name],
          account: @account,
          roles: [ "ci_worker" ]
        )

        success_result(
          ci_worker: ::System::CiWorkerSerializer.new(worker).as_json,
          # SHOWN EXACTLY ONCE — operator must store immediately
          token_plaintext: worker.token,
          note: "Store this token in your CI secrets as POWERNODE_CI_WORKER_TOKEN. Not recoverable — rotate to get a new one."
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

      def serialize_disk_image_webhook(wh)
        {
          id: wh.id,
          label: wh.label,
          status: wh.status,
          secret_preview: wh.secret_preview,
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
        result = ::System::Gitops::Reconciler.reconcile!(repository: repo)

        success_result(
          repository_id: repo.id,
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

      def serialize_gitops_repository(repo)
        {
          id: repo.id,
          name: repo.name,
          repo_url: repo.repo_url,
          branch: repo.branch,
          path_prefix: repo.path_prefix,
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
          base = { applied: false, error: result.error, proposal_id: proposal.id }
          base[:stale_conflict] = true if result.stale_conflict
          # Surface as success_result with applied: false so the operator
          # can read the conflict reason without it looking like an error.
          # (Genuine system errors raise + are caught by the rescue chain.)
          success_result(**base)
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
