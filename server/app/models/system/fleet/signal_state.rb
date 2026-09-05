# frozen_string_literal: true

module System
  module Fleet
    # Campaign 01a07025, increment app-2 — the durable record of a STANDING
    # fleet signal.
    #
    # WHAT CHANGED. The engine's dedupe branch used to answer a re-detected
    # condition with one thing only: another `decision.deduped` FleetEvent,
    # every 60s, forever (25 of them per tick on ops-hub at 2026-09-05 04:48Z,
    # and LearningExtractor's own comment puts the fleet-wide rate at 29k/day).
    # That made the EVENT STREAM the record of a standing condition, which is
    # the worst available choice: unbounded, unqueryable in aggregate, and
    # invisible to anyone not watching the firehose. This row is the record
    # instead, and the event stream is throttled to a heartbeat.
    #
    # THE ROW IS NOT A CACHE. Rails.cache on the hub is memory_store —
    # per-Puma-process, flushed on restart — so it can only ever be an
    # optimization in front of the engine's 600s dedup, never the memory of how
    # long something has stood. Everything durable lives here.
    #
    # RESOLUTION SEAM. Every threshold this table's lanes read resolves through
    # .setting, which is the deployment-wide SiteSetting rung the fleet sensors
    # already use ("<SETTING_PREFIX>.<key>"), validated by
    # SensorConfig.coerce_threshold — THE one definition of "a usable threshold
    # value" on this platform, reused rather than re-stated so a value the
    # writer would accept can never be one the reader silently discards.
    #
    # Why SiteSetting and not the SensorConfig row: SensorConfig is keyed on a
    # SENSOR (BaseSensor.sensor_key, derived from the class name) and its
    # catalog is FleetAutonomyService::SENSORS. These four values belong to the
    # DecisionEngine and to FleetAutonomyService#notify_action, neither of which
    # is a sensor, so registering them there would invent a fake sensor key that
    # `platform.system_get_sensor_config` would list and no sensor would read.
    # The sensor-side threshold this increment DID add
    # (instance_unrecoverable's ephemeral_error_grace_seconds) goes through
    # SensorConfig, where it belongs.
    class SignalState < BaseRecord
      self.table_name = "system_fleet_signal_states"

      SETTING_PREFIX = "system.fleet.signal_state"

      # Deployment-wide fallbacks. Each is the value that makes the lane quiet
      # but not silent; an operator tunes the SiteSetting, not these.
      DEFAULTS = {
        # Minimum gap between `decision.deduped` events for one fingerprint.
        # One an hour per standing condition is a heartbeat; one a minute is
        # the flood this increment removes.
        "heartbeat_seconds" => 3600,
        # Deduped re-detections before a fingerprint with NO remediation on
        # record escalates to a person. 60 ticks is an hour of standing at the
        # 60s reconcile interval — long enough that a lane still converging is
        # never escalated, short enough that "since 2026-07-19" cannot happen
        # again.
        "escalate_after_ticks" => 60,
        # Absence longer than this starts a NEW episode: tick_count, the
        # heartbeat claim and the escalation ledger all reset. Three dedup TTLs
        # (600s each) — a fingerprint that skipped that many decide windows is
        # not the same standing condition continuing.
        "episode_reset_seconds" => 1800,
        # Minimum gap between operator-inbox rows for one notify_and_proceed
        # fingerprint. Without it the notify lane writes one Notification per
        # account user per dedup TTL — 144/day/fingerprint.
        "notify_interval_seconds" => 3600
      }.freeze

      belongs_to :account

      validates :fingerprint, :signal_kind, presence: true
      validates :first_seen_at, :last_seen_at, presence: true
      validates :tick_count, :escalation_count,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 }

      # Effective value for one declared key.
      #
      # FAILS TO THE CONSTANT, never to nil and never by raising, for anything
      # that is not a positive integer — these are read on an unattended 60s
      # tick, and a bad row must not be able to disable a rate limiter (0 reads
      # exactly like "no limit") or stop the perception pass. An UNDECLARED key
      # DOES raise: that is a caller typo, not fleet data.
      def self.setting(key)
        name = key.to_s
        fallback = DEFAULTS.fetch(name) do
          raise KeyError, "#{self.name} declares no setting #{name.inspect} " \
                          "(declared: #{DEFAULTS.keys.sort.inspect})"
        end

        raw = defined?(::SiteSetting) ? ::SiteSetting.get("#{SETTING_PREFIX}.#{name}") : nil
        ::System::Fleet::SensorConfig.coerce_threshold(raw) || fallback
      rescue KeyError
        raise
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] setting #{key} fell back to its default: " \
                          "#{e.class}: #{e.message}")
        DEFAULTS[key.to_s]
      end

      # Record one DEDUPED re-detection and return the row.
      #
      # Returns nil on any failure. Every caller treats nil as "bookkeeping is
      # unavailable this tick" and falls back to the behaviour that predates
      # this table (emit the event, do not escalate) — a broken write must
      # never be able to silence an operator OR manufacture an obligation.
      #
      # Read-modify-write under a ROW LOCK, and re-raising into a retry on the
      # insert race, for the same reason SensorConfig.upsert_for does: two
      # ticks landing together must not both read tick_count and both write
      # n+1.
      def self.record_dedupe!(account:, signal:)
        reset_after = setting(:episode_reset_seconds)
        upsert_locked(account: account, fingerprint: signal.fingerprint) do |row, now|
          start_new_episode!(row, now) if new_episode?(row, now, reset_after)
          row.signal_kind = signal.kind
          row.last_seen_at = now
          row.tick_count = row.tick_count.to_i + 1
          row.last_decision = "deduped"
        end
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] dedupe record failed for #{signal.fingerprint}: " \
                          "#{e.class}: #{e.message}")
        nil
      end

      # Claim this fingerprint's heartbeat slot for a `decision.deduped` event.
      # True at most once per heartbeat_seconds, and STAMPS when it says true —
      # a due-check that does not stamp is not a rate limiter.
      def claim_dedup_event!
        claim!(:last_dedup_event_at, self.class.setting(:heartbeat_seconds))
      end

      # The notify_and_proceed counterpart, callable without a Signal object:
      # FleetAutonomyService#notify_action has only the gate metadata, and for a
      # gate call carrying no signal identity the caller passes a synthetic
      # per-action fingerprint.
      def self.claim_notification!(account:, fingerprint:, signal_kind:)
        interval = setting(:notify_interval_seconds)
        claimed = false
        upsert_locked(account: account, fingerprint: fingerprint) do |row, now|
          row.signal_kind = signal_kind.presence || fingerprint
          row.first_seen_at ||= now
          row.last_seen_at = now
          claimed = due?(row.last_notified_at, now, interval)
          row.last_notified_at = now if claimed
        end
        claimed
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] notification claim failed for #{fingerprint}: " \
                          "#{e.class}: #{e.message}")
        # Fail OPEN: an operator who chose notify_and_proceed asked to be told,
        # and a bookkeeping error must not be what stops them being told.
        true
      end

      # Stamp an escalation that actually minted. Not a guard — see the
      # migration's note on escalated_at.
      def record_escalation!
        now = Time.current
        update_columns(escalated_at: now, escalation_count: escalation_count.to_i + 1,
                       last_decision: "standing_escalated", updated_at: now)
        true
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] escalation stamp failed for #{fingerprint}: " \
                          "#{e.class}: #{e.message}")
        false
      end

      def record_decision!(decision)
        update_columns(last_decision: decision.to_s, updated_at: Time.current)
        true
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] decision stamp failed for #{fingerprint}: " \
                          "#{e.class}: #{e.message}")
        false
      end

      # ---- internals -------------------------------------------------------

      def self.upsert_locked(account:, fingerprint:)
        attempted_insert_race = false
        begin
          transaction do
            now = Time.current
            row = lock.find_by(account_id: account.id, fingerprint: fingerprint) ||
                  new(account_id: account.id, fingerprint: fingerprint,
                      first_seen_at: now, last_seen_at: now, tick_count: 0,
                      escalation_count: 0)
            yield(row, now)
            row.save!
            row
          end
        rescue ActiveRecord::RecordNotUnique
          raise if attempted_insert_race

          attempted_insert_race = true
          retry
        end
      end
      private_class_method :upsert_locked

      def self.new_episode?(row, now, reset_after_seconds)
        return true if row.new_record? || row.last_seen_at.nil?

        row.last_seen_at < now - reset_after_seconds.seconds
      end
      private_class_method :new_episode?

      def self.start_new_episode!(row, now)
        row.first_seen_at = now
        row.tick_count = 0
        row.last_dedup_event_at = nil
        row.last_notified_at = nil
        row.escalated_at = nil
        row.escalation_count = 0
      end
      private_class_method :start_new_episode!

      def self.due?(stamp, now, interval_seconds)
        stamp.nil? || stamp <= now - interval_seconds.seconds
      end

      private

      def claim!(column, interval_seconds)
        now = Time.current
        return false unless self.class.due?(self[column], now, interval_seconds)

        update_columns(column => now, :updated_at => now)
        true
      rescue StandardError => e
        Rails.logger.warn("[FleetSignalState] #{column} claim failed for #{fingerprint}: " \
                          "#{e.class}: #{e.message}")
        # Fail OPEN on the observability lane for the same reason as
        # .claim_notification!: broken bookkeeping restores the old, loud
        # behaviour rather than inventing silence.
        true
      end
    end
  end
end
