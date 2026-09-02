# frozen_string_literal: true

# IMP-51e5c6184ae4 — retire the DUPLICATE spelling of the architecture autonomy
# actions from running installs.
#
# system.architecture_create / _update / _delete were the DERIVED
# "<domain>.<skill name>" categories of the three gated architecture executors
# (APO-1c). The same three actions already had seeded rows under the dotted
# spelling the operator modal shows — system.architecture.create and siblings —
# so every install carried two independent controls over one behaviour. The
# executors now declare the dotted category, and the underscored names are gone
# from System::Governance::PolicyDeclarations and from the engine's registration
# list.
#
# WHY A MIGRATION AND NOT A SEED OR THE RECONCILER
#
#   * db:seed runs on FIRST BOOT ONLY (rails-start.sh marker), so nothing in
#     db/seeds reaches an install that is already up — which is every install
#     that has the rows.
#   * System::Governance::PolicyReconciler is ABSENCE-ONLY by design: it creates
#     a declared row that is missing and never updates or deletes one. Dropping
#     the declaration therefore strands the row rather than removing it.
#   * db/seeds/system_autonomy_orphan_cleanup.rb would collect them on the ADMIN
#     ACCOUNT ONLY — it resolves System::Seeds::AgentSetupHelpers.admin_account
#     and passes `account:` to both its count query and
#     #clean_unregistered_policies!, so it is not equivalent to this sweep on a
#     multi-account install — and it is a seed, so it is subject to the first
#     point regardless. The delete below is deliberately account-wide.
#
# Left alone the rows keep rendering in the Autonomy modal, where every save now
# 422s on the unregistered category (System::AutonomyActions#update checks
# `category_registered?`), and they gate nothing: the executors resolve the
# dotted category.
#
# WHAT CHANGES FOR AN OPERATOR — IN BOTH DIRECTIONS.
#
#   Losing a verb tuned on the DELETED row. Both spellings shipped at
#   require_approval and an unmatched category resolves to
#   InterventionPolicyService#default_policy — also require_approval — so
#   deleting a row still at its seeded verb changes nothing an executor
#   resolves.
#
#   Gaining a verb tuned on the SURVIVING row, which is the direction that can
#   LOOSEN a gate and is therefore the one to be loud about. Before this
#   release nothing resolved system.architecture.<verb>: the executors resolved
#   the underscored derivation, so the dotted row was operator-visible (the
#   Autonomy modal has listed it, and docs/FLEET_SENSORS.md tabulates it as a
#   Fleet Autonomy policy) but INERT. An operator who set it to auto_approve
#   believing it controlled architecture CRUD was, in fact, still gated. After
#   this release that row is the gate. So `up` reads every surviving dotted row
#   before deleting anything and says its verb, warning loudly when it is not
#   require_approval — the post-deploy verdict is a number this migration must
#   put in the record, not one an operator has to infer.
#
# Every deleted row is likewise logged with its scope and verb so the
# convergence is recoverable rather than silent.
#
# Data-only, no DDL. Idempotent: a re-run matches nothing. Not reversible —
# `down` cannot know which rows an install actually had, and re-creating them
# would re-register nothing, so it would restore un-saveable modal entries.
class RetireUnderscoredArchitectureAutonomyPolicies < ActiveRecord::Migration[8.1]
  RETIRED_CATEGORIES = %w[
    system.architecture_create
    system.architecture_update
    system.architecture_delete
  ].freeze

  # The spelling each retired row converges onto.
  SURVIVING_CATEGORIES = RETIRED_CATEGORIES.to_h { |c| [ c, c.sub("architecture_", "architecture.") ] }.freeze

  # The verb every spelling shipped at. Anything else on a surviving row is an
  # operator edit, and worth a warning rather than a `say`.
  SEEDED_POLICY = "require_approval"

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks can drift out from under it.
  class PolicyRow < ActiveRecord::Base
    self.table_name = "ai_intervention_policies"
  end

  def up
    return unless table_exists?(:ai_intervention_policies)

    disclose_surviving_gates

    doomed = PolicyRow.where(action_category: RETIRED_CATEGORIES)
    count = doomed.count

    if count.zero?
      say "No system.architecture_<verb> policy rows to retire"
      return
    end

    # STATE THE COUNT, and the verb, before the delete: this is the only record
    # of what an install had tuned on the spelling being withdrawn.
    doomed.order(:action_category, :id).each do |row|
      say "retiring #{row.action_category} (scope=#{row.scope.inspect} " \
          "agent_id=#{row.ai_agent_id.inspect} policy=#{row.policy.inspect}) — " \
          "superseded by #{SURVIVING_CATEGORIES.fetch(row.action_category)}"
    end

    doomed.delete_all
    say "Retired #{count} duplicate architecture autonomy policy row(s)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the retired rows were a duplicate spelling; re-creating them would restore " \
          "unregistered, un-saveable Autonomy modal entries"
  end

  private

  # The dotted rows resolved NOTHING before this release. Say what each one is
  # about to start enforcing, and shout when that is looser than the verb it
  # shipped at — an install that loosened an inert control is the one case where
  # this migration's release changes an approval outcome.
  def disclose_surviving_gates
    surviving = PolicyRow.where(action_category: SURVIVING_CATEGORIES.values)
                         .order(:action_category, :id)

    if surviving.count.zero?
      say "No system.architecture.<verb> rows present; the executors will resolve " \
          "InterventionPolicyService#default_policy"
      return
    end

    surviving.each do |row|
      line = "system.architecture.<verb> now GATES architecture CRUD: " \
             "#{row.action_category} = #{row.policy.inspect} " \
             "(account_id=#{row.account_id.inspect} scope=#{row.scope.inspect} " \
             "agent_id=#{row.ai_agent_id.inspect})"

      if row.policy.to_s == SEEDED_POLICY
        say line
      else
        say "WARNING: #{line} — this control was INERT before this release " \
            "(the executors resolved #{SURVIVING_CATEGORIES.key(row.action_category)}); " \
            "it is now the verb architecture CRUD runs under. Re-confirm it is intended."
      end
    end
  end
end
