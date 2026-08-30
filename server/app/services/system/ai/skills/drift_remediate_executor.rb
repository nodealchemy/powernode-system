# frozen_string_literal: true

module System
  module Ai
    module Skills
      # First Golden Eclipse AI Skill (M6.A). Composes M5's MCP tool surface
      # to compute drift between a NodeInstance's running modules and its
      # assigned modules, then either:
      #   - reports "no drift" if running matches assigned, OR
      #   - returns a planned action set with an estimated disruption %
      #
      # IMP-b948ea7fa382 — THIS EXECUTOR APPLIES NOTHING. Every path through
      # #perform calls system_drift_report and formats the result; there is no
      # write anywhere in the class. It nonetheless returned
      # `resolved: !requires_approval`, so any drift at or under
      # max_disruption_pct was announced as RESOLVED, next to a `note` on the
      # same line saying auto-apply was still waiting on the reconciler that
      # milestone M7 was supposed to deliver — the truth, deferred to
      # infrastructure that was never built, in a key nothing reads.
      # `resolved` now means what its name says: true only when there was
      # nothing to do.
      #
      # What DOES converge the drift is downstream and invisible from here —
      # which is precisely why this executor cannot report on it. Three
      # DecisionEngine SIGNAL_BINDINGS invoke this class, and NONE of them
      # applies the plan it returns:
      #   - system.module_drift and system.config_drift route to
      #     REMEDIATION_APPLIERS -> #dispatch_reconcile_task, which re-reads
      #     THIS result's `requires_approval` as an auto-apply budget and,
      #     under it, creates a System::Task (`sync_modules` / `apply_config`
      #     respectively). Convergence is the on-node agent's and is reported
      #     by the task, not by this return.
      #   - system.instance_silent routes to #reboot_silent_instance, which
      #     takes `_skill_result` and ignores it.
      #
      # Do not read that first bullet as "the plan gets executed". The task
      # options carry `planned_actions`, but NOTHING READS THEM: the agent's
      # sync handler (agent/internal/runtime/tasks/handlers/config.go) takes
      # only force_resync and module_id and then calls Reconciler.RunOnce,
      # which re-derives the desired set on-node from scratch. The same drift
      # converges, by the same generic reconcile the 60s tick runs; this
      # executor's action list rides along unread. It is a plan for an
      # operator and for the ApprovalRequest, not an instruction to anything.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (drift_remediate row).
      class DriftRemediateExecutor < BaseSkillExecutor
        # Per-change disruption budget. Used to estimate impact: 5 changes ≈
        # 100% disruption. The linear model is what ships: nothing weights it
        # by module, by change kind, or by PromotionCriteria, and no caller
        # overrides the constant — only the max_disruption_pct THRESHOLD it is
        # compared against is an input.
        DISRUPTION_PER_CHANGE_PCT = 20

        skill_descriptor(
          name: "drift_remediate",
          # The description is what an AGENT reads BEFORE calling, so the
          # plan/apply split has to be stated HERE too — correcting it only in
          # the class doc teaches a human and leaves the agent surface lying.
          # Same reasoning as RollingModuleUpgradeExecutor's descriptor
          # (IMP-e8dc40813adb), and purely additive truth-telling: it disables
          # no mechanism. docs/SKILL_EXECUTOR_CATALOG.md is generated from
          # this, so regenerate it (rails system:skills:generate_catalog)
          # whenever this string changes.
          description: "Compare a NodeInstance's running modules against its assigned modules; returns a planned action set + estimated disruption %. PLANS ONLY — it applies nothing, so `resolved` is true only when there was no drift to apply",
          category: "devops",
          inputs: {
            instance_id: { type: "string", required: true,
                           description: "NodeInstance to reconcile" },
            max_disruption_pct: { type: "integer", required: false, default: 20,
                                  description: "Disruption threshold above which the skill returns requires_approval=true" }
          },
          outputs: {
            resolved: :boolean,
            requires_approval: :boolean,
            disruption_pct: :integer,
            planned_actions: { attach: [ :string ], detach: [ :string ], update: [ :string ] }
          }
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(instance_id:, max_disruption_pct: 20)
          drift = tool(::Ai::Tools::SystemFleetTool).execute(
            params: { action: "system_drift_report", instance_id: instance_id }
          )
          return failure("drift_report failed: #{drift[:error]}") unless drift[:success]

          report = drift[:data]
          unless report[:drift]
            return success(
              resolved: true,
              requires_approval: false,
              disruption_pct: 0,
              planned_actions: { attach: [], detach: [], update: [] },
              reason: "no drift"
            )
          end

          disruption = compute_disruption_pct(report)
          requires_approval = disruption > max_disruption_pct.to_i

          # `resolved` is false on this whole arm. Drift was found and this
          # executor did not remove any of it; whether the lane goes on to
          # dispatch a sync_modules task is decided after this returns (see
          # the class doc). The no-drift arm above keeps resolved: true — the
          # discriminator is whether there was drift, not whether an operator
          # is asked, which is what `!requires_approval` got wrong.
          success(
            resolved: false,
            requires_approval: requires_approval,
            disruption_pct: disruption,
            planned_actions: planned_actions_from(report),
            note: if requires_approval
                    "plan only, nothing applied: disruption_pct exceeds max_disruption_pct, so an operator must approve before the lane may dispatch"
                  else
                    "plan only, nothing applied: within the auto-apply budget, so the fleet lane may dispatch a sync_modules task for these actions"
                  end,
            drift_report: report
          )
        end

        private

        def compute_disruption_pct(report)
          total = report[:missing_count].to_i + report[:extra_count].to_i + report[:mismatched_count].to_i
          return 0 if total.zero?

          [ total * DISRUPTION_PER_CHANGE_PCT, 100 ].min
        end

        def planned_actions_from(report)
          {
            attach: Array(report[:missing]).map { |k, _| k.to_s },
            detach: Array(report[:extra]).map { |k, _| k.to_s },
            update: Array(report[:mismatched]).map { |k, _| k.to_s }
          }
        end
      end
    end
  end
end
