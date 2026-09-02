# frozen_string_literal: true

require "set"

module System
  module Fleet
    # Self-improvement Phase 0 — the validate step. Closes the autonomy loop's
    # sense -> act -> VALIDATE arc that FleetAutonomyService was missing:
    #
    #   record_proceeded!  after the loop ACTS, snapshot each PROCEEDED remediation
    #                      as a pending RemediationOutcome keyed by the triggering
    #                      signal's fingerprint. IMP-31f1e5f9b365: this is also
    #                      the recorder for the require_approval lane —
    #                      FleetAutonomyService#record_approved_outcome! calls it
    #                      from the EXECUTION with a synthesised :proceed
    #                      decision, so that lane inherits every guard below
    #                      rather than growing a second recorder that shares
    #                      none of them.
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
      # its `advisory` flag. A lane earns its place here by being listed.
      #
      # IMP-43e94c9d46d4: the example this comment used to give was FALSE. It
      # offered system.cert_rotate and the SLO categories as lanes that were
      # skill-less and applier-less yet actuated through some service elsewhere.
      # Neither actuated anywhere at all — and the sentence read as a reason not
      # to look, so nothing did. Both are settled now:
      # system.cert_expiring has a REMEDIATION_APPLIERS entry, and
      # system.slo_violation is declared dormant in
      # NON_REMEDIATING_SIGNAL_KINDS below. The DECLARED-never-inferred rule
      # does not need a worked example to stand; it needs the two mechanisms
      # (this list, and the applied:false refusal in #record_proceeded!) to
      # cover every routed lane, which the equality oracle in
      # spec/services/system/fleet/proceed_lane_actuation_spec.rb asserts.
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
      #   system.node_lkg_investigate            — IMP-a8f9fa74284d. A live
      #                                            node the platform cannot
      #                                            show is armed with a valid
      #                                            last-known-good, or one
      #                                            whose LKG confirmation has
      #                                            aged out. There is no
      #                                            applier and can be none:
      #                                            the LKG is frozen on the
      #                                            node's own disk by the
      #                                            agent at boot, so nothing
      #                                            the platform dispatches
      #                                            re-arms it. On a fleet
      #                                            still running agents that
      #                                            predate the boot/LKG block
      #                                            the condition clears only
      #                                            when a rollout replaces
      #                                            them — indefinitely beyond
      #                                            SETTLE_WINDOW.
      #   system.instance_replace                — IMP-e2f53e87d090 (APO-2b).
      #                                            InstanceUnrecoverableSensor
      #                                            classifies a silent instance
      #                                            a reboot cannot recover (VM
      #                                            terminated/error at the
      #                                            provider, host connections
      #                                            all unusable, or the reboot
      #                                            lane already scored
      #                                            ineffective). There is no
      #                                            replace applier: the action
      #                                            is a destructive multi-step
      #                                            re-provision no service on
      #                                            this side performs. Seeded
      #                                            require_approval, so the
      #                                            proceed arm is not reached
      #                                            today — declared anyway so
      #                                            the exemption survives an
      #                                            operator retune, exactly the
      #                                            reasoning system.capability_gap
      #                                            carries below.
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
        system.node_lkg_investigate
        system.module_promotion_investigate
        system.instance_replace
      ].freeze

      # The same exemption, keyed by SIGNAL KIND instead of action_category —
      # for a dormant lane whose category is SHARED with lanes that do actuate.
      #
      # IMP-43e94c9d46d4. system.slo_violation routes to system.module_assign,
      # and so do system.module_drift and system.config_drift, both of which
      # dispatch a real reconcile task. Listing the CATEGORY would silently
      # take those two out of the validate arc — the exemption's failure mode
      # in reverse, and invisible, because nothing complains about a lane that
      # stops being scored. So the dormant kind is named directly.
      #
      #   system.slo_violation  — the binding's skill is nil and no applier
      #                           exists. The operator ruling of 2026-09-02
      #                           left it that way: a rolling upgrade off an
      #                           SLO breach is a plan a person approves, not
      #                           an autonomous action off a timer. The lane
      #                           reports; it does not remediate.
      #   system.capability_gap — require_approval today, so record_proceeded!
      #                           never sees it, and its own binding comment
      #                           relies on that. But the policy row is
      #                           operator-tunable: a retune to
      #                           notify_and_proceed would start scoring a gap
      #                           that clears only when a human ships a module,
      #                           days later. Declared here so the exemption
      #                           survives the retune instead of resting on DB
      #                           state.
      NON_REMEDIATING_SIGNAL_KINDS = %w[
        system.slo_violation
        system.capability_gap
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
          # IMP-43e94c9d46d4 — the same exemption keyed by KIND, for a dormant
          # lane sharing its category with lanes that actuate. See the constant.
          next if NON_REMEDIATING_SIGNAL_KINDS.include?(decision[:signal_kind].to_s)
          # IMP-43e94c9d46d4 — REFUSE applied:false. The applier's own answer
          # outranks every list above it: "no applier for <kind>", a
          # control-plane fence skip, a self-managed-target skip, "instance not
          # found", apply_remediation!'s rescue. Each of those is a proceed
          # that actuated NOTHING, and a pending outcome for one scores
          # ineffective every settle window until three of them trip
          # STUCK_STREAK_THRESHOLD into a HIGH fleet.remediation_stuck for work
          # no code attempted — the F3-11 escalation firing at a gap in the
          # ACT arm while reporting it as a failed remediation.
          #
          # This is the proceed-lane half of a rule the approved lane already
          # had: FleetAutonomyService#executed_remediation? has refused
          # applied:false since IMP-31f1e5f9b365, so a byte-identical applier
          # result was scored on one lane and dropped on the other.
          #
          # TWO deliberate non-refusals, both matching that method exactly:
          #   - a DECLARED convergence_deferred is applied:false yet IS an
          #     execution; #validate_due! settles its row `inconclusive` and
          #     that row is the evidence an operator reads.
          #   - a decision carrying NO :remediation key at all is not an
          #     applier verdict, so there is nothing to refuse. Only a
          #     DECLARED false is refused, never an absent one.
          #
          # KNOWN CONSERVATIVE GAP, INHERITED DELIBERATELY, stated rather than
          # discovered later. This refusal is not limited to the four lanes
          # IMP-43e94c9d46d4 was raised for. SIX proceed-arm lanes have no
          # REMEDIATION_APPLIERS entry yet DO actuate, because their bound
          # SKILL is the actuation:
          #
          #   system.acme_cert_expiring            (system.acme_cert_rotate)
          #   system.sdwan_peer_drift              (system.sdwan_peer_remediate)
          #   system.sdwan_bgp_session_unhealthy   (system.sdwan_bgp_session_remediate)
          #   system.sdwan_credential_expiring     (system.sdwan_credential_refresh)
          #   system.federation_peer_liveness      (system.federation_peer_remediate)
          #   system.module_critical_upgrade_ready (same category)
          #
          # Each executes its skill, then apply_remediation! returns
          # applied:false/"no applier", so from here they now mint NOTHING and
          # go unscored. That is a LOSS of measurement for six lanes, and it is
          # the direction this file already chose on the approved arm:
          # FleetAutonomyService#executed_remediation? has dropped exactly
          # these since IMP-31f1e5f9b365 under this same reasoning — admitting
          # them would mean INFERRING actuation from the presence of
          # skill_result, the inference every other rule here refuses, and a
          # wrong score is ground truth the LEARN step believes while a missing
          # score is only a gap. The declared fix is unchanged and is NOT this
          # change: those bindings should return an actuation marker of their
          # own. Until they do, the two arms agree, which is the property
          # IMP-43e94c9d46d4 was actually about.
          #
          # spec/services/system/fleet/proceed_lane_actuation_spec.rb PINS that
          # list, so a seventh such lane fails a spec instead of silently
          # joining the gap.
          if decision[:remediation].is_a?(Hash) &&
             decision[:remediation][:applied] == false &&
             !deferred_convergence(decision)
            next
          end
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
          # IMP-31f1e5f9b365: the third exemption, and a third distinct reason.
          # An applier DECLARES `fingerprint_self_clearing` when its own action
          # removes the sensor's ability to observe the condition, whatever the
          # fleet then does. #apply_template_closure_drift is the case: it
          # creates exactly the assignment rows TemplateClosureDriftSensor
          # subtracts, so the fingerprint is gone from the next pass BY
          # CONSTRUCTION rather than by convergence.
          #
          # The failure mode is the MIRROR of the other two, and worse for
          # being silent. :proposal and the non-remediating list exist because
          # a fingerprint that never clears scores INEFFECTIVE forever and
          # manufactures a false fleet.remediation_stuck escalation. This one
          # scores EFFECTIVE forever: a fabricated 1.0 written into the ground
          # truth the LEARN/ADAPT steps consume, for an on-node sync that may
          # have failed outright. Nothing complains about a success, which is
          # precisely why it has to be declared rather than discovered.
          #
          # A DECLARED deferral outranks it. #validate_due! settles a
          # convergence_deferred row `inconclusive` BEFORE consulting the
          # signals at all, so that row is scored by the declaration and never
          # by fingerprint disappearance — self-clearing cannot corrupt it, and
          # skipping it would throw away the one piece of evidence an operator
          # reads for a lane that said it could not converge.
          if decision.dig(:remediation, :fingerprint_self_clearing) && !deferred_convergence(decision)
            next
          end

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
              "sensor" => sensor_for(signals[i]),
              # IMP-848c7e953e2d: the applier's own declaration that it could
              # not converge the fleet (see #deferred_convergence). Persisted
              # here because the ROW is the only thing a later tick, a
              # dashboard, or an operator ever reads — the previous attempt at
              # this evidence (`requires_reprovision` on the applier's return
              # hash) had three writers and zero readers, so it recorded the
              # skip where nothing looked.
              "convergence_deferred" => (true if deferred_convergence(decision)),
              "deferred_reason" => (decision.dig(:remediation, :reason).to_s.presence if deferred_convergence(decision))
            }.compact
          )
          recorded += 1
        end
        recorded
      end

      # Score every due pending outcome against the current sense pass. A due
      # outcome's fingerprint still present in the live signals => INEFFECTIVE;
      # absent => EFFECTIVE (the triggering condition cleared). A due outcome
      # whose applier DECLARED convergence_deferred is settled INCONCLUSIVE
      # without consulting the signals at all — see the branch below.
      #
      # F3-11(a): absence is only evidence when the outcome's OWNING sensor ran
      # this tick — collect_signals rescues per-sensor failures, so a crashed
      # sensor's fingerprints vanish from the pass and every one of its pending
      # outcomes was falsely scored effective. Outcomes whose sensor is in
      # `failed_sensors` (or carries no provenance while anything failed) stay
      # pending and re-validate on the next clean tick. A LIVE fingerprint is
      # positive evidence and still scores ineffective regardless.
      def validate_due!(current_signals:, failed_sensors: [])
        return { effective: 0, ineffective: 0, inconclusive: 0 } if @account.nil?

        active = Array(current_signals).map(&:fingerprint).to_set
        failed = Array(failed_sensors).map(&:to_s).to_set
        result = { effective: 0, ineffective: 0, inconclusive: 0 }
        RemediationOutcome.where(account_id: @account.id).due.find_each do |outcome|
          # IMP-848c7e953e2d — checked BEFORE the presence test, because for a
          # deferred remediation NEITHER answer is evidence. Absence is not:
          # the closure applier creates precisely the assignment rows its own
          # sensor subtracts, so the fingerprint is gone by construction rather
          # than by convergence. Presence is not either: the reboot_pending
          # escalation deliberately dispatched nothing, so of course the drift
          # still fires. `inconclusive` is the vocabulary's existing terminal
          # non-scoring status: ineffective_streak's `status IN (effective,
          # ineffective)` filter EXCLUDES it — note excludes, not breaks, so a
          # run of ineffectives on either side of one still accumulates to the
          # threshold. (effectiveness_score also returns nil for it, but that
          # reader has no production callers, so it is not what makes this
          # safe.) Settling here therefore takes the row out of the F3-11 brake
          # in both directions — which is why DecisionEngine#decide reads
          # RemediationOutcome.deferred_convergence? and routes this lane into
          # the same escalation the streak feeds. Do not remove one without the
          # other.
          if outcome.metadata.is_a?(Hash) && outcome.metadata["convergence_deferred"]
            outcome.update!(status: "inconclusive", validated_at: Time.current)
            result[:inconclusive] += 1
            next
          end

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

      # IMP-848c7e953e2d — DECLARED by the applier, never inferred, exactly as
      # the `:proposal` exemption above is. An applier that did the part it
      # could and knows the fleet cannot converge until the node reboots says
      # so in its return hash; anything else is a remediation the validate arc
      # is entitled to score.
      def deferred_convergence(decision)
        decision.dig(:remediation, :convergence_deferred).present?
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
