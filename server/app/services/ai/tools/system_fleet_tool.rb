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
        "system_list_templates"         => "system.nodes.read",
        "system_get_template"           => "system.nodes.read",
        "system_list_modules"           => "system.modules.read",
        "system_get_module"             => "system.modules.read",
        "system_list_module_versions"   => "system.modules.read",
        "system_drift_report"           => "system.node_instances.read",
        "system_list_tasks"             => "system.infra_tasks.read",

        # Mutate
        "system_create_node"            => "system.nodes.create",
        "system_assign_module_to_template" => "system.modules.update",
        "system_provision_instance"     => "system.instances.create",
        "system_terminate_instance"     => "system.instances.control",

        # Promotion (state-changing across the fleet — same level as module update)
        "system_promote_module_version" => "system.modules.update",

        # Task control
        "system_cancel_task"            => "system.infra_tasks.control",

        # Module diff (read — same level as get_module)
        "system_module_diff"            => "system.modules.read",

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
        "system_drain_instance_pool"    => "system.instances.control",
        "system_acquire_pooled_instance" => "system.instances.create",
        "system_replenish_instance_pool" => "system.instances.create",

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

        # === Gap remediation slice 3 — pool ops + canary marking ===
        "system_return_pooled_instance"        => "system.instances.control",
        "system_delete_instance_pool"          => "system.instances.create",
        "system_module_mark_canary"            => "system.fleet.autonomy",

        # === Gap remediation slice 5 — disk image CI ===
        # Read paths use the existing system.fleet.read pattern; mutate paths
        # use the existing CI worker permission scheme (ci_workers.create/delete).
        "system_list_disk_image_publications"        => "system.modules.read",
        "system_set_default_disk_image_publication"  => "system.modules.update",
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
        "system_gitops_apply_proposal" => "system.modules.update"
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
            parameters: { template_id: { type: "string", required: false } }
          },
          "system_get_node" => {
            description: "Fetch a node by id",
            parameters: { node_id: { type: "string", required: true } }
          },
          "system_create_node" => {
            description: "Create a new node bound to a template",
            parameters: {
              name: { type: "string", required: true },
              template_id: { type: "string", required: true }
            }
          },

          # === Instances ===
          "system_list_instances" => {
            description: "List instances (filterable by node_id or template_id)",
            parameters: {
              node_id: { type: "string", required: false },
              template_id: { type: "string", required: false }
            }
          },
          "system_get_instance" => {
            description: "Fetch a node instance with its current status + metrics",
            parameters: { instance_id: { type: "string", required: true } }
          },
          "system_provision_instance" => {
            description: "Provision a new cloud instance for a node (asynchronous; returns task_id)",
            parameters: {
              node_id: { type: "string", required: true },
              provider_region_id: { type: "string", required: true },
              provider_instance_type_id: { type: "string", required: true },
              options: { type: "object", required: false }
            }
          },
          "system_terminate_instance" => {
            description: "Terminate an instance (cleanly destroys cloud resource + transitions to :terminated)",
            parameters: { instance_id: { type: "string", required: true } }
          },

          # === Templates ===
          "system_list_templates" => {
            description: "List node templates for the current account",
            parameters: {}
          },
          "system_get_template" => {
            description: "Fetch a template with its assigned modules",
            parameters: { template_id: { type: "string", required: true } }
          },
          "system_assign_module_to_template" => {
            description: "Bind a NodeModule to a NodeTemplate (creates a TemplateModule join)",
            parameters: {
              template_id: { type: "string", required: true },
              module_id: { type: "string", required: true }
            }
          },

          # === Modules + Versions ===
          "system_list_modules" => {
            description: "List node modules (filterable by variety)",
            parameters: { options: { type: "object", required: false } }
          },
          "system_get_module" => {
            description: "Fetch a module with its current_version + assignments",
            parameters: { module_id: { type: "string", required: true } }
          },
          "system_list_module_versions" => {
            description: "List versions of a module (newest first)",
            parameters: { module_id: { type: "string", required: true } }
          },
          "system_promote_module_version" => {
            description: "Promote a NodeModuleVersion through its lifecycle (staging|blessed|live|retired)",
            parameters: {
              module_version_id: { type: "string", required: true },
              target_state: { type: "string", required: true }
            }
          },

          # === Reconcile / Drift ===
          "system_drift_report" => {
            description: "Compare a node instance's running modules vs assigned",
            parameters: { instance_id: { type: "string", required: true } }
          },

          # === Tasks ===
          "system_list_tasks" => {
            description: "List recent tasks (filterable by node_id or instance_id)",
            parameters: {
              node_id: { type: "string", required: false },
              instance_id: { type: "string", required: false }
            }
          },
          "system_cancel_task" => {
            description: "Cancel a pending task",
            parameters: { id: { type: "string", required: true } }
          },

          # === Module diff preview (Track F-11) ===
          "system_module_diff" => {
            description: "Compare two NodeModuleVersions and return added/removed files + package changes — preview before applying assignment changes",
            parameters: {
              version_a_id: { type: "string", required: true },
              version_b_id: { type: "string", required: true }
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
              template_id: { type: "string", required: true },
              persist_as_page: { type: "boolean", required: false }
            }
          },

          # === CVE remediation runbook (Phase 10.7) ===
          "system_cve_runbook_generate" => {
            description: "Generate a markdown remediation runbook for a CVE — exposed modules, recommended steps, verification commands. Reads System::CveExposure for the current account.",
            parameters: {
              cve_id: { type: "string", required: true },
              persist_as_page: { type: "boolean", required: false }
            }
          },

          # === CVE triage (M-D2-2 partial) ===
          "system_cve_triage" => {
            description: "Triage a CVE entry against the fleet — risk-scored exposure list and remediation plan. Reads from System::CveExposure when persisted.",
            parameters: {
              cve_id: { type: "string", required: true },
              severity: { type: "string", required: true },
              affected_packages: { type: "array", required: true },
              persist: { type: "boolean", required: false, description: "Persist a System::Cve row + exposures" }
            }
          },

          # === Observability — recent FleetEvents ===
          "system_recent_signals" => {
            description: "Recent fleet observability events for this account (signals, decisions, ticks). Live feed available via SystemFleetChannel.",
            parameters: {
              limit: { type: "integer", required: false },
              kind: { type: "string", required: false, description: "Filter by event kind (e.g. 'system.module_drift')" },
              correlation_id: { type: "string", required: false }
            }
          },

          # === Attribution — what likely caused an instance failure ===
          "system_attribute_failure" => {
            description: "Given a NodeInstance, rank recent module changes + promotions by likelihood of being the cause of a failure",
            parameters: {
              instance_id: { type: "string", required: true },
              lookback_hours: { type: "integer", required: false }
            }
          },

          # === Inspect one correlation chain (one tick or one decision) ===
          "system_inspect_correlation" => {
            description: "Walk every FleetEvent sharing a correlation_id — forensic deterministic replay of one tick or one decision flow",
            parameters: {
              correlation_id: { type: "string", required: true }
            }
          },

          # === Slice 7 — pre-warmed instance pools ===
          "system_list_instance_pools" => {
            description: "List instance pools for the current account with size + occupancy stats",
            parameters: {}
          },
          "system_get_instance_pool" => {
            description: "Fetch a single instance pool with full member roster + counts",
            parameters: { id: { type: "string", required: true } }
          },
          "system_create_instance_pool" => {
            description: "Create a new pre-warmed instance pool. Reaper will provision target_size warming members on next tick.",
            parameters: {
              name: { type: "string", required: true },
              template_id: { type: "string", required: true },
              target_size: { type: "integer", required: true, description: "Target number of warm+ready members" },
              min_size: { type: "integer", required: false, description: "Lower bound (default 0)" },
              max_size: { type: "integer", required: false, description: "Upper bound (default target+10)" },
              lifecycle_class: { type: "string", required: false, description: "ephemeral|spot (default ephemeral)" },
              provider_region_id: { type: "string", required: false },
              provider_instance_type_id: { type: "string", required: false }
            }
          },
          "system_drain_instance_pool" => {
            description: "Mark a pool draining: terminate ready members, halt replenishment. Claimed members keep running.",
            parameters: { id: { type: "string", required: true } }
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
            parameters: { id: { type: "string", required: true } }
          },

          # === Gap remediation slice 1 (Phase 4) ===
          "system_drain_instance" => {
            description: "Initiate graceful drain on a NodeInstance: records drain intent + emits FleetEvent so observability tooling (and future autonomy reconcilers) can act. Workloads remain running; operator should call system_terminate_instance after relocation completes. Idempotent — calling twice updates drain_initiated_at.",
            parameters: {
              instance_id: { type: "string", required: true },
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
            parameters: { cve_id: { type: "string", required: true } }
          },
          "system_create_cve" => {
            description: "Manually inject a Cve row (typically for embargoed CVEs not yet in NVD, or for drill-mode runbooks). Idempotent via cve_id uniqueness — re-running updates fields. NOTE: Cve table is GLOBAL (not account-scoped) — created CVEs are visible to all accounts. Requires elevated system.fleet.autonomy permission.",
            parameters: {
              cve_id:            { type: "string", required: true,  description: "Canonical CVE id, format CVE-YYYY-NNNN (4+ digits). Drills should use high-numeric ids like CVE-2026-99001." },
              severity:          { type: "string", required: true,  description: "critical|high|medium|low|unknown" },
              summary:           { type: "string", required: false },
              affected_packages: { type: "array",  required: false, description: "[{name: 'openssl', version: '<3.1.4'}, ...]" },
              published_at:      { type: "string", required: false, description: "ISO8601; defaults to now" },
              reference_url:     { type: "string", required: false },
              feed_source:       { type: "string", required: false, description: "nvd|ghsa|manual (default manual)" }
            }
          },
          "system_delete_cve" => {
            description: "Destroy a Cve row + cascade-delete its CveExposures. Used for drill cleanup. Cves are global; deletion affects all accounts. Requires elevated system.fleet.autonomy permission.",
            parameters: { cve_id: { type: "string", required: true } }
          },
          "system_unassign_module_from_template" => {
            description: "Remove a NodeModule from a NodeTemplate (destroys the TemplateModule join). Inverse of system_assign_module_to_template. Idempotent — returns success even when the join doesn't exist.",
            parameters: {
              template_id: { type: "string", required: true },
              module_id:   { type: "string", required: true }
            }
          },

          # === Gap remediation slice 3 — pool ops + canary marking ===
          "system_return_pooled_instance" => {
            description: "Return a claimed instance back to its pool (rare — only safe for stateless workloads). Pool reaper picks the instance back up as a 'ready' member; pool member_count increments by 1.",
            parameters: {
              instance_id: { type: "string", required: true }
            }
          },
          "system_delete_instance_pool" => {
            description: "Destroy an empty InstancePool row. Errors when pool still has members — drain first via system_drain_instance_pool, then delete.",
            parameters: { id: { type: "string", required: true } }
          },
          "system_module_mark_canary" => {
            description: "Mark a NodeModule as a honeypot canary (config['honeypot']['canary'] = true). Canary modules are decoys — any access triggers a high-severity FleetEvent via honeypot_access_sensor. Idempotent — re-marking is a no-op.",
            parameters: {
              module_id: { type: "string", required: true },
              lure_kind: { type: "string", required: false, description: "Display label for the canary (default 'credential_store')" }
            }
          },

          # === Gap remediation slice 5 — disk image CI ===
          "system_list_disk_image_publications" => {
            description: "List DiskImagePublications for the account, optionally filtered by node_platform_id and/or status. Returns oldest-first by default.",
            parameters: {
              node_platform_id: { type: "string", required: false },
              status: { type: "string", required: false, description: "queued|verifying|published|failed|retired" },
              limit: { type: "integer", required: false, description: "Default 50" }
            }
          },
          "system_set_default_disk_image_publication" => {
            description: "Promote a published DiskImagePublication as the platform's active disk image — copies its OCI ref + git SHA onto the parent NodePlatform so new instances boot from it. Errors if the publication is not in 'published' state.",
            parameters: {
              publication_id: { type: "string", required: true }
            }
          },
          "system_set_disk_image_retention" => {
            description: "Update the per-NodePlatform retention count (number of historical publications kept before the reaper purges).",
            parameters: {
              node_platform_id: { type: "string", required: true },
              retention_count: { type: "integer", required: true, description: "Number of historical publications to retain (must be ≥1)" }
            }
          },
          "system_provision_ci_worker" => {
            description: "Provision a CI worker (a Worker with the 'ci_worker' role). Returns the worker plus a one-time-shown plaintext token. Token is NOT recoverable — operator must store immediately.",
            parameters: {
              name: { type: "string", required: true }
            }
          },
          "system_terminate_ci_worker" => {
            description: "Revoke a CI worker — destroys credentials + marks the worker as revoked. Operator can then unregister the corresponding Gitea Actions runner.",
            parameters: {
              worker_id: { type: "string", required: true }
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
              sync_run_id: { type: "string", required: true }
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
        when "system_list_instances"           then list_instances(params)
        when "system_get_instance"             then get_instance(params)
        when "system_provision_instance"       then provision_instance(params)
        when "system_terminate_instance"       then terminate_instance(params)
        when "system_list_templates"           then list_templates
        when "system_get_template"             then get_template(params)
        when "system_assign_module_to_template" then assign_module_to_template(params)
        when "system_list_modules"             then list_modules(params)
        when "system_get_module"               then get_module(params)
        when "system_list_module_versions"     then list_module_versions(params)
        when "system_promote_module_version"   then promote_module_version(params)
        when "system_drift_report"             then drift_report(params)
        when "system_list_tasks"               then list_tasks(params)
        when "system_cancel_task"              then cancel_task(params)
        when "system_module_diff"              then module_diff(params)
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
        when "system_drain_instance_pool"      then drain_instance_pool(params)
        when "system_acquire_pooled_instance"  then acquire_pooled_instance(params)
        when "system_replenish_instance_pool"  then replenish_instance_pool(params)
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
        # Gap remediation slice 3 — pool ops + canary marking
        when "system_return_pooled_instance"        then return_pooled_instance(params)
        when "system_delete_instance_pool"          then delete_instance_pool(params)
        when "system_module_mark_canary"            then module_mark_canary(params)
        # Gap remediation slice 5 — disk image CI
        when "system_list_disk_image_publications"  then list_disk_image_publications(params)
        when "system_set_default_disk_image_publication" then set_default_disk_image_publication(params)
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

      def provision_instance(params)
        node = account_nodes.find(params[:node_id])
        result = ::System::ProvisioningService.provision_instance(
          node: node,
          provider_region_id: params[:provider_region_id],
          provider_instance_type_id: params[:provider_instance_type_id],
          options: params[:options] || {}
        )
        return error_result(result.error || "provisioning failed") unless result.ok?

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
        return error_result(result.error || "termination failed") unless result.ok?

        success_result(terminated: true, instance: serialize_instance(instance.reload))
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
          last_heartbeat_at: instance.last_heartbeat_at&.iso8601
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
        ::System::NodeInstance.joins(:node).where(system_nodes: { account_id: @account.id })
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
          agent_version: i.agent_version
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
          provider_instance_type_id: params[:provider_instance_type_id]
        )
        success_result(data: { pool: pool.to_summary })
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

      # Returns a claimed pool instance back to its origin pool. The instance's
      # pool_state flips from 'claimed' → 'ready'; the next acquire! call can
      # claim it again. Only safe for stateless workloads — most operators
      # prefer system_terminate_instance to release.
      def return_pooled_instance(params)
        instance = account_instances.find(params[:instance_id])

        unless instance.instance_pool_id
          return error_result("instance #{instance.id} has no instance_pool_id — was never a pool member")
        end

        unless instance.pool_state == "claimed"
          return error_result("instance #{instance.id} is in pool_state=#{instance.pool_state.inspect}, can only return 'claimed' instances")
        end

        pool = ::System::InstancePool.for_account(@account).find(instance.instance_pool_id)

        instance.update!(pool_state: "ready", pool_acquired_at: nil)

        success_result(
          returned: true,
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
          roles: ["ci_worker"]
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
    end
  end
end
