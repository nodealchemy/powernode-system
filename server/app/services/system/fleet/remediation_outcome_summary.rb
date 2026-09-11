# frozen_string_literal: true

module System
  module Fleet
    # The remediation-outcome read model (campaign 01a08c9b B5).
    #
    # Extracted verbatim from Api::V1::System::FleetController#remediation_outcomes
    # so that the operator endpoint and the remediation_effectiveness status
    # contributor compute ONE answer. Two copies of "effectiveness" or of
    # "stuck" would drift into rival definitions, which is the defect the
    # endpoint was written to avoid.
    #
    # Per signal_kind over the window: counts by status, and an effectiveness
    # rate = mean RemediationOutcome#effectiveness_score over SETTLED rows.
    # Pending and inconclusive rows carry no score, so a kind with nothing
    # settled reports nil rather than a misleading 0%.
    #
    # `stuck` is the set of fingerprints the DecisionEngine is escalating as
    # stuck right now, computed with the engine's own ineffective_streak and
    # STUCK_STREAK_THRESHOLD. It is not windowed, because the engine's streak
    # is not.
    class RemediationOutcomeSummary
      DEFAULT_WINDOW_DAYS = 7
      STUCK_CANDIDATE_LIMIT = 200

      def self.call(account:, window_days: DEFAULT_WINDOW_DAYS)
        new(account: account, window_days: window_days).call
      end

      def initialize(account:, window_days: DEFAULT_WINDOW_DAYS)
        @account = account
        @window_days = window_days
      end

      def call
        since = @window_days.days.ago
        windowed = RemediationOutcome.where(account: @account, acted_at: since..)

        counts = windowed.group(:signal_kind, :status).count
        scores = Hash.new { |h, k| h[k] = [] }
        windowed.where(status: %w[effective ineffective]).select(:id, :signal_kind, :status)
                .find_each { |outcome| scores[outcome.signal_kind] << outcome.effectiveness_score }

        kinds = counts.keys.map(&:first).uniq.sort.map do |kind|
          by_status = counts.each_with_object({}) { |((k, status), n), acc| acc[status] = n if k == kind }
          outcome_summary(by_status, scores[kind]).merge(signal_kind: kind)
        end
        total_by_status = counts.each_with_object(Hash.new(0)) { |((_, status), n), acc| acc[status] += n }

        {
          window_days: @window_days,
          since: since.iso8601,
          kinds: kinds,
          totals: outcome_summary(total_by_status, scores.values.flatten),
          stuck: stuck_remediations
        }
      end

      private

      def outcome_summary(by_status, scores)
        RemediationOutcome::STATUSES.index_with { |s| by_status.fetch(s, 0) }.merge(
          settled: scores.size,
          effectiveness_rate: scores.empty? ? nil : (scores.sum / scores.size).round(4)
        )
      end

      # Only a fingerprint with at least `threshold` ineffective rows can have
      # a streak that long, so that is the cheap pre-filter; the verdict is
      # the engine's own RemediationOutcome.ineffective_streak.
      def stuck_remediations
        threshold = DecisionEngine::STUCK_STREAK_THRESHOLD
        candidates = RemediationOutcome
          .where(account: @account, status: "ineffective")
          .group(:fingerprint)
          .having("COUNT(*) >= ?", threshold)
          .order(Arel.sql("MAX(validated_at) DESC NULLS LAST"))
          .limit(STUCK_CANDIDATE_LIMIT)
          .pluck(:fingerprint, Arel.sql("MAX(signal_kind)"), Arel.sql("MAX(validated_at)"))

        fingerprints = candidates.filter_map do |fingerprint, signal_kind, last_validated_at|
          streak = RemediationOutcome.ineffective_streak(account: @account, fingerprint: fingerprint)
          next if streak < threshold

          { fingerprint: fingerprint, signal_kind: signal_kind, streak: streak,
            last_validated_at: last_validated_at&.iso8601 }
        end

        { threshold: threshold, fingerprints: fingerprints }
      end
    end
  end
end
