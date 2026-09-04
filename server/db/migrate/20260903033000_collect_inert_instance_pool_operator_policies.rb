# frozen_string_literal: true

# IMP-57a4b1ef94b3 — collect the four INERT instance-pool operator policy rows
# from installs that booted before IMP-5a2b801f3386.
#
# POLICY_SETS "instance-pool-operator" (scope "global", ai_agent_id nil) used
# to seed every declared instance-pool category onto the operator path, while
# only four of them are passed by a gate site (InstancePoolsController:
# `_create`, `_delete`, `_ceiling_raise`, `_archive`). The other four —
# `system.instance_pool_acquire`, `_drain`, `_replenish`, `_update` — rendered
# in the Autonomy modal as controls an operator could edit that NO code path
# reads; `_drain` showed an approval requirement nothing enforced.
# IMP-5a2b801f3386 trimmed the declaration to the gated four, so those rows
# are no longer CREATED.
#
# WHY A MIGRATION AND NOT A SEED OR THE RECONCILER
#
#   * db:seed runs on FIRST BOOT ONLY (rails-start.sh marker), so the trimmed
#     seed never reaches an install that is already up — which is every
#     install that has the rows, this platform's own hub included.
#   * System::Governance::PolicyReconciler is ABSENCE-ONLY by design: it
#     creates a declared row that is missing and never deletes one. (Since
#     HIER-P2A it has ONE update arm — the owner re-home, which rewrites
#     ai_agent_id only, for a key whose declared owner changed. It never
#     touches a verb and never removes a row.) Withdrawing the declaration
#     therefore strands the rows.
#   * the seed-side operator sweep of the day
#     (System::Seeds::AgentSetupHelpers.clean_stale_operator_policies!, since
#     deleted by IMP-10e4f6c3bcd2 with the seeds' policy upserts) keyed on
#     scope "action_type"; these rows are scope "global".
#   * db/seeds/system_autonomy_orphan_cleanup.rb collects only DEREGISTERED
#     categories, and all eight instance-pool categories stay registered —
#     correctly — through the untouched Fleet Autonomy agent set.
#
# THE PREDICATE IS DELIBERATELY NARROW (operator ruling R2, 2026-09-03): a row
# is collected only when it sits at the operator shape the seed wrote — scope
# "global", ai_agent_id nil, user_id nil — for one of the four ungated
# categories AND its verb still equals the seeded default. A row whose verb an
# operator retuned is kept and named in the log: it is exactly as inert (no
# gate site reads it either way), but "still at the seeded verb" is the only
# evidence available that nobody ever meant it, and this migration does not
# guess past that. A user-bound row (user_id set) is never a seed's, so it is
# outside the predicate by construction.
#
# WHAT CHANGES FOR AN OPERATOR: nothing an executor resolves. None of the four
# categories has a gate site on the operator path, so every row here — kept or
# collected, active or deactivated — governed no decision before this
# migration and governs none after it. The Autonomy modal stops rendering the
# collected controls; the retuned ones it still renders, still inertly, until
# the verb gains a gate site (which is what puts it back on
# PolicyDeclarations::INSTANCE_POOL_OPERATOR_GATED_KEYS).
#
# Every collected row is logged with its account, scope, verb and active flag
# so the sweep is recoverable rather than silent. Data-only, no DDL.
# Idempotent: a re-run matches nothing. Not reversible — `down` cannot know
# which rows an install actually had, and re-creating them would restore the
# inert controls this migration exists to remove.
class CollectInertInstancePoolOperatorPolicies < ActiveRecord::Migration[8.1]
  # The verb each category SHIPPED at on the operator path. Pinned as a
  # literal rather than read from PolicyDeclarations::INSTANCE_POOL_POLICIES:
  # the declaration can move after this migration has run, and the predicate
  # must describe what the seed WROTE, not what it declares today.
  INERT_OPERATOR_CATEGORIES = {
    "system.instance_pool_acquire"   => "auto_approve",
    "system.instance_pool_drain"     => "require_approval",
    "system.instance_pool_replenish" => "auto_approve",
    "system.instance_pool_update"    => "notify_and_proceed"
  }.freeze

  # The shape db/seeds/system_instance_pool_policies.rb wrote for the manual
  # scope (its find_or_initialize_by identity, minus the account).
  OPERATOR_SHAPE = { scope: "global", ai_agent_id: nil, user_id: nil }.freeze

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks can drift out from under it.
  class PolicyRow < ActiveRecord::Base
    self.table_name = "ai_intervention_policies"
  end

  def up
    return unless table_exists?(:ai_intervention_policies)

    candidates = PolicyRow.where(action_category: INERT_OPERATOR_CATEGORIES.keys, **OPERATOR_SHAPE)
                          .order(:action_category, :id)

    doomed_ids = []

    # STATE THE COUNT, and each row, before the delete: this is the only record
    # of what an install had at the shape being withdrawn.
    candidates.each do |row|
      seeded = INERT_OPERATOR_CATEGORIES.fetch(row.action_category)
      where  = "(account_id=#{row.account_id.inspect} scope=#{row.scope.inspect} " \
               "agent_id=#{row.ai_agent_id.inspect} is_active=#{row.is_active})"

      if row.policy.to_s == seeded
        say "collecting #{row.action_category} #{where} policy=#{row.policy.inspect} — " \
            "still at the seeded verb; no gate site reads it"
        doomed_ids << row.id
      else
        say "KEEPING #{row.action_category} #{where} policy=#{row.policy.inspect} differs from " \
            "seeded #{seeded.inspect} — operator-tuned, so left in place; " \
            "note it is still inert: no gate site reads it"
      end
    end

    if doomed_ids.empty?
      say "No inert instance-pool operator policy rows to collect"
      return
    end

    PolicyRow.where(id: doomed_ids).delete_all
    say "Collected #{doomed_ids.size} inert instance-pool operator policy row(s)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the collected rows were operator controls no gate site reads; this migration " \
          "cannot know which rows an install had, and re-creating them would restore " \
          "inert Autonomy modal entries"
  end
end
