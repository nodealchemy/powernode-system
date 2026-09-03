# frozen_string_literal: true

# Collect autonomy policy rows for categories that are no longer registered
# (IMP-0a3ff97f6fbb).
#
# WHY THIS IS A SEED OF ITS OWN. The sibling seeds each clean the rows they
# themselves declare, keyed on the SHAPE they write — agent-scoped, operator
# (scope "action_type"), or the `system.task.` global set. Two producers write
# outside all three: `System::AutonomyActions#update` mints scope "global" with
# a nil ai_agent_id whenever the Autonomy modal saves a control whose row
# identity it could not recover, and system_instance_pool_policies.rb seeds that
# same shape with no cleanup at all (the four REGISTERED-but-ungated rows it
# used to write there were collected once, by migration 20260903033000 —
# IMP-57a4b1ef94b3 — which this pass cannot reach: they are not deregistered).
# A row in that gap whose category is later
# deregistered is stranded — the modal still renders it, every save 422s on the
# unknown category, and no seed re-run removes it.
#
# So this pass is deliberately NOT another shape. It asks one question of every
# row in the extension's namespaces — is this category still registered? — which
# is the same predicate the write path enforces. A row the API refuses to write
# is a row this collects, whoever created it and at whatever scope. See
# `AgentSetupHelpers.clean_unregistered_policies!` for why that keeps a future
# row shape from opening a new orphan class, and why it cannot touch an
# operator's tuning of a registered category.
#
# Runs LAST, though it does not have to: the predicate is the boot registry
# rather than any seed's declarations, so this is order-independent. Last is
# simply where a garbage-collection pass belongs.
#
# It raises rather than warning if the registry looks unpopulated for these
# namespaces — deleting on the ABSENCE of a registration is only sound while
# that absence is trustworthy.

require_relative "concerns/agent_setup_helpers"

puts "\n  Collecting autonomy policies for deregistered categories..."

# Resolved through the helper, NOT a bare `Account.first`: that is where the six
# agent seeds write their policy rows (bootstrap_admin_context!), and a sweep
# aimed at a different account would both miss the rows it exists to collect and
# operate on somebody else's.
admin_account = System::Seeds::AgentSetupHelpers.admin_account
unless admin_account
  puts "  ⚠️  No account found — skipping orphan policy cleanup"
  return
end

owned = System::Seeds::AgentSetupHelpers::OWNED_CATEGORY_NAMESPACES

# STATE THE COUNT BEFORE THE BULK OPERATION. This deletes on the ABSENCE of a
# boot registration, so the one number that must never be inferred after the
# fact is how much it took: a registry that failed to populate and a genuine
# deregistration produce the same log line otherwise. `clean_unregistered_policies!`
# refuses outright when a namespace holds no registered category, so this pass is
# the second look rather than the only one — it makes an unexpected MAGNITUDE
# visible while the rows still exist.
doomed = Ai::InterventionPolicy
  .where(account: admin_account)
  .where.not(action_category: Ai::InterventionPolicy.registered_categories)
  .where(owned.map { "action_category LIKE ?" }.join(" OR "),
         *owned.map { |p| "#{Ai::InterventionPolicy.sanitize_sql_like(p)}%" })

if doomed.exists?
  categories = doomed.distinct.pluck(:action_category).sort
  puts "  ⚠️  #{doomed.count} policy row(s) across #{categories.size} deregistered " \
       "category(ies) will be collected: #{categories.join(', ')}"
end

destroyed = System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
  account: admin_account, owned_prefixes: owned
)

if destroyed.positive?
  puts "  🧹 Collected #{destroyed} policy row(s) for deregistered categories"
else
  puts "  ✅ No deregistered-category policy rows to collect"
end
