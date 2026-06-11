# frozen_string_literal: true

require "set"

module System
  module Fleet
    # Self-improvement Phase 0 — the validate step. Closes the autonomy loop's
    # sense -> act -> VALIDATE arc that FleetAutonomyService was missing:
    #
    #   record_proceeded!  after the loop ACTS, snapshot each PROCEEDED remediation
    #                      as a pending RemediationOutcome keyed by the triggering
    #                      signal's fingerprint.
    #   validate_due!      on a LATER tick, reuse the fresh sense pass: a pending
    #                      outcome whose settle window elapsed is EFFECTIVE if its
    #                      fingerprint is gone from the current signals, else
    #                      INEFFECTIVE (the signal still fires -> the remediation
    #                      didn't stick). That score is the ground truth the
    #                      LEARN/ADAPT steps (later phases) consume.
    class RemediationValidator
      # Minimum age before an outcome is scored — the action needs time to take
      # effect, and validation runs on a subsequent tick anyway.
      SETTLE_WINDOW = 90 # seconds

      def initialize(account:, agent: nil)
        @account = account
        @agent = agent
      end

      # Snapshot newly-PROCEEDED remediations as pending outcomes. `decisions` and
      # `signals` are parallel (decide_all maps signals -> decisions in order). One
      # pending outcome per fingerprint: a repeat for an already-pending
      # fingerprint is the same unresolved problem, not a fresh remediation.
      def record_proceeded!(decisions:, signals:, correlation_id: nil)
        return 0 if @account.nil?

        now = Time.current
        signals = Array(signals)
        recorded = 0
        Array(decisions).each_with_index do |decision, i|
          next unless proceeded?(decision)

          fingerprint = (decision[:fingerprint] || signals[i]&.fingerprint).to_s
          next if fingerprint.blank?
          next if RemediationOutcome.pending.exists?(account_id: @account.id, fingerprint: fingerprint)

          RemediationOutcome.create!(
            account: @account,
            agent_id: @agent&.id,
            signal_kind: decision[:signal_kind].to_s,
            fingerprint: fingerprint,
            action_category: decision[:action_category].to_s.presence,
            correlation_id: correlation_id,
            resource_ref: resource_ref_for(signals[i]),
            status: "pending",
            acted_at: now,
            settle_until: now + SETTLE_WINDOW,
            metadata: {
              "gate" => decision[:gate].to_s.presence,
              # F3-11(a): provenance for the sensor-failure guard — absence of
              # this fingerprint only counts as "effective" on ticks where
              # this sensor actually ran.
              "sensor" => sensor_for(signals[i])
            }.compact
          )
          recorded += 1
        end
        recorded
      end

      # Score every due pending outcome against the current sense pass. A due
      # outcome's fingerprint still present in the live signals => INEFFECTIVE;
      # absent => EFFECTIVE (the triggering condition cleared).
      #
      # F3-11(a): absence is only evidence when the outcome's OWNING sensor ran
      # this tick — collect_signals rescues per-sensor failures, so a crashed
      # sensor's fingerprints vanish from the pass and every one of its pending
      # outcomes was falsely scored effective. Outcomes whose sensor is in
      # `failed_sensors` (or carries no provenance while anything failed) stay
      # pending and re-validate on the next clean tick. A LIVE fingerprint is
      # positive evidence and still scores ineffective regardless.
      def validate_due!(current_signals:, failed_sensors: [])
        return { effective: 0, ineffective: 0 } if @account.nil?

        active = Array(current_signals).map(&:fingerprint).to_set
        failed = Array(failed_sensors).map(&:to_s).to_set
        result = { effective: 0, ineffective: 0 }
        RemediationOutcome.where(account_id: @account.id).due.find_each do |outcome|
          if active.include?(outcome.fingerprint)
            outcome.update!(status: "ineffective", validated_at: Time.current)
            result[:ineffective] += 1
            next
          end

          sensor = outcome.metadata.is_a?(Hash) ? outcome.metadata["sensor"].presence : nil
          next if failed.any? && (sensor.nil? || failed.include?(sensor))

          outcome.update!(status: "effective", validated_at: Time.current)
          result[:effective] += 1
        end
        result
      end

      private

      def proceeded?(decision)
        decision.is_a?(Hash) && decision[:decision] == :proceed
      end

      def resource_ref_for(signal)
        return nil unless signal.respond_to?(:payload) && signal.payload.is_a?(Hash)

        p = signal.payload
        (p["instance_id"] || p["peer_id"] || p["mission_id"] || p["resource_id"])&.to_s
      end

      def sensor_for(signal)
        return nil unless signal.respond_to?(:payload) && signal.payload.is_a?(Hash)

        signal.payload["_sensor"].presence
      end
    end
  end
end
