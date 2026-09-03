# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Chains the full CVE response loop:
      #   1. CveResponseExecutor: triage the CVE, enumerate exposed modules,
      #      compute risk score, build remediation plan.
      #   2. For each affected module with a PackageModuleLink: dispatch
      #      PackageModuleRefreshExecutor so the upstream-patched version
      #      gets materialized into a new NodeModuleVersion.
      #   3. For each affected module that ALREADY has a blessed version
      #      newer than current_version: dispatch RollingModuleUpgradeExecutor
      #      (one plan per template) so the patch reaches running instances.
      #   4. Mark the CveExposure rows of the modules that ACTUALLY got a
      #      dispatch (2 or 3) as `remediating`, so the dashboard reflects
      #      in-flight response and CvePublishedSensor doesn't re-fire —
      #      that sensor selects `state: "open"` exclusively
      #      (cve_ops/sensors/cve_published_sensor.rb), so `remediating` is
      #      precisely what silences it. CriticalUpgradeAvailableSensor uses
      #      the wider `unresolved` scope and is NOT silenced by it.
      #
      #      IMP-9b8d774298d5 — step 4 used to run unconditionally over every
      #      named exposure, including when steps 2 and 3 produced nothing.
      #      Silencing the sensor is only truthful once something is in
      #      flight; doing it on an empty run turned a false success into a
      #      false success that also suppressed the next alarm.
      #
      # Idempotency:
      #   - Keyed on (cve_id, node_module_id). Re-invocation for the same
      #     pair within the DecisionEngine's dedup TTL is a no-op (skipped
      #     by the engine before this executor is called).
      #   - Beyond the dedup window, the dispatched refresh job is itself
      #     idempotent (last_synced_at gate) and the rolling upgrade is
      #     guarded by the autonomy approval flow.
      #   - IMP-9b8d774298d5 changed the STEADY STATE of a run that dispatches
      #     nothing. It used to flip the exposure to `remediating` on the first
      #     tick, after which CvePublishedSensor was quiet forever. Now the
      #     exposure stays `open`, so that sensor re-emits `cve_pub:<cve_id>`
      #     each tick past its 600s dedup TTL and — under notify_and_proceed —
      #     re-runs this whole orchestration roughly every 10 minutes, with no
      #     backoff; `open_operator_request?` does not absorb it because that
      #     only covers the require_approval path.
      #   - IMP-60717919d4a0 — that repetition is NOT a standing alarm, and
      #     an earlier version of this note wrongly said it ran "until an
      #     operator acts". CvePublishedSensor selects `detected_at` inside
      #     its detection window (24h default, SiteSetting-resolved), and
      #     `detected_at` is never refreshed, so the re-runs stop after one
      #     window whether or not anyone acted. Past the window the exposure
      #     stays visible through System::CveOps::AgedExposureEscalator's
      #     `cve_responder.exposure_aged_out` FleetEvent (one per CVE per
      #     window, run from the CVE Responder tick).
      #
      # Why this exists (separate from CveResponseExecutor):
      #   CveResponseExecutor is a *planner* — it returns a plan but doesn't
      #   dispatch. This orchestrator turns the plan into concrete operations
      #   for the CVE Responder agent's `notify_and_proceed` autonomy path.
      #   The planner remains usable by Concierge for runbook generation and
      #   by humans for triage without side-effects.
      class CveRemediationOrchestrationExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "cve_remediation_orchestration",
          description: "Orchestrate the full CVE → exposure → rebuild → rolling-upgrade chain for one CVE",
          category: "security",
          inputs: {
            cve_id: { type: "string", required: true,
                      description: "Canonical CVE id, e.g. CVE-2026-12345" },
            severity: { type: "string", required: false,
                        description: "critical|high|medium|low. Defaults to the persisted Cve.severity" },
            affected_module_ids: { type: "array", required: false,
                                   description: "Optional pre-resolved list of module ids — when omitted, derived from CveExposure rows" },
            exposure_ids: { type: "array", required: false,
                            description: "Optional list of CveExposure ids to transition to remediating" }
          },
          outputs: {
            cve_id: :string,
            triage: :object,
            refresh_dispatches: [ :object ],
            rolling_upgrade_plans: [ :object ],
            exposures_remediating: :integer,
            remediation_dispatched: :boolean,
            skipped_modules: [ :object ],
            skipped_reason: :string
          }
        )

        binds_to "CVE Responder"

        # Why a module produced no rolling-upgrade plan, most operator-
        # actionable first. The run-level `skipped_reason` is the highest-
        # priority reason present across the skipped modules, so an operator
        # reading one string is pointed at the thing they can actually do.
        #
        #   candidate_version_not_promoted — a newer version EXISTS but sits
        #     in built/staging. `newer_blessed_version_for` deliberately only
        #     accepts blessed/live: promotion is a human gate, and this
        #     executor's job is to make the gate VISIBLE, never to open it.
        #   no_enabled_template_assignment — a promoted fix exists but
        #     `templates_for` found no enabled assignment ON A NODE THAT
        #     BELONGS TO A TEMPLATE (it inner-joins node => node_template), so
        #     an enabled assignment on a template-less node lands here too.
        #   no_current_version — the module has no current_version, so
        #     "newer than current" is undefined.
        #   no_candidate_version — no newer version of any kind exists yet;
        #     a package refresh (step 2) may eventually create one.
        #   module_not_found — the id was resolved by triage but matches no
        #     NodeModule in THIS account. Without this entry such an id fell
        #     out of `find_each` and appeared in neither plans nor skips, so a
        #     wholly empty run still reported no reason at all.
        SKIP_REASON_PRIORITY = %w[
          candidate_version_not_promoted
          no_enabled_template_assignment
          no_current_version
          no_candidate_version
          module_not_found
        ].freeze

        # Promotion states a version can sit in while still being a plausible
        # fix an operator could put on the path to blessed.
        UNPROMOTED_STATES = %w[built staging].freeze

        # The forward rungs of NodeModuleVersion::PROMOTION_TRANSITIONS, used
        # to name the LEGAL next step rather than hardcoding one. `built` does
        # NOT transition straight to blessed — promote_to!("blessed") from
        # `built` raises InvalidTransition — so an operator instruction that
        # says "promote to blessed" is unfollowable from the commonest state.
        PROMOTION_LADDER = %w[staging blessed live].freeze

        protected

        def perform(cve_id:, severity: nil, affected_module_ids: nil, exposure_ids: nil)
          cve = ::System::Cve.find_by(cve_id: cve_id) if defined?(::System::Cve)
          return failure("cve not found: #{cve_id}") unless cve

          severity_norm = (severity || cve.severity).to_s.downcase
          packages = cve.normalized_affected_packages

          triage_executor = executor(::System::Ai::Skills::CveResponseExecutor)
          triage = triage_executor.execute(
            cve_id: cve_id,
            severity: severity_norm,
            affected_packages: packages.empty? ? [ { name: cve_id } ] : packages,
            summary: cve.summary
          )

          unless triage[:success]
            return failure("triage failed: #{triage[:error]}")
          end

          triage_data = triage[:data] || {}
          resolved_module_ids = resolve_module_ids(affected_module_ids, triage_data)

          refresh_dispatches = dispatch_refreshes(resolved_module_ids)
          rolling = plan_rolling_upgrades(resolved_module_ids)
          rolling_upgrade_plans = rolling[:plans]
          skipped_modules = rolling[:skipped]

          # A module counts as remediated only where something was actually
          # dispatched FOR IT. Anything else and `remediating` is a claim the
          # run cannot support (see the header note on step 4).
          remediated_module_ids = dispatched_module_ids(refresh_dispatches,
                                                        rolling_upgrade_plans)
          remediating_count = transition_exposures(cve, exposure_ids,
                                                   remediated_module_ids)

          skipped_reason = SKIP_REASON_PRIORITY.find do |reason|
            skipped_modules.any? { |m| m[:reason] == reason }
          end

          payload = {
            cve_id: cve_id,
            severity: severity_norm,
            triage: {
              risk_score: triage_data[:risk_score],
              exposed_modules: triage_data[:exposed_modules],
              exposed_instance_count: triage_data[:exposed_instance_count],
              requires_approval: triage_data[:requires_approval]
            },
            refresh_dispatches: refresh_dispatches,
            rolling_upgrade_plans: rolling_upgrade_plans,
            exposures_remediating: remediating_count,
            remediation_dispatched: remediated_module_ids.any?,
            skipped_modules: skipped_modules,
            skipped_reason: skipped_reason
          }

          # The lane dispatched NOTHING and a promotion would have unblocked
          # it: that is the one skip class an operator can clear today, so it
          # returns `failure` and the sole production caller
          # (System::CveOps::CveResponderService#dispatch_single) stamps
          # ok:false on its `cve_responder.inline_dispatch` FleetEvent instead
          # of an unqualified success over an empty run. That caller logs and
          # emits — it does not retry — so `failure` here costs no retry storm.
          # Since IMP-60717919d4a0 the caller also carries this message on
          # that event (`payload.error`, severity medium, correlated to
          # `cve_pub:<cve_id>`) and on its log line, so the string below IS
          # what an operator reads; before that it was dropped on the only
          # production path.
          # Partial progress stays `success`: something IS in flight, and the
          # blocked module is still named in skipped_modules.
          #
          # Deliberately a BARE failure. BaseSkillExecutor#failure's `**extra`
          # is the composition runner's rollback seam and its contract is
          # "only keys that actually hold ids" — a diagnostic payload passed
          # there survives strip_control_keys and would displace a retried
          # step's genuine last_outputs. Everything an operator needs is in
          # the message.
          if !payload[:remediation_dispatched] && skipped_reason == "candidate_version_not_promoted"
            return failure(promotion_blocked_message(skipped_modules))
          end

          success(payload)
        end

        private

        def resolve_module_ids(explicit_ids, triage_data)
          return Array(explicit_ids).map(&:to_s).uniq if explicit_ids.present?

          Array(triage_data[:exposed_modules]).filter_map { |m| m[:module_id]&.to_s }.uniq
        end

        def dispatch_refreshes(module_ids)
          return [] if module_ids.empty?

          refresh_executor = executor(::System::Ai::Skills::PackageModuleRefreshExecutor)

          links = ::System::PackageModuleLink
            .joins(:node_module)
            .where(system_node_modules: { account_id: @account.id, id: module_ids })

          links.map do |link|
            result = refresh_executor.execute(package_module_link_id: link.id)
            {
              node_module_id: link.node_module_id,
              package_module_link_id: link.id,
              ok: result[:success] == true,
              # The executor's own evidence that a job was queued. It succeeds
              # even when it queues nothing, so this — not `ok` — is what
              # #dispatched_module_ids may treat as remediation in flight.
              enqueued: result.dig(:data, :enqueued) == true,
              error: result[:error]
            }
          end
        end

        # Returns { plans: [...], skipped: [...] }. Every module that yields
        # no plan lands in `skipped` with a machine-readable reason — the
        # silent `next unless blessed` it replaces is what let an empty run
        # look like a completed one (IMP-9b8d774298d5).
        def plan_rolling_upgrades(module_ids)
          return { plans: [], skipped: [] } if module_ids.empty?

          rolling_executor = executor(::System::Ai::Skills::RollingModuleUpgradeExecutor)

          plans = []
          skipped = []
          seen_ids = []
          ::System::NodeModule
            .where(account: @account, id: module_ids)
            .includes(:current_version, versions: :module_artifacts)
            .find_each do |mod|
              seen_ids << mod.id
              blessed = newer_blessed_version_for(mod)
              unless blessed
                skipped << skip_entry(mod)
                next
              end

              template_ids = templates_for(mod)
              if template_ids.empty?
                skipped << skip_entry(mod, reason: "no_enabled_template_assignment",
                                           target_version_id: blessed.id)
                next
              end

              template_ids.each do |template_id|
                plan = rolling_executor.execute(
                  template_id: template_id,
                  module_id: mod.id,
                  target_version_id: blessed.id
                )
                plans << {
                  node_module_id: mod.id,
                  template_id: template_id,
                  target_version_id: blessed.id,
                  ok: plan[:success] == true,
                  # IMP-b948ea7fa382 — was batch_count, which the plan no
                  # longer returns. Module upgrades are fleet-atomic, so there
                  # is no batch count to report; total_instances below is the
                  # population that moves together. This flag is descriptive
                  # only — nothing branches on it.
                  fleet_atomic: true,
                  total_instances: plan.dig(:data, :total_instances),
                  error: plan[:error]
                }
              end
            end

          (module_ids.map(&:to_s) - seen_ids.map(&:to_s)).each do |missing_id|
            skipped << { node_module_id: missing_id, node_module_name: nil,
                         current_version_id: nil, target_version_id: nil,
                         reason: "module_not_found" }
          end

          { plans: plans, skipped: skipped }
        end

        # Classifies a module that produced no plan. When the blessed lookup
        # came up empty, name the version an operator could promote to make it
        # non-empty — "a fix is built but not promoted" and "no fix exists
        # yet" are different operator messages and must not collapse.
        def skip_entry(mod, reason: nil, target_version_id: nil)
          entry = {
            node_module_id: mod.id,
            node_module_name: mod.name,
            current_version_id: mod.current_version_id,
            target_version_id: target_version_id
          }
          return entry.merge(reason: reason) if reason

          return entry.merge(reason: "no_current_version") unless mod.current_version_id

          candidate = unpromoted_candidate_for(mod)
          return entry.merge(reason: "no_candidate_version") unless candidate

          entry.merge(
            reason: "candidate_version_not_promoted",
            candidate_version_id: candidate.id,
            candidate_version_number: candidate.version_number,
            candidate_promotion_state: candidate.promotion_state,
            # The LEGAL next rung, not the destination: from `built` the only
            # forward move is `staging`.
            next_promotion_state: next_promotion_step(candidate),
            required_promotion_state: "blessed"
          )
        end

        # Derived from the model's own transition table so it cannot drift
        # from what promote_to! will actually accept.
        def next_promotion_step(version)
          allowed = ::System::NodeModuleVersion::PROMOTION_TRANSITIONS
                      .fetch(version.promotion_state, [])
          (PROMOTION_LADDER & allowed).first
        end

        # NOT a mirror of #newer_blessed_version_for, deliberately. That
        # method's "newer" is only `where.not(id: current_version_id)` — it
        # never compares against the current version's age — which is
        # tolerable when the result is a target the operator never sees, and
        # is NOT tolerable here: this result becomes an assertive instruction
        # that names a version and fails the run. A stale `built` row left by
        # an earlier build would otherwise be surfaced as "the fix", telling
        # an operator to promote a downgrade. So this one is bounded to
        # versions created after the current one, with a deterministic
        # tiebreak for versions created in the same batch. (Narrowing this
        # lookup only; the blessed/live filter is untouched.)
        def unpromoted_candidate_for(mod)
          current = mod.current_version
          return nil unless current

          mod.versions
             .where(promotion_state: UNPROMOTED_STATES)
             .where.not(id: current.id)
             .where("system_node_module_versions.created_at > ?", current.created_at)
             .order(created_at: :desc, id: :desc)
             .first
        end

        # Modules a refresh or a rolling upgrade actually landed on. A plan or
        # dispatch that reported ok:false is NOT remediation in flight.
        #
        # `ok` alone is not enough for the refresh half: PackageModuleRefresh
        # Executor returns success whether or not it queued anything, so this
        # reads its `enqueued` output instead (see #dispatch_refreshes). Using
        # the success envelope here would have moved the false "response in
        # flight" claim from an unconditional transition into a conditional
        # one that is still always true — the same defect, better hidden.
        def dispatched_module_ids(refresh_dispatches, rolling_upgrade_plans)
          refreshed = refresh_dispatches.select { |d| d[:ok] && d[:enqueued] }
          planned   = rolling_upgrade_plans.select { |p| p[:ok] }

          (refreshed + planned).filter_map { |entry| entry[:node_module_id] }.uniq
        end

        # Operator-facing and deliberately precise about what promotion does.
        # Advancing promotion_state does NOT change which version the fleet
        # serves (NodeModule#current_version_id) — it makes
        # #newer_blessed_version_for non-nil so a LATER run of this
        # orchestration can plan the rolling upgrade that ships it. Saying
        # "promote to release the fix" would re-mint on this surface the same
        # promote-means-ship claim IMP-65bea54e4081 removed from the
        # system_promote_module_version tool description.
        def promotion_blocked_message(skipped_modules)
          blocked = skipped_modules.select { |m| m[:reason] == "candidate_version_not_promoted" }
          detail = blocked.map do |m|
            "#{m[:node_module_name]}: version #{m[:candidate_version_number]} " \
              "is #{m[:candidate_promotion_state]}, next promotion step is " \
              "#{m[:next_promotion_state] || 'none'} (version id=#{m[:candidate_version_id]})"
          end.join("; ")

          "cve remediation dispatched nothing: #{blocked.size} " \
            "#{'module'.pluralize(blocked.size)} #{blocked.size == 1 ? 'has' : 'have'} a newer " \
            "version that is not promoted to blessed/live, so no rolling upgrade can be " \
            "planned. Promoting advances promotion_state only — it does not change which " \
            "version the fleet serves; it is what lets a later run plan the upgrade. " \
            "#{detail}. Exposures left open."
        end

        # The rollout gate: "is there a fix I may ship?" Bounded to versions
        # created AFTER the served one, per the promotion-ladder decision in
        # docs/design/promotion-ladder-semantics.md — `live` is a HISTORICAL
        # stamp recording that a version was once promoted, not a statement
        # that it is fit to ship now. Without the bound, `where.not(id:
        # current_version_id)` excludes only the served row, so any older
        # `live` row falls straight through and is returned as "the fix".
        #
        # That is not hypothetical. Read from the live control plane
        # 2026-09-01, the unbounded query would have offered
        # powernode-hub-frontend v20 and reverse-proxy-traefik v13 — both
        # `live`, both `oci_digest: nil`, i.e. unmountable — as the remediation
        # for their v26/v16 current versions, and powernode-hub-backend v79 as
        # the fix for v87. Those stale `live` rows are OBSERVED; what wrote
        # them is not established (no writer enumerated in the design note's
        # section 1.2 produces that shape), which is filed there rather than
        # guessed at here. The bound does not depend on their provenance: any
        # `live` row older than what is served is a downgrade.
        #
        # This mirrors the bound #unpromoted_candidate_for already carries; the
        # comment there recorded that it left "the blessed/live filter
        # untouched", and this is that half. The filter itself is unchanged and
        # deliberately so: restricting rollout to blessed/live material is the
        # conservatism, not the bug.
        def newer_blessed_version_for(mod)
          current = mod.current_version
          return nil unless current

          mod.versions
             .where(promotion_state: %w[blessed live])
             .where.not(id: current.id)
             .where("system_node_module_versions.created_at > ?", current.created_at)
             .order(created_at: :desc, id: :desc)
             .first
        end

        def templates_for(mod)
          ::System::NodeModuleAssignment
            .joins(node: :node_template)
            .where(node_module_id: mod.id)
            .where(enabled: true)
            .distinct
            .pluck("system_node_templates.id")
        end

        # `remediated_module_ids` is the gate, not a filter, and the module
        # join is the SINGLE mechanism that enforces it: an empty list makes
        # the join match nothing, which is why there is no separate early
        # return (a redundant second guard would make the join unmutatable).
        # The join is applied ALWAYS — previously it was the `elsif` arm, so
        # an explicit exposure_ids list bypassed it entirely. A caller-supplied
        # exposure list can now narrow the set but can no longer widen it past
        # the modules that actually got a dispatch.
        #
        # IMP-2f1c8c089113 — the transition is ONE-WAY, which the step-4 note
        # in the class header ("so the dashboard reflects in-flight response")
        # understates. Nothing in the platform ever moves a row back out:
        # `System::CveExposure#resolve!` and `#remediating!` have zero callers
        # outside their own definitions
        # (`command grep -rn "resolve!" --include=*.rb server extensions/*/server worker
        # | grep -v /spec/` — 23 hits, the only CveExposure one being
        # cve_exposure.rb:23 itself), and no controller writes `state`
        # (Api::V1::System::CveExposuresController is read-only). Since
        # CvePublishedSensor selects `state: "open"` exclusively, every
        # transition here is a PERMANENT exit from that sensor's view. That is
        # tolerable only because the gate above is exact: silence is bought
        # solely for modules something was actually dispatched for.
        #
        # Audited 2026-09-02 against the live control plane: 565 exposures, all
        # `open` — zero `remediating`, `resolved` or `wont_fix` rows, so nothing
        # is parked today. A resolver (the missing #resolve! caller) is a CVE-lane
        # design change and is deliberately NOT introduced here.
        def transition_exposures(cve, explicit_ids, remediated_module_ids)
          scope = ::System::CveExposure.unresolved.where(cve: cve)
          scope = scope.where(id: explicit_ids) if explicit_ids.present?
          scope = scope.joins(node_module_version: :node_module)
                       .where(system_node_modules: { id: remediated_module_ids })

          scope.find_each.count do |exposure|
            exposure.update!(state: "remediating") if exposure.state == "open"
          end
        end
      end
    end
  end
end
