# frozen_string_literal: true

module System
  module Status
    module Contributors
      # THE CONTROL PLANE'S OWN COMPONENTS (design §4.4, increment B1).
      #
      # One component per subsystem the composite probe measures, per account.
      # The probe (System::Platform::CompositeHealthProbe) already answers "is
      # the platform healthy" with the not_measured discipline this plane
      # depends on; this contributor READS its persisted result and does not
      # re-probe anything. A status sweep that opened sockets would be a
      # fleet-wide load generator on a 60-second cron, and its failure modes
      # would be indistinguishable from the failures it reports.
      #
      # ── WHY THERE IS ALWAYS A ROW ───────────────────────────────────────
      # The snapshot is written at most every
      # `system.platform_health_check_interval_minutes`, and the scheduled
      # writer SKIPS an account with no clone of the bound agent
      # (ScheduledHealthCheckService#run_if_due! -> "no_bound_agent_clone").
      # So "no snapshot" is a normal, reachable and long-lived state — and it
      # is exactly the state where an empty screen would read as a healthy
      # platform. An account with no snapshot therefore gets one
      # `not_measured` row per known subsystem, reason `NoSnapshot`, with the
      # attribution gap named in the message. Never zero rows.
      #
      # ── WHY FRESHNESS IS ITS OWN CONDITION ──────────────────────────────
      # A stored subsystem entry is a reading with a timestamp on it, and the
      # two facts fail separately: "postgres was ok" and "we last looked four
      # hours ago" are both true and only one of them is reassuring. `Fresh`
      # goes false past twice the configured interval, which by the ladder
      # makes the component `degraded` even when every stored entry said `ok`.
      # That is deliberate: a status plane serving a stale `ok` is the precise
      # lie the composite probe was written to end.
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # The subsystem set is the probe's own SUBSYSTEMS constant. Nothing here
      # restates it, so a subsystem added to the probe gets a component with no
      # edit to this file. Nothing is ever "gone": all thirteen are structural,
      # so this contributor has no terminated/archived arm.
      class PlatformSubsystemContributor < ::Platform::Status::Contributor
        KIND = "platform_subsystem"

        PROBE   = ::System::Platform::CompositeHealthProbe
        SCHEDULE = ::System::Platform::ScheduledHealthCheckService

        # How many intervals a snapshot may age before `Fresh` goes false. Two,
        # not one: a single skipped run (a lock held, a deploy, an account whose
        # agent clone appeared late) is ordinary and must not alarm.
        STALE_AFTER_INTERVALS = 2

        # Condition types. `Healthy` is the subsystem's own reading; `Fresh` is
        # how much that reading is still worth.
        HEALTHY = "Healthy"
        FRESH   = "Fresh"

        # Probe status -> the token the condition reports. UpperCamelCase
        # because these are greppable and must never reach a status-variant
        # lookup (Platform::Status::Condition rejects anything else).
        REASON_FOR_STATUS = {
          PROBE::OK           => "Ok",
          PROBE::DEGRADED     => "Degraded",
          PROBE::DOWN         => "Down",
          PROBE::NOT_MEASURED => "NotObserved"
        }.freeze

        # A subsystem the probe declares but this snapshot does not carry —
        # an older snapshot written before the key existed. Distinct from
        # `NotObserved` (the probe asked and could not see) and from
        # `NoSnapshot` (nothing ever ran).
        REASON_ABSENT     = "SubsystemAbsent"
        # Two tokens for "there is no snapshot", because the two cases have
        # different fixes and only one of them resolves itself. The scheduled
        # writer SKIPS an account with no clone of the agent the health-check
        # skill is bound to, so that account will never get a snapshot no matter
        # how long anyone waits; an account that simply has not been swept yet
        # gets one on the next tick. A single token asserting the first cause
        # would be a diagnosis this contributor never checked, and every new
        # install would read it for its first fifteen minutes.
        REASON_NO_CLONE    = "NoBoundAgentClone"
        REASON_NO_SNAPSHOT = "NoSnapshot"
        REASON_FRESH      = "SnapshotFresh"
        REASON_STALE      = "SnapshotStale"

        # Presentation only, and deliberately a FALLBACK rather than a
        # requirement: an unlisted key still gets a row, humanized. A key added
        # to the probe must never be gated on someone remembering to name it
        # here.
        DISPLAY_NAMES = {
          "mcp_endpoint"    => "MCP endpoint",
          "ai_providers"    => "AI providers",
          "acme"            => "ACME",
          "sdwan"           => "SDWAN",
          "worker_web"      => "Worker web",
          "fleet_tick"      => "Fleet tick",
          "fleet_instances" => "Fleet instances",
          "reverse_proxy"   => "Reverse proxy"
        }.freeze

        HEALTH_PAGE_PATH = "/app/system/compute/platform/health"

        # One subsystem, resolved against whatever snapshot the account has.
        # `entry` is nil when the snapshot does not carry this key and the whole
        # struct's `captured_at` is nil when there is no snapshot at all — the
        # two absences are different facts and the conditions report them as
        # such.
        Subsystem = Struct.new(
          :key, :entry, :captured_at, :snapshot_id, :stale_after_seconds, :absence,
          keyword_init: true
        ) do
          def snapshot? = captured_at.present?
          def status = entry.is_a?(Hash) ? entry["status"].to_s : nil
          def fresh?(now) = snapshot? && captured_at >= (now - stale_after_seconds)
        end

        def kind = KIND

        def account_scoped? = true

        # Always the full declared set, in the probe's own reading order.
        def each_component(account)
          snapshot = latest_snapshot(account)
          stale_after = stale_after_seconds
          # Resolved ONCE per sweep, not once per subsystem: it is a SkillBindings
          # lookup plus a principal resolution, and thirteen of them per account
          # per minute would be a real cost for one message.
          absence = snapshot ? nil : snapshot_absence(account)

          PROBE::SUBSYSTEMS.each do |name|
            key = name.to_s
            yield Subsystem.new(
              key: key,
              entry: snapshot && subsystem_entry(snapshot, key),
              captured_at: snapshot&.captured_at,
              snapshot_id: snapshot&.id,
              stale_after_seconds: stale_after,
              absence: absence
            )
          end
        end

        def ref_for(record) = record.key

        def display_name_for(record)
          DISPLAY_NAMES.fetch(record.key) { record.key.humanize }
        end

        # The snapshot the reading came from. It changes on every capture,
        # which is what a generation is for: it lets a reader tell "still the
        # same observation" from "observed again and unchanged".
        def observed_generation_for(record) = record.snapshot_id

        # The SOURCE's time, never the sweep's — freshness honesty depends on
        # it. nil when there is no snapshot, which lets the sweep fall back to
        # now: we learned "there is no snapshot" just now.
        def observed_at_for(record) = record.captured_at

        def presentation
          # group_order 10: the control plane's own components sort above the
          # fleet it manages.
          { "icon" => "Activity", "label" => "Platform subsystem", "group_order" => 10 }
        end

        def links_for(_record)
          [ { "label" => "Platform health", "path" => HEALTH_PAGE_PATH } ]
        end

        # The probe declares no dependency graph between its subsystems — its
        # SUBSYSTEMS constant is an ordered list, not edges, and nothing else in
        # the extension expresses "sidekiq requires redis" as data. Inventing
        # those edges here would put a hand-drawn graph behind the root-cause
        # ranking, which is worse than no graph: the ranking would look
        # authoritative and be a guess. Left empty until the probe declares
        # them.
        def dependencies_for(_record) = []

        # Design §5.1: every platform_subsystem recommendation is
        # `not_actuatable` by default. The only actuation path for the control
        # plane's own components is an extension lane that runs the INV-1
        # self-management fence, so this contributor offers no buttons.
        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [ healthy_condition(record, now), fresh_condition(record, now) ]
        end

        private

        def latest_snapshot(account)
          return nil if account.blank?

          ::System::PlatformHealthSnapshot.for_account(account).recent.first
        end

        def subsystem_entry(snapshot, key)
          entry = snapshot.subsystems.is_a?(Hash) ? snapshot.subsystems[key] : nil
          entry.is_a?(Hash) ? entry : nil
        end

        # Twice the interval the scheduled writer actually uses. Both the
        # setting name and the fallback come from that service's own constants
        # so the two cannot drift; the resolution is repeated rather than called
        # because `#interval_minutes` is a private instance method on a service
        # that needs an account, and this contributor is per-kind.
        def stale_after_seconds
          configured = ::SiteSetting.get(SCHEDULE::INTERVAL_SETTING)
          minutes =
            if configured.present? && configured.to_i.positive?
              configured.to_i
            else
              SCHEDULE::DEFAULT_INTERVAL_MINUTES
            end

          minutes * STALE_AFTER_INTERVALS * 60
        end

        # The subsystem's own reading, carried through rather than re-derived:
        # the probe's prose becomes the message and its whole entry becomes the
        # evidence, so the drawer shows what was actually observed (the
        # endpoint, the response time, the error class) and not a summary of it.
        def healthy_condition(record, now)
          return no_snapshot_condition(record, HEALTHY, now) unless record.snapshot?

          entry = record.entry
          unless entry
            return ::Platform::Status::Condition.build(
              type: HEALTHY, status: ::Platform::Status::Condition::UNKNOWN,
              reason: REASON_ABSENT,
              message: "the snapshot at #{record.captured_at.iso8601} carries no entry for #{record.key}",
              evidence: { "snapshot_id" => record.snapshot_id.to_s, "subsystem" => record.key },
              observed_at: record.captured_at, now: now
            )
          end

          status = record.status
          ::Platform::Status::Condition.build(
            type: HEALTHY,
            status: condition_status_for(status),
            reason: REASON_FOR_STATUS.fetch(status, REASON_ABSENT),
            message: probe_message(entry),
            severity: severity_for(status),
            evidence: entry.except("status"),
            observed_generation: record.snapshot_id,
            observed_at: record.captured_at,
            now: now
          )
        end

        def fresh_condition(record, now)
          return no_snapshot_condition(record, FRESH, now) unless record.snapshot?

          fresh = record.fresh?(now)
          age = (now - record.captured_at).to_i

          ::Platform::Status::Condition.build(
            type: FRESH,
            status: fresh,
            reason: fresh ? REASON_FRESH : REASON_STALE,
            message: "last captured #{age}s ago; stale after #{record.stale_after_seconds}s",
            evidence: {
              "captured_at" => record.captured_at.iso8601,
              "age_seconds" => age,
              "stale_after_seconds" => record.stale_after_seconds,
              "interval_setting" => SCHEDULE::INTERVAL_SETTING
            },
            observed_at: record.captured_at,
            now: now
          )
        end

        # Which of the two no-snapshot cases this account is in, resolved rather
        # than assumed.
        #
        # `bound_agent_clone` is private on the scheduler, and it is reached by
        # #send deliberately: it is a SkillBindings registration lookup followed
        # by an AccountPrincipalResolver.existing call, and re-deriving that
        # chain here would be a second answer to "who owns this skill" — the
        # exact duplication that service's own doc records as a live
        # mis-attribution bug. Reading its answer is right; copying its
        # reasoning is not.
        #
        # A lookup that RAISES is its own third case. Reporting it as "no clone"
        # would be the same unchecked diagnosis in a new place.
        def snapshot_absence(account)
          clone = SCHEDULE.new(account: account).send(:bound_agent_clone)
          clone ? { cause: :not_yet_run } : { cause: :no_bound_agent_clone }
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] bound-clone lookup failed: #{e.class}: #{e.message}")
          { cause: :unresolved, error: "#{e.class}: #{e.message}" }
        end

        # The state the brief calls out and the one an empty screen would hide.
        # The message names the case that actually applies, because "the
        # scheduler skips accounts with no agent clone" is true of the platform
        # and not necessarily of THIS account.
        def no_snapshot_condition(record, type, now)
          absence = record.absence || { cause: :unresolved }
          evidence = { "interval_setting" => SCHEDULE::INTERVAL_SETTING,
                       "cause" => absence[:cause].to_s }
          evidence["error"] = absence[:error] if absence[:error].present?

          ::Platform::Status::Condition.build(
            type: type,
            status: ::Platform::Status::Condition::UNKNOWN,
            reason: absence[:cause] == :no_bound_agent_clone ? REASON_NO_CLONE : REASON_NO_SNAPSHOT,
            message: absence_message(absence),
            evidence: evidence,
            now: now
          )
        end

        def absence_message(absence)
          case absence[:cause]
          when :no_bound_agent_clone
            "no platform health snapshot has ever been captured, and none will be: this account " \
              "has no clone of the agent the scheduled check is bound to, so every tick skips it"
          when :not_yet_run
            "no platform health snapshot has been captured yet; the bound agent clone exists, so " \
              "the next scheduled check should write one"
          else
            "no platform health snapshot has ever been captured, and whether the scheduled check " \
              "can run for this account could not be determined (#{absence[:error]})"
          end
        end

        def condition_status_for(status)
          case status
          when PROBE::OK then true
          when PROBE::DEGRADED, PROBE::DOWN then false
          else ::Platform::Status::Condition::UNKNOWN
          end
        end

        # `down` has to be asked for; the default false severity is `degraded`
        # and must not silently escalate.
        def severity_for(status)
          status == PROBE::DOWN ? ::Platform::Status::Condition::SEVERITY_DOWN : nil
        end

        # The probe's own prose, whichever field it used. `reason` for a
        # not_measured, `error` for an observed failure, and both when it has
        # both.
        def probe_message(entry)
          [ entry["reason"], entry["error"] ].compact_blank.join(" — ").presence ||
            entry["observed_via"].presence
        end
      end
    end
  end
end
