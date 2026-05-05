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
        "system_validate_module_manifest" => "system.modules.read"
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
    end
  end
end
