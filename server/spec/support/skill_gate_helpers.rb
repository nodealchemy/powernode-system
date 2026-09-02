# frozen_string_literal: true

# Approval-gate harness for skill-executor specs (APO-1c, IMP-7e2bdc1774e4).
#
# `requires_approval: true` on a skill descriptor used to be inert — the flag
# was declared by 14 executors and read by nobody, so a spec could call
# `described_class.new(...).execute(...)` and land straight in #perform.
# BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE #perform,
# and an unconfigured category resolves to Ai::InterventionPolicyService
# #default_policy — "require_approval" — so those calls now park an approval
# instead of performing.
#
# A spec exercising an executor's #perform therefore has to say which side of
# the gate it is on. Two honest ways to do that, both here:
#
#   auto_execute_skill_policy!  — an operator has tuned this action to run
#                                 automatically. Use it for specs about what
#                                 #perform DOES; the gate still runs, it just
#                                 resolves to proceed, so a spec keeps
#                                 exercising the real entry point.
#   `execute(gated: true, ...)` — the caller already resolved policy itself.
#                                 That is System::Fleet::DecisionEngine's
#                                 contract, not a general test escape hatch;
#                                 use it only where the spec is standing in for
#                                 the tick loop.
#
# Deliberately NOT a global default: a blanket auto-approve in the test env
# would hide the gate from every spec written after this one, which is the
# state this increment exists to end.
module SkillGateHelpers
  # Seeds an auto_approve policy for each executor class's own action_category.
  #
  # Scope "global" rather than "action_type" so ONE call covers both audiences:
  # Ai::InterventionPolicyService cuts an agent caller down to its own rows plus
  # the scope-"global" audience, so an "action_type" row would silently not
  # match a spec that passes `agent:`.
  #
  # The category is read from the executor (`.action_category`), never spelled
  # as a literal — a rename of the skill moves the seeded row with it instead of
  # leaving a row that matches nothing and a spec that gates by surprise.
  def auto_execute_skill_policy!(account, *executor_classes)
    executor_classes.flatten.map do |klass|
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: nil, scope: "global",
        action_category: klass.action_category, policy: "auto_approve",
        priority: 5, is_active: true
      )
    end
  end
end

RSpec.configure do |config|
  config.include SkillGateHelpers
end
