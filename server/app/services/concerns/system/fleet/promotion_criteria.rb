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
    # The constants are deliberately conservative defaults for
    # staging→blessed. They are NOT the effective thresholds — those are
    # resolved per-evaluation so a small (1-2 instance) fleet can lower the
    # bar enough to promote at all. Resolution cascade (highest wins), the
    # platform's config-driven-config convention (mirrors
    # System::StorageMigration.cleanup_grace_hours):
    #   1) per-module   — node_module.config[<key>]
    #   2) per-account  — account.settings[<key>]
    #   3) global       — SiteSetting[<key>]
    #   4) default      — the REQUIRED_COUNT / DWELL_TIME constants below
    # Overriding nothing preserves today's behavior exactly.
    module PromotionCriteria
      REQUIRED_COUNT = 3
      DWELL_TIME = 30.minutes

      REQUIRED_COUNT_KEY = "module_promotion_required_count"
      DWELL_MINUTES_KEY  = "module_promotion_dwell_minutes"

      MIN_REQUIRED_COUNT = 1
      MAX_REQUIRED_COUNT = 100
      MIN_DWELL_MINUTES  = 0
      MAX_DWELL_MINUTES  = 60 * 24 * 30 # 30 days

      module_function

      def evaluate(version:)
        digest = version.oci_digest
        return { eligible: false, reason: "no oci_digest on version" } if digest.blank?

        required = required_count(version)
        dwell    = dwell_time(version)

        running_instances = matching_instances(version, digest)
        running_count = running_instances.size
        return { eligible: false, reason: "running_count #{running_count} < required #{required}",
                 running_count: running_count, required_count: required } if running_count < required

        # Dwell time: the *most recent* of the qualifying instances must have
        # observed the digest for at least the resolved dwell threshold. Using
        # min(last_heartbeat_at) of the candidate set as the dwell-anchor proxy.
        oldest_anchor = running_instances.filter_map(&:last_heartbeat_at).min
        return { eligible: false, reason: "no heartbeat data" } if oldest_anchor.nil?

        observed = Time.current - oldest_anchor
        return { eligible: false, reason: "dwell_time #{observed.to_i}s < required #{dwell.to_i}s",
                 running_count: running_count, required_count: required,
                 dwell_time_minutes: (observed / 60.0).round(1) } if observed < dwell

        {
          eligible: true,
          running_count: running_count,
          required_count: required,
          dwell_time_minutes: (observed / 60.0).round(1)
        }
      end

      # Effective minimum healthy-instance count for this version's module,
      # clamped to a sane range. A floor of 1 keeps promotion evidence-based
      # even when an operator misconfigures the override to 0.
      def self.required_count(version)
        raw = resolve_threshold(version, REQUIRED_COUNT_KEY)
        return REQUIRED_COUNT if raw.blank?

        raw.to_i.clamp(MIN_REQUIRED_COUNT, MAX_REQUIRED_COUNT)
      end

      # Effective dwell threshold (an ActiveSupport::Duration) for this
      # version's module. 0 minutes is a valid override (no dwell required).
      def self.dwell_time(version)
        raw = resolve_threshold(version, DWELL_MINUTES_KEY)
        return DWELL_TIME if raw.blank?

        raw.to_i.clamp(MIN_DWELL_MINUTES, MAX_DWELL_MINUTES).minutes
      end

      # Walks the module → account → site cascade, returning the first
      # configured value (or nil so the caller falls back to its default).
      def self.resolve_threshold(version, key)
        mod = version.node_module

        module_value = mod&.config&.dig(key)
        return module_value if module_value.present?

        account = mod&.account
        account_value = account.respond_to?(:settings) ? account.settings&.dig(key) : nil
        return account_value if account_value.present?

        begin
          ::SiteSetting.get(key)
        rescue StandardError
          nil
        end
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
