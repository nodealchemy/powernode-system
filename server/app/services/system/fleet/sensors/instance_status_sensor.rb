# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects instances marked `running` whose last_heartbeat_at is older
      # than 3 × the expected heartbeat interval (default heartbeat is 30s →
      # silent threshold is 90s).
      #
      # Emits `system.instance_silent` signals, which the DecisionEngine
      # binds to the drift_remediate skill (the most informative diagnostic
      # response) and ultimately to the system.instance_reprovision action
      # if drift remediation cannot recover the instance.
      class InstanceStatusSensor < BaseSensor
        # Control-plane fence: a silent instance owned by ANOTHER control plane
        # must not even emit a signal here — that signal drives the presumed-dead
        # reap. Inert for a single-plane deployment (no self-id configured).
        include ::System::Autonomy::ControlPlaneFence

        # Conservative — assumes 30s heartbeat * 3 + 30s grace.
        # Tuned to agree with CapacityRecommendExecutor::SILENT_HEARTBEAT_AGE.
        #
        # THE FALLBACK, not the effective value: an account may override it
        # through System::Fleet::SensorConfig (see .default_thresholds below).
        # Callers outside a sense pass — PromotionCriteria's DWELL_TIME,
        # CapacityRecommendExecutor — still read the constant, deliberately:
        # they are stating a platform-wide default, not sensing one account.
        SILENT_THRESHOLD = 3.minutes

        # The statuses in which a heartbeat is EXPECTED, and therefore the only
        # ones whose silence means anything. Deliberately narrower than
        # NodeInstance::LIVE_REPLICA_STATUSES: `stopped`/`stopping`/`rebooting`
        # /`pending`/`provisioning` replicas are live for CAPACITY purposes but
        # are not running an agent that should be reporting, so reading their
        # silence as a fault turns every routine reboot into an incident.
        #
        # Declared here, not inlined, because this sensor OWNS the definition of
        # a silent instance and IMP-ff9043758d8b gave it a second reader
        # (ProjectMetricsCollector#sample_availability_pct). Two copies of the
        # list would let the availability metric and the silence signals
        # disagree about which nodes were even supposed to answer.
        HEARTBEAT_EXPECTED_STATUSES = %w[running starting].freeze

        # IMP-ca485128072e (APO-2e) — the operator-tunable surface.
        # Seconds, not minutes: every threshold on every sensor is stored in
        # seconds so one MCP verb can describe them all without a per-key unit.
        def self.default_thresholds
          { "silent_threshold_seconds" => SILENT_THRESHOLD.to_i }
        end

        def sense
          silent_threshold = threshold("silent_threshold_seconds")
          cutoff = Time.current - silent_threshold.seconds

          # P2.5 gap #5 — stamp per-region health onto each cross-AZ pool so
          # InstancePoolService#pick_region_for_slot can skip degraded regions
          # during replenishment. Side effect of the same perception pass.
          stamp_region_health(cutoff)

          silent = ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: HEARTBEAT_EXPECTED_STATUSES)
            .where("last_heartbeat_at < ? OR last_heartbeat_at IS NULL", cutoff)

          fence_to_control_plane(silent)
            .find_each.map do |inst|
            signal(
              kind: "system.instance_silent",
              severity: severity_for(inst, cutoff),
              payload: {
                instance_id: inst.id,
                node_id: inst.node_id,
                last_heartbeat_at: inst.last_heartbeat_at&.iso8601,
                # The RESOLVED value, so an operator reading the signal sees
                # the threshold it was actually measured against.
                threshold_seconds: silent_threshold
              },
              fingerprint: "instance_silent:#{inst.id}"
            )
          end
        end

        private

        # Writes pool.metadata["region_health"] = { region_id => state } for
        # every cross-AZ pool (preferred_regions set) in the account. A region
        # is "healthy" when at least one of the pool's members there is live,
        # "unhealthy" when it has members but none are live, and "unknown" when
        # it currently has no members (so a fresh region can still be picked).
        # pick_region_for_slot only skips regions explicitly marked "unhealthy".
        def stamp_region_health(cutoff)
          pools = ::System::InstancePool
                    .where(account_id: account.id)
                    .where.not(preferred_regions: [])

          pools.find_each do |pool|
            regions = Array(pool.preferred_regions).compact_blank
            next if regions.empty?

            by_region = pool.node_instances
                            .where(provider_region_id: regions)
                            .select(:id, :provider_region_id, :status, :last_heartbeat_at)
                            .group_by(&:provider_region_id)

            health = regions.index_with do |region_id|
              members = by_region[region_id] || []
              if members.empty?
                "unknown"
              elsif members.any? { |m| live?(m, cutoff) }
                "healthy"
              else
                "unhealthy"
              end
            end

            existing = pool.metadata.is_a?(Hash) ? pool.metadata["region_health"] : nil
            next if existing == health # avoid write churn when unchanged

            pool.update!(metadata: (pool.metadata || {}).merge("region_health" => health))
          end
        rescue StandardError => e
          Rails.logger.warn("[InstanceStatusSensor] region_health stamp failed: #{e.message}")
        end

        def live?(instance, cutoff)
          HEARTBEAT_EXPECTED_STATUSES.include?(instance.status) &&
            instance.last_heartbeat_at.present? &&
            instance.last_heartbeat_at >= cutoff
        end

        # No heartbeat ever vs. recently silent. The first means the instance
        # never enrolled successfully (or is mid-bootstrap); the second means
        # an in-flight workload likely just lost connectivity. Severity tracks
        # the difference so DecisionEngine can route accordingly.
        def severity_for(instance, cutoff)
          return :high if instance.last_heartbeat_at.nil?
          return :critical if instance.last_heartbeat_at < cutoff - 30.minutes
          :medium
        end
      end
    end
  end
end
