# frozen_string_literal: true

module System
  module Status
    module Contributors
      # Fleet remediation effectiveness, one component per account (campaign
      # 01a08c9b B5, checklist row 23). It reads
      # System::Fleet::RemediationOutcomeSummary, the same computation that
      # GET /system/fleet/remediation_outcomes renders, so the endpoint and this
      # component cannot disagree about what "effective" or "stuck" means.
      #
      # ── TWO FACTS, TWO CONDITIONS ───────────────────────────────────────
      # EffectivenessMeasured: the 7-day rate is the mean effectiveness_score
      # over SETTLED outcomes (effective or ineffective). With nothing settled
      # it is nil, and the condition is not_measured, never a 0% rate. No
      # threshold is ruled for the rate, so a measured rate is reported, not
      # judged.
      #
      # NoStuckRemediations: a fingerprint whose ineffective streak reaches
      # DecisionEngine::STUCK_STREAK_THRESHOLD is one the engine escalates as
      # stuck. Any such fingerprint makes the component degraded, and each is
      # named.
      #
      # The outcome grid, top-5 per kind and top-3 stuck are out of scope here.
      # They render later through the drawer's derived slot.
      class RemediationEffectivenessContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "remediation_effectiveness"
        REF  = "fleet_remediation"

        SUMMARY = ::System::Fleet::RemediationOutcomeSummary

        EFFECTIVENESS = "EffectivenessMeasured"
        STUCK         = "NoStuckRemediations"

        Remediation = Struct.new(:account, keyword_init: true)

        def kind = KIND

        def account_scoped? = true

        # Design §5.4: the DecisionEngine's stuck lane owns escalation.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          yield Remediation.new(account: account)
        end

        def ref_for(_record) = REF

        def display_name_for(_record) = "Fleet remediation"

        def presentation
          { "icon" => "Wrench", "label" => "Fleet remediation", "group_order" => 130 }
        end

        def conditions_for(record)
          now = Time.current
          summary = SUMMARY.call(account: record.account)
          [ effectiveness(summary, now), stuck(summary, now) ]
        end

        private

        def effectiveness(summary, now)
          totals = summary.fetch(:totals)
          rate = totals.fetch(:effectiveness_rate)
          evidence = {
            "source" => "system_fleet_remediation_outcomes via RemediationOutcomeSummary, acted_at within the window",
            "window_days" => summary.fetch(:window_days),
            "totals" => totals.except(:effectiveness_rate).transform_keys(&:to_s),
            "effectiveness_rate" => rate
          }

          if rate.nil?
            CONDITION.build(
              type: EFFECTIVENESS, status: CONDITION::UNKNOWN, reason: "NothingSettled",
              message: "no remediation settled effective or ineffective in the window; the rate is unknown, not 0%",
              evidence: evidence, now: now
            )
          else
            CONDITION.build(
              type: EFFECTIVENESS, status: true, reason: "Measured",
              message: "#{(rate * 100).round(1)}% of settled remediations were effective",
              evidence: evidence, now: now
            )
          end
        end

        def stuck(summary, now)
          stuck = summary.fetch(:stuck)
          fingerprints = stuck.fetch(:fingerprints)
          evidence = {
            "source" => "RemediationOutcome.ineffective_streak against DecisionEngine::STUCK_STREAK_THRESHOLD",
            "threshold" => stuck.fetch(:threshold),
            "stuck_count" => fingerprints.size,
            "fingerprints" => fingerprints.map { |f| f.transform_keys(&:to_s) }
          }

          if fingerprints.empty?
            CONDITION.build(type: STUCK, status: true, reason: "NoneStuck", evidence: evidence, now: now)
          else
            CONDITION.build(
              type: STUCK, status: false, reason: "RemediationStuck", severity: CONDITION::SEVERITY_DEGRADED,
              message: "#{fingerprints.size} fingerprint(s) at or past the engine's stuck streak of #{stuck.fetch(:threshold)}",
              evidence: evidence, now: now
            )
          end
        end
      end
    end
  end
end
