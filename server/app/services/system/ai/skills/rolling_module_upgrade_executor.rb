# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Size a module upgrade across the fleet for a given Template.
      # This executor returns a structured *plan* (the affected instance set,
      # estimated impact) and does nothing else.
      #
      # IMP-e8dc40813adb — NOTHING EXECUTES THE PLAN. There is no batch
      # advancer, no health check, and no circuit breaker anywhere in the
      # platform for module upgrades. The original header promised "dispatch"
      # and deferred the walk to a reconciler that milestone M7 was supposed
      # to deliver; that milestone shipped FleetAutonomyService and its
      # sensors, and no such reconciler. The promise survived only in this
      # file's own comments and in the note this executor returns. Both are
      # corrected here rather than left to imply a runtime a caller would wait
      # on. IMP-b948ea7fa382 removed the last two restatements of it
      # (ScaleProjectExecutor and DriftRemediateExecutor) and pinned their
      # absence in spec/docs/rolling_upgrade_docs_accuracy_spec.rb, which is
      # why this paragraph no longer quotes the phrase verbatim.
      #
      # MODULE UPGRADES ARE FLEET-ATOMIC (IMP-b948ea7fa382, operator decision
      # 2026-08-30). This is a property of the schema, not of the missing
      # actuator, so it holds however the lane is eventually built:
      #
      #   - The version an instance receives resolves from
      #     NodeModule#current_version_id — a per-MODULE pointer, read at
      #     download by NodeApi::ModulesController#download.
      #   - system_node_module_assignments, the only per-node row for a module,
      #     carries NO version column of any kind (server/db/schema.rb, table
      #     system_node_module_assignments: auto_resolved, config, node_id,
      #     node_module_id, priority, source_template_module_id, enabled,
      #     timestamps).
      #
      # So there is no per-instance version selection to batch OVER, and every
      # instance carrying the module converges together by construction. This
      # executor previously accepted a `batch_pct` and sliced the fleet into
      # groups; that parameter was removed rather than left accepted-and-
      # ignored, because a percentage that cannot bound blast radius reads to
      # a caller as pacing. Genuine staging requires separating the SCOPE —
      # instance pools, or a second NodeModule row with its own pointer — see
      # docs/tutorials/06-rolling-upgrade.md § "If you need a real
      # blast-radius bound".
      #
      # Still true of the two remaining optional inputs:
      #   - max_consecutive_failures and health_timeout_sec are echoed into the
      #     returned circuit_breaker hash and read by nothing. They are kept
      #     because a future actuator COULD implement a health gate; batch_pct
      #     was removed because no actuator could implement per-instance
      #     batching without a schema change.
      #
      # The implemented reference for this shape is
      # BootImageDriftRolloutExecutor: it dispatches its current batch through
      # UpgradeDispatcher and converges tick-by-tick by re-planning off its own
      # drift sensor, which is why it needs no advancer. The equivalent module
      # lane does not exist. Operator procedure meanwhile:
      # docs/tutorials/06-rolling-upgrade.md § "What to do instead".
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (rolling_module_upgrade).
      class RollingModuleUpgradeExecutor < BaseSkillExecutor
        DEFAULT_MAX_CONSECUTIVE_FAILS = 2
        DEFAULT_HEALTH_TIMEOUT_SEC    = 600
        # Two minutes per affected instance is the rough envelope from M2 boot
        # benchmarks (cloud-init + cert exchange + cosign verify + composefs
        # mount + heartbeat). Used only for ETA hints; not a hard SLO.
        #
        # READ THIS BEFORE TRUSTING estimated_total_seconds: it is the SUM over
        # the affected set, i.e. a SERIALIZED envelope. Instances do NOT
        # converge serially — the pointer moves once and each instance picks
        # the new version up at its own next reconcile, largely in parallel. So
        # the sum is a worst-case upper bound for "everything has settled", not
        # a rollout duration, and it must not be read as pacing. It is retained
        # only because it is the one figure that scales with how much of the
        # fleet a pointer flip touches.
        ETA_PER_INSTANCE_SEC = 120

        skill_descriptor(
          name: "rolling_module_upgrade",
          description: "Size a FLEET-ATOMIC module upgrade for a NodeModule across all instances of a Template. " \
                       "The upgrade cannot be staged or batched: the served version resolves from a per-MODULE " \
                       "pointer (NodeModule#current_version_id), so every instance carrying the module converges " \
                       "together. PLAN ONLY — the plan is NOT executed; nothing in the platform moves the pointer " \
                       "from this plan. See the class doc for the manual procedure and for real staging options.",
          category: "devops",
          inputs: {
            template_id: { type: "string", required: true },
            module_id: { type: "string", required: true },
            target_version_id: { type: "string", required: true },
            max_consecutive_failures: { type: "integer", required: false,
                                        default: DEFAULT_MAX_CONSECUTIVE_FAILS,
                                        description: "NOT IMPLEMENTED — echoed into the returned circuit_breaker hash and read by nothing" },
            health_timeout_sec: { type: "integer", required: false,
                                  default: DEFAULT_HEALTH_TIMEOUT_SEC,
                                  description: "NOT IMPLEMENTED — echoed into the returned circuit_breaker hash and read by nothing" }
          },
          outputs: {
            total_instances: :integer,
            affected_instance_ids: [ :string ],
            estimated_total_seconds: :integer,
            circuit_breaker: :object
          }
        )

        binds_to "Fleet Autonomy", "concierge", "CVE Responder"

        protected

        # `batch_pct` is deliberately NOT a keyword here. BaseSkillExecutor#execute
        # slices inputs to the keywords this signature declares, so a stale
        # caller still passing it is dropped at that seam rather than raising —
        # and, crucially, rather than being accepted and quietly ignored.
        def perform(template_id:, module_id:, target_version_id:,
                    max_consecutive_failures: DEFAULT_MAX_CONSECUTIVE_FAILS,
                    health_timeout_sec: DEFAULT_HEALTH_TIMEOUT_SEC)
          fleet_tool = tool(::Ai::Tools::SystemFleetTool)

          mod_check = fleet_tool.execute(params: { action: "system_get_module", module_id: module_id })
          return failure("module lookup failed: #{mod_check[:error]}") unless mod_check[:success]

          version_check = fleet_tool.execute(params: { action: "system_list_module_versions", module_id: module_id })
          return failure("version listing failed: #{version_check[:error]}") unless version_check[:success]

          target_version = Array(version_check[:data][:versions])
                           .find { |v| v[:id] == target_version_id }
          return failure("target_version_id not found in module's version list") unless target_version

          instances_resp = fleet_tool.execute(params: {
            action: "system_list_instances", template_id: template_id
          })
          return failure("instance listing failed: #{instances_resp[:error]}") unless instances_resp[:success]

          instances = Array(instances_resp[:data][:instances])
                      .select { |i| %w[running starting].include?(i[:status].to_s) }

          if instances.empty?
            return success(
              total_instances: 0,
              affected_instance_ids: [],
              estimated_total_seconds: 0,
              circuit_breaker: { trips_after_consecutive_failures: max_consecutive_failures, status: "not_implemented" },
              note: "no eligible instances for template — nothing to do"
            )
          end

          # ONE set, never groups. This is the fleet-atomic claim in the return
          # value: these are the instances that converge together the moment
          # current_version_id moves, which is the only blast radius there is.
          affected_instance_ids = instances.map { |i| i[:id] }

          success(
            total_instances: instances.size,
            affected_instance_ids: affected_instance_ids,
            estimated_total_seconds: instances.size * ETA_PER_INSTANCE_SEC,
            # status is "not_implemented", never "armed": there is no breaker to
            # arm. Both fields below are the caller's own arguments echoed back,
            # so a caller must not read this hash as evidence of a live gate.
            circuit_breaker: {
              trips_after_consecutive_failures: max_consecutive_failures,
              health_timeout_sec: health_timeout_sec,
              status: "not_implemented"
            },
            target: {
              module_id: module_id,
              target_version_id: target_version_id,
              target_version_number: target_version[:version_number],
              target_oci_digest: target_version[:oci_digest]
            },
            requires_approval: true,
            executed: false,
            note: "PLAN ONLY — nothing moves the fleet from this plan, and the upgrade is FLEET-ATOMIC when " \
                  "you do move it: current_version_id is a per-module pointer, so all #{instances.size} " \
                  "instances converge together and no subset can be staged. To actually move the fleet, see " \
                  "docs/tutorials/06-rolling-upgrade.md § \"What to do instead\"; for real staging, " \
                  "§ \"If you need a real blast-radius bound\"."
          )
        end
      end
    end
  end
end
