# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Spin up N instances of a Template in a region. Composition shape:
      #   system_get_template → loop(system_create_node) → parallel(system_provision_instance)
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (provision_cluster row).
      # The executor returns a structured *result set* (created nodes + provisioning
      # task ids); polling/wait_for_running is the autonomy reconciler's job.
      class ProvisionClusterExecutor < BaseSkillExecutor
        DEFAULT_NAME_PREFIX = "node"

        # Hard upper bound on a single skill invocation. Larger fleet rolls
        # come through rolling_module_upgrade with explicit operator confirmation.
        MAX_COUNT = 50

        skill_descriptor(
          name: "provision_cluster",
          description: "Provision N instances of a Template in a region — composes create_node + provision_instance for each",
          category: "devops",
          inputs: {
            template_id: { type: "string", required: true },
            count: { type: "integer", required: true,
                     description: "Number of nodes/instances to spin up (1-50)" },
            provider_region_id: { type: "string", required: true },
            provider_instance_type_id: { type: "string", required: true },
            name_prefix: { type: "string", required: false,
                           description: "Prefix for node names (default: \"node\")" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without creating resources" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            created_nodes: [ :object ],
            provisioned: [ :object ],
            # IMP-334f0cd3e1e8 — the NESTED ids region, which is the only shape
            # any plan-level reader addresses: VerificationService reads
            # `outputs.node_instance_ids` for BOTH the step_N_count oracle and
            # the live-reconciliation expectation list,
            # SkillCompositionRunner#rollback_kwargs merges this sub-hash up one
            # level to build the rollback hook's flat kwargs, and
            # PlanComposerService wires depends_on_outputs at that literal path.
            #
            # This executor used to return them FLAT (created_nodes /
            # provisioned only). `count` is a REQUIRED input, so
            # declared_instance_count was always positive and the count branch
            # always ran against an EMPTY id list: a fully successful N-node
            # cluster scored "provisioned 0/N" forever, and zero expectations
            # reached the reconciler, so its instances were never live-verified.
            # IMP-529b8514bbc6 fixed the same class of defect once already, on
            # the other side of the same oracle. There is ONE accepted shape,
            # and it is this one — the reader was deliberately not taught to
            # also read a flat envelope.
            #
            # created_nodes / provisioned stay: they are the human/audit view
            # (full serialized rows), the same way provision_full_stack keeps
            # `planned_actions` alongside its `outputs`.
            outputs: {
              node_ids: [ :string ],
              node_instance_ids: [ :string ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_provision_cluster,
          blast_radius: :medium
        )

        binds_to "Runtime Manager", "System Concierge"

        # Instance-method rollback contract — invoked by `SkillCompositionRunner`
        # via `executor.public_send(:rollback_provision_cluster, **outputs)`,
        # whose kwargs are flattened up out of the nested `outputs` sub-hash
        # above. Mirrors ProvisionFullStackExecutor#rollback_provision_full_stack.
        #
        # Before IMP-334f0cd3e1e8 this executor declared NO hook at all, so a
        # step carrying `on_failure: "rollback"` reached
        # SkillCompositionRunner#rollback_step!, found no descriptor entry,
        # and stamped `rolled_back` over half a cluster that was still live and
        # billing. The nesting above is what makes the hook actionable: a flat
        # envelope carries no `node_instance_ids` key at any depth, so the
        # kwargs would arrive empty even with the hook present.
        #
        # Only NodeInstances are reversed. Nodes are cheap DB shells and are
        # left in place for post-mortem — the same disposition
        # rollback_provision_full_stack takes. This executor provisions no
        # volumes and enrols no peers, so the volume-before-instance ordering
        # and the peer-detach pass of the full-stack hook have nothing to
        # mirror here; `**_extras` absorbs those ids (and `node_ids`) if a
        # composer ever forwards a wider envelope.
        #
        # Reverse order, and a per-id rescue: one instance the provider refuses
        # must not abort the teardown of its siblings, and the errors it
        # collects are returned rather than swallowed — the runner fails the
        # rollback loudly on a non-empty list instead of marking the step
        # rolled_back over survivors.
        def rollback_provision_cluster(node_instance_ids: [], **_extras)
          errors = []

          Array(node_instance_ids).reverse_each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            errors << { resource: "node_instance", id: instance_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(template_id:, count:, provider_region_id:, provider_instance_type_id:,
                    name_prefix: DEFAULT_NAME_PREFIX, dry_run: false)
          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          fleet_tool = tool(::Ai::Tools::SystemFleetTool)

          template_check = fleet_tool.execute(params: { action: "system_get_template", template_id: template_id })
          return failure("template lookup failed: #{template_check[:error]}") unless template_check[:success]

          if dry_run
            return success(
              dry_run: true,
              count: count,
              created_nodes: [],
              provisioned: [],
              outputs: { node_ids: [], node_instance_ids: [] },
              failures: [],
              plan: build_plan(template_check[:data], name_prefix, count, provider_region_id, provider_instance_type_id)
            )
          end

          created = []
          provisioned = []
          node_ids = []
          node_instance_ids = []
          failures = []

          # IMP-334f0cd3e1e8 — the loop is GUARDED, and the guard is what makes
          # the rollback hook above reachable at all.
          #
          # The legs below return error RESULTS, but they can also RAISE.
          # Ai::Tools::BaseTool#execute has no `rescue StandardError` around
          # `call(params)` (only an `ensure` for undeclared-action telemetry),
          # and SystemFleetTool#call rescues exactly FOUR classes
          # (:1758-1763 — RecordNotFound, RecordInvalid, ArgumentError,
          # NodeModuleVersion::InvalidTransition) into error results. Anything
          # else reaches here as a raise:
          #   - RecordNotUnique on a node-name collision, StatementInvalid or
          #     ConnectionNotEstablished on a DB blip, a provider adapter's
          #     Timeout::Error — none are in that four-class list;
          #   - PermissionDeniedError from #enforce_instance_deny_overlay!,
          #     which runs in BaseTool#execute BEFORE `call` and so is outside
          #     the tool's rescue entirely;
          #   - NoMethodError at `node[:id]` below, when a create result comes
          #     back carrying a nil node — raised in THIS method, never near a
          #     tool rescue.
          # (A node deleted mid-run is NOT one of them: `account_nodes.find`
          # raises RecordNotFound, which the tool converts to an error result
          # and the loop already records as a leg failure.)
          #
          # Unguarded, that raise unwound to BaseSkillExecutor#execute, which
          # returns a BARE `failure(e.message)` with no extras. The runner then
          # recorded no failure_outputs, rollback_outputs_for fell back to
          # `last_outputs` (empty — a step can never re-enter execute_step!,
          # CLAIMABLE_STATUSES is %w[pending] and nothing resets a step to
          # pending), the hook fired with `node_instance_ids: []`, and
          # mark_rolled_back stamped ROLLED_BACK over instances that were live
          # and billing. That is strictly worse than the no-op it looks like.
          #
          # `failure(msg, **extra)` (BaseSkillExecutor:187) is the seam that
          # exists for exactly this, and it is the ONLY dispatch that reaches
          # this executor's rollback: a first-run leg failure returns
          # success(partial: true) and never sees handle_failure. Mirrors
          # ProvisionFullStackExecutor, which guards every leg for this reason.
          #
          # ABORT rather than continue: a raise is an unexpected condition
          # (a revoked permission, a vanished node), not a per-node outcome the
          # loop knows how to skip, so standing up the remaining nodes would
          # widen an unexplained blast radius. The orphans already created are
          # handed to the rollback instead.
          begin
            count.times do |i|
              node_name = "#{name_prefix}-#{i + 1}-#{SecureRandom.hex(3)}"
              create_result = fleet_tool.execute(params: {
                action: "system_create_node", name: node_name, template_id: template_id
              })
              unless create_result[:success]
                failures << { step: "create_node", index: i, error: create_result[:error] }
                next
              end

              node = create_result[:data][:node]
              created << node
              node_ids << node[:id]

              prov_result = fleet_tool.execute(params: {
                action: "system_provision_instance",
                node_id: node[:id],
                provider_region_id: provider_region_id,
                provider_instance_type_id: provider_instance_type_id
              })
              if prov_result[:success]
                provisioned << prov_result[:data]
                # Guarded rather than pushed blind: a nil here would enter the
                # verifier's expectation list and reconcile a phantom. Dropping it
                # instead makes the count check short by one, which is the loud
                # failure — the executor claimed an instance it cannot name.
                instance_id = prov_result.dig(:data, :instance, :id)
                node_instance_ids << instance_id if instance_id
              else
                failures << { step: "provision_instance", node_id: node[:id], error: prov_result[:error] }
              end
            end
          rescue StandardError => e
            failures << { step: "unhandled", error: "#{e.class}: #{e.message}" }
            # Only the ids region goes in `outputs` — SkillCompositionRunner
            # #actionable_resources? descends it and treats any present value as
            # a resource, so bookkeeping (count, created_nodes) in there would
            # make an EMPTY rollback report as compensated.
            return failure(e.message,
                           outputs: { node_ids: node_ids, node_instance_ids: node_instance_ids },
                           failures: failures)
          end

          success(
            dry_run: false,
            count: count,
            created_nodes: created,
            provisioned: provisioned,
            outputs: { node_ids: node_ids, node_instance_ids: node_instance_ids },
            failures: failures,
            partial: failures.any? && created.any?
          )
        end

        private

        def build_plan(template_data, name_prefix, count, region_id, instance_type_id)
          {
            template_id: template_data[:template][:id],
            template_name: template_data[:template][:name],
            count: count,
            naming: "#{name_prefix}-1..#{count}",
            provider_region_id: region_id,
            provider_instance_type_id: instance_type_id,
            estimated_steps: count * 2 # create_node + provision_instance per
          }
        end
      end
    end
  end
end
