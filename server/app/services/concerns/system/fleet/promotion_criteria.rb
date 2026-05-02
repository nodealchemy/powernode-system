# frozen_string_literal: true

module System
  module Fleet
    # Promotion eligibility for NodeModuleVersion. Mirrors
    # Trading::Overseer::PromotionCriteria's shape: a pure function from
    # version + observed runtime evidence to {eligible:, ...details} hash.
    #
    # v0 thresholds:
    #   - REQUIRED_COUNT: minimum number of healthy instances must be
    #     running this exact oci_digest
    #   - DWELL_TIME: how long the instance has been running it (uses
    #     last_heartbeat_at as the dwell anchor — close enough until M-D2-2
    #     adds a per-version "first_seen_running_at" timestamp)
    #
    # The numbers are deliberately conservative for staging→blessed; once
    # operational data is available, tune via knobs in
    # config/initializers/system_extension.rb.
    module PromotionCriteria
      REQUIRED_COUNT = 3
      DWELL_TIME = 30.minutes

      module_function

      def evaluate(version:)
        digest = version.oci_digest
        return { eligible: false, reason: "no oci_digest on version" } if digest.blank?

        running_instances = matching_instances(version, digest)
        running_count = running_instances.size
        return { eligible: false, reason: "running_count #{running_count} < required #{REQUIRED_COUNT}",
                 running_count: running_count, required_count: REQUIRED_COUNT } if running_count < REQUIRED_COUNT

        # Dwell time: the *most recent* of the qualifying instances must have
        # observed the digest for at least DWELL_TIME. Using min(last_heartbeat_at)
        # of the candidate set as the dwell-anchor proxy.
        oldest_anchor = running_instances.filter_map(&:last_heartbeat_at).min
        return { eligible: false, reason: "no heartbeat data" } if oldest_anchor.nil?

        dwell = Time.current - oldest_anchor
        return { eligible: false, reason: "dwell_time #{dwell.to_i}s < required #{DWELL_TIME.to_i}s",
                 running_count: running_count, dwell_time_minutes: (dwell / 60.0).round(1) } if dwell < DWELL_TIME

        {
          eligible: true,
          running_count: running_count,
          required_count: REQUIRED_COUNT,
          dwell_time_minutes: (dwell / 60.0).round(1)
        }
      end

      def self.matching_instances(version, digest)
        # Find instances whose running_module_digests JSONB contains digest
        # at the matching module_id key. The digest comparison is exact —
        # promotion is a digest-bound concept, not a version-number-bound one.
        ::System::NodeInstance
          .joins(node: :node_modules)
          .where(system_node_modules: { id: version.node_module_id })
          .where(status: "running")
          .where("running_module_digests->>? = ?", version.node_module_id.to_s, digest)
          .distinct
      end
    end
  end
end
