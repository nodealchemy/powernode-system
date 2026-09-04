# frozen_string_literal: true

# Install the declared intervention-policy rows — the LAST step of the system
# extension's seed run (IMP-10e4f6c3bcd2, proposal §5 ruling 7).
#
# WHY THIS SEED EXISTS. Ruling 7 makes System::Governance::PolicyReconciler the
# single writer of declared rows, so every agent seed's `upsert_policies!` and
# all four policy-only seeds were deleted. That removed the ONLY writer that
# `rails db:seed` reached: `governance-reconcile.rb` runs from rails-start.sh
# and so exists only on a module-composed hub image, and
# `rails system:governance:reconcile` is a manual verb. Every other documented
# install path — docs/getting-started/01-quickstart.md,
# docs/operations/production-deployment.md,
# docs/operations/single-node-bootstrap.md,
# docs/contributing/development-setup.md — runs `db:seed` alone, and would have
# come up with ZERO declared rows. Absence is not neutral: the gate then
# resolves every verb through Ai::InterventionPolicyService's require_approval
# default, and a DecisionEngine-routed lane blocks every signal with only a
# WARN (see the PolicyReconciler class header).
#
# This does NOT reintroduce a second writer. The reconciler still performs the
# only write; this file just calls it on the install path that used to get its
# rows from the seeds. It is absence-only and idempotent, so re-running
# `db:seed` on an established install neither resets a tuned verb nor deletes
# anything — which is exactly what the retired seed upserts could not promise.
#
# LAST in SYSTEM_SEED_FILES, and pinned there by
# spec/db/seeds/policy_single_writer_spec.rb: it resolves an acting principal
# for every declared agent (HIER-P2I), so every agent seed above must already
# have run. Failure is non-fatal per account, matching the hub runner — one bad
# account must not cost the rest their rows.
puts "🛡  Governance policy reconcile (declared rows; absence only)…"

accounts = 0
created_total = 0
failed = []

Account.find_each do |account|
  accounts += 1
  result = System::Governance::PolicyReconciler.new(account: account).reconcile!
  created_total += result.created

  puts "   [#{account.name}] created #{result.created}: #{result.created_categories.join(', ')}" if result.created.positive?
  puts "   [#{account.name}] skipped #{result.skipped_sets.size}: #{result.skipped_sets.join(', ')}" if result.skipped_sets.any?
  puts "   [#{account.name}] re-homed #{result.rehomed.size} onto their declared owner: #{result.rehomed.join(', ')}" if result.rehomed.any?
rescue StandardError => e
  # One bad account must not stop the rest (same rule as the boot runner).
  failed << account.id
  Rails.logger.error("[system seeds] policy reconcile failed for account #{account.id}: #{e.class}: #{e.message}")
  puts "   ❌ [#{account.name}] reconcile failed: #{e.class}: #{e.message}"
end

puts "   ✅ #{accounts} account(s), #{created_total} declared row(s) created, #{failed.size} failed"
