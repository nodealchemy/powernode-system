# frozen_string_literal: true

module System
  module CveOps
    # IMP-60717919d4a0 — the standing alarm for an exposure the autonomy lane
    # could not clear.
    #
    # CvePublishedSensor is a FRESH-DETECTION lane: it selects `detected_at`
    # inside its window, and `detected_at` is written once and refreshed only
    # when an sbom match CONFIRMS a row that had no version evidence
    # (CveExposure#record_match, IMP-7bba0413c36a) — never by an ordinary
    # re-match. An open critical/high exposure therefore re-runs
    # orchestration for one window (~144 ticks at the 600s dedup TTL over
    # 24h) and then leaves the sensor's view for good — a day of churn and
    # then silence, with the exposure still open. CriticalUpgradeAvailableSensor
    # does not cover that gap (it needs a drifted PackageModuleLink with a
    # live upstream package), so the unpromoted-fix case went fully dark.
    #
    # This is the surface that keeps it visible, and deliberately NOT a
    # Signal: a signal would re-run triage and the per-link refresh executors
    # forever, which is the churn the window exists to bound, and it would need
    # a new action category and policy declaration. Instead: one durable,
    # broadcast FleetEvent (`cve_responder.exposure_aged_out`) per CVE per
    # window, severity mirroring the CVE, correlated to `cve_pub:<cve_id>` so
    # system_inspect_correlation and system_recent_signals file it next to the
    # decisions that failed to clear it. It re-emits once the last record is
    # itself older than the window — a bounded reminder rather than either
    # every-tick noise or a single line that scrolls away.
    #
    # Read-side except for the event row. Runs from CveResponderService#tick!
    # with the sensor's OWN resolved window (resolved once per tick and handed
    # in), so widening the window moves both lanes together. Bounded per pass
    # in two ways — see #escalate! for the query order and
    # DEFAULT_MAX_CVES_PER_TICK for the ceiling.
    class AgedExposureEscalator
      EVENT_KIND = "cve_responder.exposure_aged_out"
      SOURCE     = "cve_responder"
      REASON     = "open_beyond_detection_lookback"

      # The event band per CVE severity. Only ELIGIBLE_SEVERITIES reach here,
      # so today this is a true mirror; an explicit map rather than a default
      # so a severity added to that list later fails loudly in the spec that
      # pins it instead of being silently filed as `high`.
      SEVERITY_BAND = { "critical" => :critical, "high" => :high }.freeze

      # Ceiling on CVEs escalated in ONE pass. Unlike the sensor's fresh set,
      # this candidate set grows monotonically — an exposure nobody remediates
      # only gets older — so a first tick against a real backlog (565 open
      # exposures in the 2026-09-02 audit) would otherwise emit and broadcast
      # one event per CVE in a single pass. Nothing is lost by capping: an
      # un-escalated CVE carries no record, so the next tick picks it up, and
      # the window dedup rotates the escalated ones out of the candidate set.
      # Same shape as InstanceUnrecoverableSensor's `max_per_tick`.
      DEFAULT_MAX_CVES_PER_TICK = 25
      MAX_CVES_SETTING_KEY      = "system.cve_responder.aged_out_max_cves_per_tick"
      ACCOUNT_MAX_CVES_KEY      = "cve_responder_aged_out_max_cves_per_tick"

      attr_reader :account, :lookback

      def initialize(account:, lookback:)
        @account = account
        @lookback = lookback
      end

      # Returns the number of events emitted this pass.
      #
      # ORDER MATTERS. In steady state — every tick but the first of a window
      # — every aged CVE is already escalated and this pass emits nothing, so
      # the work has to be bounded BEFORE any exposure row is loaded:
      #   1. one grouped query for the candidate CVEs (ids only, no rows),
      #   2. one query for the correlations already escalated in this window,
      #   3. the cap,
      #   4. only then the exposures, for the survivors alone.
      # Loading the whole aged set first and deduping in Ruby made the no-op
      # pass cost the full table scan plus preloads, forever, on a set that
      # only grows.
      def escalate!
        return 0 unless defined?(::System::CveExposure) && defined?(::System::Cve)
        return 0 unless defined?(::System::Fleet::EventBroadcaster)

        candidates = candidate_cves
        return 0 if candidates.empty?

        already = recently_escalated_correlations(candidates.map { |_uuid, external| correlation_for(external) })
        pending = candidates.reject { |_uuid, external| already.include?(correlation_for(external)) }
        return 0 if pending.empty?

        pending = pending.first(max_cves_per_tick)
        exposures_by_cve = aged_exposures_for(pending.map(&:first)).group_by(&:cve_id)
        cves = ::System::Cve.where(id: pending.map(&:first)).index_by(&:id)

        pending.count do |cve_uuid, external|
          cve = cves[cve_uuid]
          exposures = exposures_by_cve[cve_uuid]
          next false if cve.nil? || exposures.blank?

          emit!(cve, exposures, correlation_for(external)).present?
        end
      end

      private

      def correlation_for(external_cve_id)
        "cve_pub:#{external_cve_id}"
      end

      def max_cves_per_tick
        @max_cves_per_tick ||= ::System::CveOps::TunableSetting.resolve(
          account: account,
          account_key: ACCOUNT_MAX_CVES_KEY,
          site_setting_key: MAX_CVES_SETTING_KEY,
          default: DEFAULT_MAX_CVES_PER_TICK
        )
      end

      # [[cve uuid, cve identifier], ...] for every CVE with at least one open
      # eligible exposure older than the window, OLDEST FIRST. Grouped in SQL:
      # no exposure row is materialized, and the ordering is the fair one —
      # the longest-unremediated CVE is the first to be escalated when the cap
      # bites. It cannot starve the rest, because an escalated CVE drops out of
      # the candidate set for a whole window.
      def candidate_cves
        aged_scope
          .group("system_cves.id", "system_cves.cve_id")
          .order(Arel.sql("MIN(system_cve_exposures.detected_at) ASC"))
          .pluck("system_cves.id", "system_cves.cve_id")
      end

      # The rows, for the handful of CVEs actually being escalated.
      def aged_exposures_for(cve_uuids)
        aged_scope
          .where(system_cve_exposures: { cve_id: cve_uuids })
          .preload(:cve, node_module_version: :node_module)
          .to_a
      end

      # `state: "open"` only. `suspected` (IMP-7bba0413c36a — a keyword-only
      # match with no version evidence) is deliberately outside this lane: a
      # suspicion does not age into an alarm, it waits for an SBOM match.
      def aged_scope
        ::System::CveExposure
          .joins(:cve, node_module_version: :node_module)
          .where(system_node_modules: { account_id: account.id })
          .where(state: "open")
          .where(system_cves: { severity: ::System::CveOps::Sensors::CvePublishedSensor::ELIGIBLE_SEVERITIES })
          .where("system_cve_exposures.detected_at <= ?", lookback.ago)
      end

      # One query for the whole pass: the correlation ids that already carry
      # an aged-out record younger than the window.
      def recently_escalated_correlations(correlations)
        ::System::FleetEvent
          .where(account_id: account.id, kind: EVENT_KIND)
          .where(correlation_id: correlations)
          .where("emitted_at > ?", lookback.ago)
          .distinct
          .pluck(:correlation_id)
          .to_set
      end

      def emit!(cve, exposures, correlation)
        module_ids = exposures.filter_map { |e| e.node_module_version&.node_module_id }.uniq
        oldest = exposures.filter_map(&:detected_at).min

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: EVENT_KIND,
          # Mirrors the CVE: an unremediated critical exposure past the window
          # is not routine telemetry.
          severity: SEVERITY_BAND.fetch(cve.severity, :high),
          source: SOURCE,
          correlation_id: correlation,
          # The row uuid, for the ref column; the identifier rides in the
          # payload, as the signal's own decision events carry it.
          cve_id: cve.id,
          payload: {
            "cve_id" => cve.cve_id,
            "cve_severity" => cve.severity,
            "cve_summary" => cve.summary.to_s.truncate(200),
            "exposure_ids" => exposures.map(&:id),
            "affected_module_ids" => module_ids,
            "affected_packages" => exposures.map(&:package_name).compact.uniq,
            "exposure_count" => exposures.size,
            "open_since" => oldest&.iso8601,
            "open_for_hours" => oldest ? ((Time.current - oldest) / 1.hour).floor : nil,
            "detection_lookback_hours" => (lookback / 1.hour).to_i,
            "reason" => REASON
          }.compact
        )
      end
    end
  end
end
