# frozen_string_literal: true

module System
  module Status
    module Contributors
      # The honeypot canary, one component per account (campaign 01a08c9b B5,
      # checklist rows 20 and 21). It carries HoneypotCanaryTile's reading to
      # the server with the same semantics.
      #
      # ── THE DATA ────────────────────────────────────────────────────────
      # An access to a canary is a system_fleet_events row of kind
      # system.honeypot_triggered (Honeypot::CanaryModuleService#observe_access!),
      # which the fleet tick's HoneypotAccessSensor reads. Every count cites
      # system_fleet_events.emitted_at.
      #
      # ── WHEN THE FEED IS DOWN ───────────────────────────────────────────
      # The tile's "feed down" was a failed or malformed fetch. Server-side
      # there is no fetch, so availability is judged by the fleet tick with the
      # composite probe's OWN rule, CompositeHealthProbe#fleet_tick_reading: the
      # newest fleet.tick_complete against tick_staleness_seconds. No new
      # threshold. The feed is down, and the reason names which case, when no
      # tick was ever recorded, when the newest tick is stale, when that tick
      # lists HoneypotAccessSensor in failed_sensors, or when it predates the
      # failed_sensors key and so cannot say. A down feed is not_measured:
      # never ok, and never ok with a count of 0.
      #
      # ── THE RATCHET ─────────────────────────────────────────────────────
      # An outage may raise severity but never lower one already observed
      # (HoneypotCanaryTile.tsx:104-114). A canary this component last stored
      # as tripped keeps that severity while the feed is down. One last stored
      # clear, or never stored, reads not_measured. Counts are withheld for the
      # whole outage, because a stale number invites a fresh reading.
      #
      # ── SEVERITY ────────────────────────────────────────────────────────
      # The tile's own rule (HoneypotCanaryTile.tsx:64-67 and :102): any
      # access in 24h is an alert, read here as down; any in 7d is a warning,
      # read as degraded; none is clear.
      class HoneypotContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "honeypot"
        REF  = "canary"

        EVENT_KIND = "system.honeypot_triggered"
        SENSOR     = "HoneypotAccessSensor"
        PROBE      = ::System::Platform::CompositeHealthProbe
        EVENTS     = ::System::FleetEvent

        FEED      = "FeedAvailable"
        UNTOUCHED = "CanaryUntouched"

        # The tile's two windows (fresh24h and fresh7d).
        ALERT_WINDOW = 24.hours
        WARN_WINDOW  = 7.days

        OUTAGE_MESSAGES = {
          "NoFleetTick" => "no fleet.tick_complete has ever been recorded for this account, so nothing reads the canary",
          "FleetTickStale" => "the newest fleet.tick_complete is older than tick_staleness_seconds, so the canary is not being read",
          "HoneypotSensorFailed" => "the newest fleet tick reports that HoneypotAccessSensor failed",
          "SensorReportAbsent" => "the newest fleet tick predates failed_sensors, so it cannot say whether HoneypotAccessSensor ran"
        }.freeze

        Canary = Struct.new(:account, keyword_init: true)

        def kind = KIND

        def account_scoped? = true

        # Design §5.4: the fleet tick's own lane (HoneypotAccessSensor) owns
        # escalation for this kind.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          yield Canary.new(account: account)
        end

        def ref_for(_record) = REF

        def display_name_for(_record) = "Honeypot canary"

        def presentation
          { "icon" => "ShieldAlert", "label" => "Honeypot canary", "group_order" => 110 }
        end

        def conditions_for(record)
          now = Time.current
          probe = PROBE.new(account: record.account)
          tick = probe.last_fleet_tick
          reading = probe.fleet_tick_reading(tick)
          outage = feed_outage(tick, reading)
          previous = CONDITION.index_by_type(stored_conditions(record.account))

          if outage
            [ feed_down(outage, tick, reading, previous, now), ratchet(outage, previous, now) ]
          else
            [ feed_up(reading, now), observed(record.account, now) ]
          end
        end

        private

        def feed_outage(tick, reading)
          return "NoFleetTick" if tick.nil? || reading[:status] == PROBE::NOT_MEASURED
          return "FleetTickStale" unless reading[:status] == PROBE::OK

          payload = tick.payload.is_a?(Hash) ? tick.payload : {}
          return "SensorReportAbsent" unless payload.key?("failed_sensors")
          return "HoneypotSensorFailed" if Array(payload["failed_sensors"]).include?(SENSOR)

          nil
        end

        def tick_evidence(reading)
          {
            "source" => "system_fleet_events.emitted_at, kind fleet.tick_complete",
            "rule" => "CompositeHealthProbe#fleet_tick_reading",
            "last_tick_at" => reading[:last_tick_at],
            "age_seconds" => reading[:age_seconds],
            "staleness_threshold_seconds" => reading[:staleness_threshold_seconds]
          }.compact
        end

        def feed_up(reading, now)
          CONDITION.build(type: FEED, status: true, reason: "FleetTickFresh", evidence: tick_evidence(reading), now: now)
        end

        def feed_down(outage, tick, reading, previous, now)
          failed = tick&.payload.is_a?(Hash) ? tick.payload["failed_sensors"] : nil
          CONDITION.build(
            type: FEED,
            status: CONDITION::UNKNOWN,
            reason: outage,
            message: OUTAGE_MESSAGES.fetch(outage),
            evidence: tick_evidence(reading).merge(
              "failed_sensors" => failed,
              "unavailable_since" => unavailable_since(previous[FEED], now)
            ).compact,
            now: now
          )
        end

        # The START of the outage, not this sweep (HoneypotCanaryTile.tsx:77-81).
        # The sweep keeps a condition's last_transition_at while its status
        # holds, so a feed that was already down keeps the time it went down.
        def unavailable_since(previous_feed, now)
          return now.iso8601 unless previous_feed && previous_feed["status"] == CONDITION::UNKNOWN

          previous_feed["last_transition_at"].presence ||
            previous_feed.dig("evidence", "unavailable_since").presence ||
            now.iso8601
        end

        def observed(account, now)
          scope = EVENTS.where(account: account, kind: EVENT_KIND)
          count_24h = scope.where(emitted_at: (now - ALERT_WINDOW)..now).count
          count_7d  = scope.where(emitted_at: (now - WARN_WINDOW)..now).count
          last_access_at = scope.maximum(:emitted_at)
          evidence = {
            "source" => "system_fleet_events.emitted_at, kind #{EVENT_KIND}",
            "count_24h" => count_24h,
            "count_7d" => count_7d,
            "last_access_at" => last_access_at&.iso8601
          }

          if count_24h.positive?
            CONDITION.build(type: UNTOUCHED, status: false, reason: "AccessedWithin24h",
                            severity: CONDITION::SEVERITY_DOWN, evidence: evidence, now: now,
                            message: "#{count_24h} canary access(es) in the last 24h")
          elsif count_7d.positive?
            CONDITION.build(type: UNTOUCHED, status: false, reason: "AccessedWithin7d",
                            severity: CONDITION::SEVERITY_DEGRADED, evidence: evidence, now: now,
                            message: "#{count_7d} canary access(es) in the last 7 days")
          else
            CONDITION.build(type: UNTOUCHED, status: true, reason: "NoAccess", evidence: evidence, now: now)
          end
        end

        def ratchet(outage, previous, now)
          prior = previous[UNTOUCHED]
          if prior && prior["status"] == false && CONDITION::SEVERITIES.include?(prior["severity"])
            CONDITION.build(
              type: UNTOUCHED,
              status: false,
              reason: "HeldFromLastObservation",
              severity: prior["severity"],
              message: "feed unavailable (#{outage}); holding the severity last observed rather than lowering it",
              evidence: {
                "counts_withheld" => true,
                "last_observed_reason" => prior.dig("evidence", "last_observed_reason") || prior["reason"],
                "last_observed_at" => prior.dig("evidence", "last_observed_at") || prior["observed_at"],
                "last_access_at" => prior.dig("evidence", "last_access_at")
              }.compact,
              now: now
            )
          else
            CONDITION.build(
              type: UNTOUCHED,
              status: CONDITION::UNKNOWN,
              reason: "FeedUnavailable",
              message: "feed unavailable (#{outage}); access counts are withheld rather than reported as 0",
              evidence: { "counts_withheld" => true },
              now: now
            )
          end
        end

        def stored_conditions(account)
          ::Platform::ComponentStatus
            .where(account_id: account.id, component_kind: KIND, component_ref: REF)
            .pick(:conditions)
        end
      end
    end
  end
end
