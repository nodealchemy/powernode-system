# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Plan a rolling module upgrade across the fleet for a given Template.
      # This executor returns a structured *plan* (batch boundaries, estimated
      # impact) and does nothing else.
      #
      # IMP-e8dc40813adb — NOTHING EXECUTES THE PLAN. There is no batch
      # advancer, no health check, and no circuit breaker anywhere in the
      # platform for module upgrades. The original header promised "dispatch"
      # and deferred the walk to an "M7 reconciler"; M7 was never built, and
      # the phrase survived only in this file's own comments and in the note
      # this executor returns. Both are corrected here rather than left to
      # imply a runtime a caller would wait on.
      #
      # Consequences a caller must know before trusting the plan:
      #   - batch_pct is NOT a blast-radius control. It sizes groups in a
      #     document. Even if something walked them, the version an instance
      #     receives resolves from NodeModule#current_version_id — a per-MODULE
      #     pointer — so moving it moves every instance carrying that module at
      #     once. There is no per-instance version selection to batch over.
      #   - max_consecutive_failures and health_timeout_sec are echoed into the
      #     returned circuit_breaker hash and read by nothing.
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
        DEFAULT_BATCH_PCT             = 10
        DEFAULT_MAX_CONSECUTIVE_FAILS = 2
        DEFAULT_HEALTH_TIMEOUT_SEC    = 600
        # Two minutes per affected instance is the rough envelope from M2 boot
        # benchmarks (cloud-init + cert exchange + cosign verify + composefs
        # mount + heartbeat). Used only for ETA hints; not a hard SLO.
        ETA_PER_INSTANCE_SEC = 120

        skill_descriptor(
          name: "rolling_module_upgrade",
          description: "Compute a batched rolling-upgrade plan for a NodeModule across all instances of a Template. " \
                       "PLAN ONLY — the plan is NOT executed: no batch advancer, health check or circuit breaker " \
                       "exists, so nothing advances the batches. See the class doc for the manual procedure.",
          category: "devops",
          inputs: {
            template_id: { type: "string", required: true },
            module_id: { type: "string", required: true },
            target_version_id: { type: "string", required: true },
            batch_pct: { type: "integer", required: false, default: DEFAULT_BATCH_PCT,
                         description: "Percent of fleet per batch (1-100). Sizes groups in the returned plan only — " \
                                      "it is NOT a blast-radius control, because nothing executes the batches." },
            max_consecutive_failures: { type: "integer", required: false,
                                        default: DEFAULT_MAX_CONSECUTIVE_FAILS,
                                        description: "NOT IMPLEMENTED — echoed into the returned circuit_breaker hash and read by nothing" },
            health_timeout_sec: { type: "integer", required: false,
                                  default: DEFAULT_HEALTH_TIMEOUT_SEC,
                                  description: "NOT IMPLEMENTED — echoed into the returned circuit_breaker hash and read by nothing" }
          },
          outputs: {
            total_instances: :integer,
            batch_size: :integer,
            batch_count: :integer,
            estimated_total_seconds: :integer,
            circuit_breaker: :object,
            batches: [ :object ]
          }
        )

        binds_to "Fleet Autonomy", "System Concierge", "CVE Responder"

        protected

        def perform(template_id:, module_id:, target_version_id:,
                    batch_pct: DEFAULT_BATCH_PCT,
                    max_consecutive_failures: DEFAULT_MAX_CONSECUTIVE_FAILS,
                    health_timeout_sec: DEFAULT_HEALTH_TIMEOUT_SEC)
          batch_pct = batch_pct.to_i
          return failure("batch_pct must be between 1 and 100") unless batch_pct.between?(1, 100)

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
              batch_size: 0,
              batch_count: 0,
              estimated_total_seconds: 0,
              circuit_breaker: { trips_after_consecutive_failures: max_consecutive_failures, status: "not_implemented" },
              batches: [],
              note: "no eligible instances for template — nothing to do"
            )
          end

          batch_size = [ (instances.size * batch_pct / 100.0).ceil, 1 ].max
          batches = instances.each_slice(batch_size).each_with_index.map do |group, idx|
            {
              index: idx,
              instance_ids: group.map { |i| i[:id] },
              size: group.size,
              estimated_seconds: group.size * ETA_PER_INSTANCE_SEC,
              status: "planned"
            }
          end

          success(
            total_instances: instances.size,
            batch_size: batch_size,
            batch_count: batches.size,
            estimated_total_seconds: batches.sum { |b| b[:estimated_seconds] },
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
            batches: batches,
            requires_approval: true,
            executed: false,
            note: "PLAN ONLY — nothing advances these batches. No batch advancer, health check or circuit " \
                  "breaker is implemented for module upgrades, so approving this plan does not roll anything " \
                  "out. To actually move the fleet, see docs/tutorials/06-rolling-upgrade.md " \
                  "§ \"What to do instead\"."
          )
        end
      end
    end
  end
end
