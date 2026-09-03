# frozen_string_literal: true

module System
  module Fleet
    # Promotion eligibility for NodeModuleVersion. A pure function from
    # version + observed runtime evidence to an {eligible:, ...details}
    # hash — the platform's standard promotion-criteria shape.
    #
    # v0 thresholds:
    #   - REQUIRED_COUNT: minimum number of healthy instances must be
    #     running this exact oci_digest
    #   - DWELL_TIME: how long the instance has been running it, read from
    #     NodeInstance#first_seen_running_at_for (the
    #     module_first_seen_running_at document stamped by the heartbeat
    #     ingest). Instances must ALSO be currently alive — a qualifying
    #     instance whose heartbeat is stale is a fault the platform is already
    #     acting on, never promotion evidence.
    #
    # IMP-249aa98969bd: the anchor used to be `min(last_heartbeat_at)`, which
    # measured SILENCE, not dwell. A healthy fleet heartbeating normally kept
    # that anchor near zero and could never clear a 30-minute dwell; the gate
    # cleared only once every qualifying instance had been silent for
    # DWELL_TIME — ten times InstanceStatusSensor::SILENT_THRESHOLD, the age at
    # which the platform already raises `system.instance_silent`. It was
    # anti-correlated with the health it exists to certify. (The prior comment
    # here deferred the real timestamp to "M-D2-2". No plan document for that
    # milestone exists in this tree, and the name is used for two different
    # things in it — SBOM-aware CVE matching (README.md) and a telemetry
    # pipeline (capacity_recommend_executor.rb, score_evaluator.rb) — with
    # nothing anywhere recording that it was to add this field. It was a
    # deferral to a component no one owned.)
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

      # The promotion targets these criteria have anything to say about.
      # `blessed` is the rung that claims "the fleet has run this and lived",
      # which is exactly what #evaluate measures; `staging`/`built` are
      # pre-evidence rungs and `retired`/`live` are operator decisions about a
      # version that already cleared (or is being decommissioned regardless).
      # System::Fleet::ModulePromotionService — the automated lane — refuses on
      # this same set; System::Fleet::ManualPromotionAdvisory (the operator REST
      # promote and its MCP twin) WARNS on it.
      #
      # This IS the single definition. IMP-d6826c872d88 introduced it as the
      # shared NAME for the two manual paths while module_promotion_service.rb
      # still carried its own `target_state == "blessed"` literal;
      # IMP-bdb650b82c65 collapsed the service onto PromotionCriteria.gates?,
      # and spec/services/system/fleet/module_promotion_service_spec.rb now
      # stubs this constant and scans the service source for any surviving
      # target-state literal. manual_promotion_advisory_spec.rb still drives
      # the real service over every target state and asserts the states it
      # refuses on are exactly the states this constant names.
      GATED_TARGET_STATES = %w[blessed].freeze

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

        # Liveness: every qualifying instance must be heard from NOW. A stale
        # heartbeat means the platform is already treating this instance as
        # silent (InstanceStatusSensor -> drift remediation -> reprovision), so
        # it is evidence of a fault, not evidence a version is safe to bless.
        #
        # Deliberately NOT operator-tunable, unlike the two thresholds above:
        # those trade evidence for a fleet too small or too fresh to supply it,
        # whereas this one asks only that the evidence be current. There is no
        # fleet size at which "we have not heard from these instances" is
        # promotion evidence, so it reuses NodeInstance::HEARTBEAT_STALE_AFTER
        # (the same staleness the rest of the platform acts on) with no
        # override key. Setting module_promotion_dwell_minutes to 0 still
        # removes the dwell bar; it does not remove this.
        silent = running_instances.count(&:stale_heartbeat?)
        return { eligible: false,
                 reason: "#{silent} of #{running_count} qualifying instances are silent " \
                         "(no heartbeat within #{::System::NodeInstance::HEARTBEAT_STALE_AFTER.to_i}s)",
                 running_count: running_count, required_count: required } if silent.positive?

        # Dwell time: EVERY qualifying instance must have been running this
        # digest for at least the resolved threshold, so the anchor is the
        # instance that started running it most recently — the shortest dwell
        # in the set.
        starts = running_instances.map { |inst| inst.first_seen_running_at_for(version.node_module_id) }
        unstamped = starts.count(&:nil?)

        # An unstamped instance carries no dwell evidence at all, so it
        # contributes zero — which is ineligible for any positive threshold and
        # still eligible under an explicit 0-minute override (that override
        # disables the dwell gate outright, exactly as it did before).
        observed = unstamped.positive? ? 0.seconds : (Time.current - starts.max)
        dwell_reason =
          if unstamped.positive?
            "no first_seen_running_at recorded for #{unstamped} of #{running_count} qualifying instances"
          else
            "dwell_time #{observed.to_i}s < required #{dwell.to_i}s"
          end
        return { eligible: false, reason: dwell_reason,
                 running_count: running_count, required_count: required,
                 dwell_time_minutes: (observed / 60.0).round(1) } if observed < dwell

        {
          eligible: true,
          running_count: running_count,
          required_count: required,
          dwell_time_minutes: (observed / 60.0).round(1)
        }
      end

      # Does a promotion to this target state turn on these criteria at all?
      def self.gates?(target_state)
        GATED_TARGET_STATES.include?(target_state.to_s)
      end

      # #evaluate for a criteria-relevant target state, nil otherwise — so a
      # caller that promotes to any state can ask one question and get either a
      # verdict or "not applicable", without restating the gated set.
      def self.advisory(version:, target_state:)
        return nil unless gates?(target_state)

        evaluate(version: version)
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
