# frozen_string_literal: true

# Shared approval-gate harness for SDWAN request/service specs (IMP-b8e8e9d6e4d9).
#
# approve_latest_deferred! / seed_operator_policy! were hand-pasted across
# 9+ spec files with drift: some asserted deferred presence with a message,
# others called .tap(&:execute_now!) on a bare `.first` (a missing gate then
# fails as an uninformative `undefined method 'execute_now!' for nil`
# instead of failing by name). Extracted here in the STRICTEST existing
# form — Ai::Tools::SdwanTool's top-level copy, which already carried the
# presence assertion (see that file's comment, which named this extraction).
module SdwanApprovalGateHelpers
  # Executes the deferred operation the gate parked — the tail of the
  # approval path (Ai::ApprovalRequest ultimately calls execute_now!), not
  # the whole of it; the approval-chain hop itself is core-owned. The
  # presence assertion keeps a missing gate failing by name instead of as
  # `undefined method for nil`.
  def approve_latest_deferred!
    deferred = Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "no deferred operation was parked — the action was applied inline"
    deferred.execute_now!
  end

  # Seeds an explicit notify_and_proceed InterventionPolicy for the given
  # action_category, scoped to the enclosing example's `account`.
  #
  # Precondition: every current caller seeds exactly one policy row matching
  # a given account/action_category, so there is never a competing candidate
  # for InterventionPolicy's precedence resolution (Ai::InterventionPolicy's
  # specificity ranking, cf7528b15, is lexicographic by scope tier) to rank
  # against. That makes this helper's outcome independent of how ties are
  # broken — but only as long as that precondition holds. If a future spec
  # calls this twice for the same account/action_category (or otherwise
  # seeds a second matching row through here), the precedence rules become
  # load-bearing and need to be reasoned about explicitly rather than
  # assumed moot.
  def seed_operator_policy!(action_category)
    ::Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: nil, scope: "action_type",
      action_category: action_category, policy: "notify_and_proceed",
      priority: 5, is_active: true
    )
  end
end

RSpec.configure do |config|
  config.include SdwanApprovalGateHelpers
end
