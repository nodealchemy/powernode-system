# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Drift-driven fleet boot-image rollout (campaign 019f505f increment 4).
      # BootImageDriftSensor emits system.boot_image_drift when a node's booted
      # image lags its platform's promoted image; DecisionEngine routes that to
      # this executor. It plans a CANARY-FIRST, HALT-ON-FAILURE rollout across all
      # drifted instances on the platform and (once approved) dispatches the
      # current batch through the shared UpgradeDispatcher.
      #
      # Convergence is tick-driven: each approved batch upgrades a slice; the next
      # sensor tick re-emits drift for the still-stale nodes and re-plans the
      # remainder — so the fleet converges batch-by-batch after a promote WITHOUT
      # a dedicated batch-advancer. HALT-ON-FAILURE: if a recent upgrade on the
      # platform failed (a canary that didn't come back on the new image), the
      # rollout stops planning new batches until an operator intervenes.
      class BootImageDriftRolloutExecutor < BaseSkillExecutor
        # INV-1 (no self-management). Every batch this planner emits becomes a
        # REBOOT, so a drifted instance on this control plane's own hosting node
        # would have the plane order its own restart mid-rollout — the
        # self-detach class System::Compliance::RcpInvariantScanner reports as
        # "blocked at the actuator".
        #
        # It was NOT blocked, because nothing downstream of here carries a
        # fence: UpgradeDispatcher.dispatch! has none, the System::Task it
        # writes has none, and ExecutionDispatcher has none — the whole path
        # from this planner to the on-node handler is unfenced. (The fences
        # that do exist — ProvisioningService, PlatformResilienceExecutor,
        # DecisionEngine's own reboot/converge lanes, ReplicaReconciler — sit on
        # OTHER paths this rollout never enters.) Plan time is therefore the
        # only seam where INV-1 can be enforced for a boot-image rollout.
        # Inert until an operator configures SiteSetting `self_hosting_node_id`.
        include ::System::Autonomy::SelfManagementFence

        DEFAULT_BATCH_PCT             = 10
        DEFAULT_MAX_CONSECUTIVE_FAILS = 1 # canary-first: halt on the first failed batch
        ETA_PER_INSTANCE_SEC          = 180 # a boot-image upgrade reboots the node
        # How far back a failed upgrade counts against the circuit breaker.
        FAILURE_WINDOW_SEC = (ENV["BOOT_IMAGE_ROLLOUT_FAILURE_WINDOW_SEC"] || 3600).to_i

        skill_descriptor(
          name: "boot_image_drift_rollout",
          description: "Plan a canary-first, halt-on-failure in-place boot-image upgrade across all drifted " \
                       "instances on a node platform, converging the fleet onto the promoted image.",
          category: "devops",
          inputs: {
            instance_id: { type: "string", required: true,
                           description: "A drifted NodeInstance — the rollout resolves its platform + all drifted siblings" },
            batch_pct: { type: "integer", required: false, default: DEFAULT_BATCH_PCT,
                         description: "Percent of drifted instances per batch (canary = first batch)" },
            max_consecutive_failures: { type: "integer", required: false, default: DEFAULT_MAX_CONSECUTIVE_FAILS,
                                        description: "Halt the rollout after this many recent failed upgrades on the platform" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no tasks created (the require_approval gate path)" }
          },
          # `total_drifted` counts the instances this rollout MAY reboot — the
          # drifted set after the INV-1 exclusion, so it always agrees with the
          # batch math. Instances withheld by the fence are counted separately
          # in `self_managed_excluded`; a drift report elsewhere still counts
          # them as drifted, because they are.
          outputs: {
            platform_id: :string, target_git_sha: :string, total_drifted: :integer,
            batch_size: :integer, batch_count: :integer, halted: :boolean, halt_reason: :string,
            circuit_breaker: :object, batches: [ :object ],
            dispatched_task_ids: [ :string ], dispatch_errors: [ :object ],
            self_managed_excluded: [ :string ]
          },
          requires_approval: true,
          # System::Fleet::DecisionEngine already gates this executor's tick-loop
          # door on system.node_boot_image_drift (SIGNAL_BINDINGS
          # "system.boot_image_drift"), and that category is registered and
          # seeded. Declaring it here makes the APO-1c gate on the DIRECT door
          # resolve the same operator row instead of deriving a second spelling
          # (system.boot_image_drift_rollout) for one capability
          # (IMP-7e2bdc1774e4, IMP-eb60db901f5f).
          action_category: "system.node_boot_image_drift",
          blast_radius: "reboots every drifted node on the platform, batch by batch"
        )
        binds_to "Fleet Autonomy"

        protected

        def perform(instance_id:, batch_pct: DEFAULT_BATCH_PCT,
                    max_consecutive_failures: DEFAULT_MAX_CONSECUTIVE_FAILS, dry_run: false)
          batch_pct = batch_pct.to_i
          return failure("batch_pct must be 1..100") unless batch_pct.between?(1, 100)

          seed = account_instances.find_by(id: instance_id)
          return failure("instance not found") unless seed
          platform = seed.node&.node_platform
          return failure("instance has no resolvable platform") if platform.nil?
          target = platform.disk_image_git_sha

          drifted, self_managed = partition_self_managed(drifted_instances(platform))
          fails    = recent_failures(platform)
          inflight = in_flight_count(platform)
          threshold = max_consecutive_failures.to_i
          # Plan-time preflight: an instance-independent guard failure (no promoted
          # UKI / no cosign key / no bundle) would make every dispatch a silent
          # no-op, so surface it in the plan instead of a green batch list.
          blocker = ::System::BootImage::UpgradeDispatcher.platform_blocker(platform)
          # HALT when: preflight blocked; a recent upgrade FAILED (a canary that
          # regressed); OR an upgrade is still IN FLIGHT — never advance to the
          # next batch until the current one proves healthy or resolves.
          halt_reason =
            if blocker.present?             then blocker
            elsif fails >= threshold        then "recent upgrade failure on platform (#{fails})"
            elsif inflight.positive?        then "upgrade in flight — waiting for the current batch (#{inflight})"
            elsif drifted.empty? && self_managed.any?
              # The steady state this fence creates: every sibling has
              # converged and the only thing still drifted is the node hosting
              # this plane, which INV-1 forbids us to reboot. Say so, rather
              # than return an inscrutable zero-batch plan — the drift sensor
              # keeps firing for that node, so an operator WILL see this and
              # needs to know it is waiting on an out-of-band upgrade from the
              # consensus group, not on a batch that never comes.
              "only this control plane's own hosting node is still drifted — " \
              "INV-1 forbids self-management; upgrade it from the consensus group"
            end
          halted = halt_reason.present?

          batch_size = [ (drifted.size * batch_pct / 100.0).ceil, 1 ].max
          batches = drifted.each_slice(batch_size).each_with_index.map do |group, idx|
            { index: idx, instance_ids: group.map(&:id), size: group.size,
              estimated_seconds: group.size * ETA_PER_INSTANCE_SEC,
              status: idx.zero? ? "canary" : "planned" }
          end

          dispatched = []
          errors = []
          # ACT (create tasks) only on the approved (non-dry_run) replay AND when
          # not halted. dry_run (the require_approval gate) is always plan-only.
          if !dry_run && !halted
            (batches.first&.dig(:instance_ids) || []).each do |id|
              inst = account_instances.find_by(id: id)
              next unless inst
              res = ::System::BootImage::UpgradeDispatcher.dispatch!(
                instance: inst, source: "fleet_boot_image_rollout"
              )
              if res.upgraded && res.task
                dispatched << res.task.id
              elsif res.reason
                errors << { instance_id: id, reason: res.reason }
              end
            end
          end

          success(
            platform_id: platform.id,
            target_git_sha: target,
            total_drifted: drifted.size,
            batch_size: batch_size,
            batch_count: batches.size,
            halted: halted,
            halt_reason: halt_reason,
            circuit_breaker: {
              trips_after_consecutive_failures: threshold,
              recent_failures: fails,
              in_flight: inflight,
              status: halted ? "tripped" : "armed"
            },
            batches: batches,
            dispatched_task_ids: dispatched,
            dispatch_errors: errors,
            self_managed_excluded: self_managed.map(&:id),
            requires_approval: true
          )
        end

        private

        def account_instances
          ::System::NodeInstance.where(account_id: account.id)
        end

        # Running instances on this platform whose booted image lags the promoted
        # one, in a STABLE order so the approved canary == the dispatched canary
        # (heartbeat writes churn physical row order). Eager-loaded → N+1-free.
        def drifted_instances(platform)
          account_instances
            .where(status: "running")
            .order(:id)
            .includes(node: { node_template: :node_platform })
            .select { |i| i.node&.node_platform&.id == platform.id && i.boot_image_drifted? }
        end

        # INV-1: split the drifted set into the instances this rollout may reboot
        # and the one(s) hosting this control plane. Excluded at PLAN time, not
        # at dispatch — a batch that lists the plane's own node has already told
        # the operator it will be rebooted. Reported in `self_managed_excluded`
        # rather than dropped silently, so an operator can see why the
        # self-hosted node never converges (it needs an out-of-band upgrade from
        # the consensus group, which is exactly INV-1's point).
        def partition_self_managed(instances)
          instances.partition { |instance| !self_managed_target?(instance) }
        end

        # All of this platform's instance ids (memoized — used by both the failure
        # and in-flight queries).
        def platform_instance_ids(platform)
          @platform_instance_ids ||= account_instances
                                     .includes(node: { node_template: :node_platform })
                                     .select { |i| i.node&.node_platform&.id == platform.id }
                                     .map(&:id)
        end

        # upgrade_boot_image tasks on this platform's instances that FAILED within
        # the window — the halt-on-failure signal (the reconciler/reaper fails a
        # canary that doesn't come back on the new image).
        def recent_failures(platform)
          ids = platform_instance_ids(platform)
          return 0 if ids.empty?

          ::System::Task
            .where(operable_type: "System::NodeInstance", operable_id: ids)
            .where(command: "upgrade_boot_image", status: "failed")
            .where("updated_at > ?", FAILURE_WINDOW_SEC.seconds.ago)
            .count
        end

        # upgrade_boot_image tasks still in flight on this platform — the rollout
        # waits for these before advancing (so a mid-reboot / bricked canary that
        # hasn't failed yet still halts the next batch).
        def in_flight_count(platform)
          ids = platform_instance_ids(platform)
          return 0 if ids.empty?

          ::System::Task
            .where(operable_type: "System::NodeInstance", operable_id: ids)
            .where(command: "upgrade_boot_image", status: %w[pending scheduled running])
            .count
        end
      end
    end
  end
end
