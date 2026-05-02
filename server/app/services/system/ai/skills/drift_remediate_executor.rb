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
      # Auto-apply + ApprovalRequest gating lives in M7 (FleetAutonomyService);
      # this executor produces the *plan* an autonomy reconciler can act on.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (drift_remediate row).
      class DriftRemediateExecutor
        # Per-change disruption budget. Used to estimate impact: 5 changes ≈
        # 100% disruption (the linear model is a stand-in until we have real
        # operational data; M7 will tune this with PromotionCriteria-style
        # weighting).
        DISRUPTION_PER_CHANGE_PCT = 20

        # Static descriptor that gets seeded into ai_skills via
        # System::Ai::Skills::Seeder (TODO: ship as part of M6 seeds task).
        def self.descriptor
          {
            name: "drift_remediate",
            description: "Reconcile a NodeInstance's running modules against its assigned modules; returns a planned action set + estimated disruption %",
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
              planned_actions: { attach: [:string], detach: [:string], update: [:string] }
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(instance_id:, max_disruption_pct: 20)
          tool = ::Ai::Tools::SystemFleetTool.new(account: @account, agent: @agent, user: @user)

          drift = tool.execute(params: { action: "system_drift_report", instance_id: instance_id })
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

          success(
            resolved: !requires_approval,
            requires_approval: requires_approval,
            disruption_pct: disruption,
            planned_actions: planned_actions_from(report),
            note: requires_approval ? "disruption_pct exceeds max_disruption_pct; gated until M7 ApprovalRequest wiring" : "auto-apply pending M7 reconciler",
            drift_report: report
          )
        rescue StandardError => e
          Rails.logger.error("[DriftRemediateExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def compute_disruption_pct(report)
          total = report[:missing_count].to_i + report[:extra_count].to_i + report[:mismatched_count].to_i
          return 0 if total.zero?

          [total * DISRUPTION_PER_CHANGE_PCT, 100].min
        end

        def planned_actions_from(report)
          {
            attach: Array(report[:missing]).map { |k, _| k.to_s },
            detach: Array(report[:extra]).map { |k, _| k.to_s },
            update: Array(report[:mismatched]).map { |k, _| k.to_s }
          }
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
