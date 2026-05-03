# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Plan + dispatch a rolling module upgrade across the fleet for a given
      # Template. v0 returns a structured *plan* (batch boundaries, gating,
      # estimated impact); the autonomy reconciler is responsible for stepping
      # through batches and pausing on circuit-breaker trip. Returning a plan
      # rather than executing in-band keeps the executor side-effect-free
      # for non-confirmed runs and makes the M7 ApprovalRequest payload a
      # one-step copy.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (rolling_module_upgrade).
      class RollingModuleUpgradeExecutor
        DEFAULT_BATCH_PCT             = 10
        DEFAULT_MAX_CONSECUTIVE_FAILS = 2
        DEFAULT_HEALTH_TIMEOUT_SEC    = 600
        # Two minutes per affected instance is the rough envelope from M2 boot
        # benchmarks (cloud-init + cert exchange + cosign verify + composefs
        # mount + heartbeat). Used only for ETA hints; not a hard SLO.
        ETA_PER_INSTANCE_SEC = 120

        def self.descriptor
          {
            name: "rolling_module_upgrade",
            description: "Plan a batched rolling upgrade of a NodeModule across all instances of a Template, with circuit-breaker and health gating",
            category: "devops",
            inputs: {
              template_id: { type: "string", required: true },
              module_id: { type: "string", required: true },
              target_version_id: { type: "string", required: true },
              batch_pct: { type: "integer", required: false, default: DEFAULT_BATCH_PCT,
                           description: "Percent of fleet to upgrade per batch (1-100). Smaller = safer + slower." },
              max_consecutive_failures: { type: "integer", required: false,
                                          default: DEFAULT_MAX_CONSECUTIVE_FAILS,
                                          description: "Trip the circuit-breaker after this many consecutive batch failures" },
              health_timeout_sec: { type: "integer", required: false,
                                    default: DEFAULT_HEALTH_TIMEOUT_SEC,
                                    description: "How long to wait for a batch to report healthy heartbeats before marking failed" }
            },
            outputs: {
              total_instances: :integer,
              batch_size: :integer,
              batch_count: :integer,
              estimated_total_seconds: :integer,
              circuit_breaker: :object,
              batches: [ :object ]
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(template_id:, module_id:, target_version_id:,
                    batch_pct: DEFAULT_BATCH_PCT,
                    max_consecutive_failures: DEFAULT_MAX_CONSECUTIVE_FAILS,
                    health_timeout_sec: DEFAULT_HEALTH_TIMEOUT_SEC)
          batch_pct = batch_pct.to_i
          return failure("batch_pct must be between 1 and 100") unless batch_pct.between?(1, 100)

          tool = ::Ai::Tools::SystemFleetTool.new(account: @account, agent: @agent, user: @user)

          mod_check = tool.execute(params: { action: "system_get_module", module_id: module_id })
          return failure("module lookup failed: #{mod_check[:error]}") unless mod_check[:success]

          version_check = tool.execute(params: { action: "system_list_module_versions", module_id: module_id })
          return failure("version listing failed: #{version_check[:error]}") unless version_check[:success]

          target_version = Array(version_check[:data][:versions])
                           .find { |v| v[:id] == target_version_id }
          return failure("target_version_id not found in module's version list") unless target_version

          instances_resp = tool.execute(params: {
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
              circuit_breaker: { trips_after_consecutive_failures: max_consecutive_failures, status: "armed" },
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
            circuit_breaker: {
              trips_after_consecutive_failures: max_consecutive_failures,
              health_timeout_sec: health_timeout_sec,
              status: "armed"
            },
            target: {
              module_id: module_id,
              target_version_id: target_version_id,
              target_version_number: target_version[:version_number],
              target_oci_digest: target_version[:oci_digest]
            },
            batches: batches,
            requires_approval: true,
            note: "plan returned; M7 reconciler advances batches one at a time, gating each via system.fleet_rolling_upgrade ApprovalRequest"
          )
        rescue StandardError => e
          Rails.logger.error("[RollingModuleUpgradeExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
