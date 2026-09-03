# frozen_string_literal: true

# IMP-2effedffc990 — retire the DUPLICATE spelling of the package-module create
# autonomy action from running installs. Second instance of the pair
# IMP-51e5c6184ae4 fixed for the architecture executors
# (20260902210000_retire_underscored_architecture_autonomy_policies.rb).
#
# system.package_module_create was the DERIVED "<domain>.<skill name>" category
# of System::Ai::Skills::PackageModuleCreateExecutor. The same action already
# had a seeded row under the dotted spelling the operator modal shows —
# system.package_module.create — so an install carried two independent controls
# over one supply-chain-critical behaviour. The executor now DECLARES the
# dotted category, and the underscored name is gone from
# System::Governance::PolicyDeclarations and from the engine's registration.
#
# THE ROW EXISTS ON RUNNING INSTALLS. FLEET_AUTONOMY_POLICIES declared
# "system.package_module_create" from ext commit 73f2c8f7 ("seed the fourteen
# gated-executor categories at their current default verdict"), which is an
# ancestor of origin/develop. Any install that first-booted after it, or whose
# operator ran `rake governance:reconcile` (lib/tasks/governance_reconcile.rake
# — PolicyReconciler's only call sites), has the row.
#
# WHY A MIGRATION AND NOT A SEED OR THE RECONCILER — unchanged from the
# architecture precedent:
#
#   * db:seed runs on FIRST BOOT ONLY (rails-start.sh marker), so nothing in
#     db/seeds reaches an install that is already up.
#   * System::Governance::PolicyReconciler is ABSENCE-ONLY by design: it
#     creates a declared row that is missing and never deletes one. (Since
#     HIER-P2A it has ONE update arm — the owner re-home, which rewrites
#     ai_agent_id and nothing else, and only when the declared owner of a key
#     changed. It still never touches a verb, and it cannot remove a row.)
#     Dropping the declaration strands the row rather than removing it.
#   * db/seeds/system_autonomy_orphan_cleanup.rb would collect it on the ADMIN
#     ACCOUNT ONLY, and it is a seed, so the first point applies regardless.
#     The delete below is deliberately account-wide.
#
# Left alone the row keeps rendering in the Autonomy modal, where every save
# now 422s on the unregistered category (System::AutonomyActions#update checks
# `category_registered?`), and it gates nothing: the executor resolves the
# dotted category.
#
# WHAT CHANGES FOR AN OPERATOR — IN BOTH DIRECTIONS.
#
#   Losing a verb tuned on the DELETED row. Both spellings shipped at
#   require_approval, and an unmatched category resolves to
#   Ai::InterventionPolicyService#default_policy — also require_approval — so
#   deleting a row still at its seeded verb changes no verdict.
#
#   Gaining a verb tuned on the SURVIVING row, which is the direction that can
#   LOOSEN a gate. Before this release NOTHING resolved
#   system.package_module.create. The executor resolved the underscored
#   derivation; the dotted spelling reached no other gate either — it is not in
#   System::Fleet::DecisionEngine::SIGNAL_BINDINGS (the only source of the
#   action_category both FleetAutonomyService#gate_action! call sites receive),
#   and its membership in FleetAutonomyService::ADVANCEMENT_ACTIONS only
#   selects a 4h rather than 1h approval TTL. The row was operator-VISIBLE (the
#   Autonomy modal lists it; docs/FLEET_SENSORS.md tabulates it) but INERT.
#   After this release it is the gate a supply-chain-critical skill runs under.
#   So `up` reads every surviving dotted row before deleting anything and says
#   its verb, warning loudly when it is not require_approval — the post-deploy
#   verdict is a number this migration must put in the record, not one an
#   operator has to infer.
#
# Every deleted row is likewise logged with its scope and verb so the
# convergence is recoverable rather than silent.
#
# Data-only, no DDL. Idempotent: a re-run matches nothing. Not reversible —
# `down` cannot know which rows an install actually had, and re-creating them
# would re-register nothing, so it would restore un-saveable modal entries.
class RetireUnderscoredPackageModuleAutonomyPolicy < ActiveRecord::Migration[8.1]
  RETIRED_CATEGORIES = %w[
    system.package_module_create
  ].freeze

  # The spelling each retired row converges onto.
  SURVIVING_CATEGORIES = RETIRED_CATEGORIES.to_h { |c| [ c, c.sub("package_module_", "package_module.") ] }.freeze

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

    # Disclosure runs FIRST and unconditionally: the surviving row starts
    # gating whether or not this install ever held the retired spelling.
    disclose_surviving_gates

    doomed = PolicyRow.where(action_category: RETIRED_CATEGORIES)
    count = doomed.count

    if count.zero?
      say "No system.package_module_create policy rows to retire"
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
    say "Retired #{count} duplicate package-module autonomy policy row(s)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the retired row was a duplicate spelling; re-creating it would restore " \
          "an unregistered, un-saveable Autonomy modal entry"
  end

  private

  # The dotted row resolved NOTHING before this release. Say what it is about
  # to start enforcing, and shout when that is looser than the verb it shipped
  # at — an install that loosened an inert control is the one case where this
  # release changes an approval outcome, and the action it changes it for is
  # materialising packages into the fleet.
  def disclose_surviving_gates
    surviving = PolicyRow.where(action_category: SURVIVING_CATEGORIES.values)
                         .order(:action_category, :id)

    if surviving.count.zero?
      say "No system.package_module.create row present; the executor will resolve " \
          "Ai::InterventionPolicyService#default_policy"
      return
    end

    surviving.each do |row|
      line = "system.package_module.create now GATES package module creation: " \
             "#{row.action_category} = #{row.policy.inspect} " \
             "(account_id=#{row.account_id.inspect} scope=#{row.scope.inspect} " \
             "agent_id=#{row.ai_agent_id.inspect})"

      if row.policy.to_s == SEEDED_POLICY
        say line
      else
        say "WARNING: #{line} — this control was INERT before this release " \
            "(the executor resolved #{SURVIVING_CATEGORIES.key(row.action_category)}, " \
            "and no other gate read the dotted spelling); it is now the verb a " \
            "supply-chain-critical skill runs under. Re-confirm it is intended."
      end
    end
  end
end
