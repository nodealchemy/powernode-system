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

      # Action categories that PROCEED without ever attempting a remediation.
      # There is nothing for the validate arc to score: the triggering
      # condition clears when a human acts, not within SETTLE_WINDOW, so a
      # pending outcome would be marked ineffective every window until the
      # F3-11 streak manufactures a false fleet.remediation_stuck HIGH
      # escalation (and forces require_approval) for a lane that never acted.
      #
      # DECLARED, never inferred — the same rule DecisionEngine states for
      # its `advisory` flag. "Skill-less and applier-less" does NOT imply
      # non-remediating: system.cert_rotate and the SLO categories are both
      # and still actuate through services outside this engine. A lane earns
      # its place here by being listed.
      #
      #   system.observation                     — pure dashboard/MCP surface
      #                                            (boot-image drift, trading
      #                                            pressure, stale BGP).
      #   system.sdwan_service_health_investigate — IMP-c7d663f24a0b. A service
      #                                            that stopped serving needs a
      #                                            person to read its logs; the
      #                                            sensor deliberately ships no
      #                                            remediation (its signal has
      #                                            just PROVEN the overlay
      #                                            healthy, so every sdwan_*
      #                                            executor would act on
      #                                            plumbing that is fine).
      #   system.disk_image_publication_investigate — IMP-71f7ca1ff35b. The
      #                                            same shape, and unlike the
      #                                            sdwan lane this one was LIVE:
      #                                            DiskImagePublicationFailure
      #                                            StreakSensor is registered in
      #                                            FleetAutonomyService::SENSORS
      #                                            and emitting. Its binding
      #                                            ("DK3") declares the reason
      #                                            in its own words — "a broken
      #                                            CI pipeline needs operator
      #                                            investigation, not an
      #                                            automated retry" — which is
      #                                            what earns the exemption;
      #                                            skill:nil alone would not.
      #   system.sdwan_ovn_deployment_investigate — IMP-57e9a90598ee. A
      #                                            degraded or stalled OVN
      #                                            deployment names failing
      #                                            infrastructure the platform
      #                                            does not provision (northd,
      #                                            the NB/SB OVSDB servers).
      #                                            There is no applier and can
      #                                            be none until a
      #                                            daemon-provisioning story
      #                                            exists; the condition
      #                                            clears when the operator
      #                                            fixes their OVN control
      #                                            plane, far beyond
      #                                            SETTLE_WINDOW.
      #   system.sdwan_apply_investigate         — IMP-da1b772c2596. The
      #                                            agent's OBSERVED SDWAN
      #                                            apply failure. There is no
      #                                            applier and can be none:
      #                                            the agent already retries
      #                                            the failing apply on every
      #                                            tick, so re-serving the
      #                                            same config remediates
      #                                            nothing — the repair is an
      #                                            image or a config a person
      #                                            changes, far beyond
      #                                            SETTLE_WINDOW. Its sibling
      #                                            kind (apply_not_measured)
      #                                            clears only when a fleet
      #                                            rollout replaces the
      #                                            agents, which is slower
      #                                            still.
      #   system.sdwan_user_device_config_investigate — IMP-7034199a5a19. An
      #                                            issued user-device
      #                                            WireGuard config whose
      #                                            AllowedIPs predates a VIP /
      #                                            lan_subnet / federation
      #                                            prefix added since. There
      #                                            is no applier and can be
      #                                            none: the drifted artefact
      #                                            is a text file on a user's
      #                                            laptop. The condition
      #                                            clears only when a person
      #                                            re-issues the device, far
      #                                            beyond SETTLE_WINDOW.
      NON_REMEDIATING_ACTION_CATEGORIES = %w[
        system.observation
        system.sdwan_service_health_investigate
        system.disk_image_publication_investigate
        system.sdwan_ovn_deployment_investigate
        system.sdwan_bgp_observation_investigate
        system.sdwan_apply_investigate
        system.sdwan_user_device_config_investigate
        system.module_verify_investigate
        system.task_backlog_investigate
      ].freeze

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
          # Non-remediating signals carry no remediation to validate — they
          # exist purely to surface a condition (dashboards / serializers /
          # MCP / the operator notification). Recording a pending outcome for
          # one would score "ineffective" forever (nothing ever remediates the
          # fingerprint) and, once the ineffective streak trips F3-11,
          # manufacture false fleet.remediation_stuck HIGH escalations +
          # forced approvals. Skip them from the validate arc — see the
          # constant for the declared list and why it is a list, not a rule.
          next if NON_REMEDIATING_ACTION_CATEGORIES.include?(decision[:action_category].to_s)
          # IMP-4f7f7a0c9d33: same exemption class, different reason. A PROPOSAL
          # is not a remediation — the remediation is the EXECUTED plan. The
          # project.* adaptation lane composes a diff plan and deliberately stops,
          # so the triggering condition cannot clear until an operator approves
          # that plan AND it runs, which is far beyond SETTLE_WINDOW. Scoring the
          # proposal by fingerprint disappearance measures the wrong event: it
          # marks every proposal ineffective on the next tick, and three of those
          # trip STUCK_STREAK_THRESHOLD into exactly the false
          # fleet.remediation_stuck HIGH escalation the applier was added to
          # remove.
          #
          # DO NOT "restore" this scoring. The outcome belongs at EXECUTION time —
          # IMP-8c37b9e5ccd5 records it when the runner dispatches an approved
          # adaptation_diff plan and flips pending -> effective on fingerprint
          # clear. Re-adding it here only reintroduces the false escalation.
          #
          # Note this pins ineffective_streak at 0 for these fingerprints, which
          # disables F3-11 as the lane's brake; DecisionEngine#propose_project_adaptation
          # carries the replacement (one open proposal per mission).
          #
          # Keyed off the applier's own proposal flag, not the action_category, so
          # any future propose-only lane inherits the exemption by declaring it.
          next if decision.dig(:remediation, :proposal)

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
