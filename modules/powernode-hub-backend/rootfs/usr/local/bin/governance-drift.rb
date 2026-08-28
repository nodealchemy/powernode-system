# frozen_string_literal: true

# READ-ONLY governance drift report. Mutates nothing.
#
#   powernode-runner /usr/local/bin/governance-drift.rb
#
# WHY A SCRIPT AND NOT THE RAKE TASK. `system:governance:drift` exists in the
# extension (server/lib/tasks/governance_reconcile.rake) and works in
# development, but NO extension rake task registers on a deployed hub:
# powernode_system is absent from the shipped Gemfile.lock, so Bundler never
# locks it as a path gem and the engine's rake tasks are never loaded. The
# extension's CODE still runs — only its rake tasks are missing. Verified on
# ops-hub 2026-08-28: `rake -T` lists 151 tasks, every `system:*` one of them
# from CORE, and none of the extension's own namespaces (powernode:, rcp:,
# sdwan:, system:governance:, system:catalog:, system:fleet:, system:worker:).
#
# Fixing that means changing how the build locks extension gems. Until then the
# capability ships through the channel that demonstrably works on this host —
# the same one governance-reconcile.rb uses at boot.
#
# Exits 1 on drift so it can gate a script, matching the rake task.
begin
  unless defined?(::System::Governance::PolicyReconciler)
    warn "[governance-drift] system extension not loaded — nothing to report"
    exit 0
  end

  drifted = false

  Account.find_each do |account|
    report = ::System::Governance::PolicyReconciler.new(account: account).drift

    # Reported INDEPENDENTLY of drift: a set whose agent row is absent
    # contributes no MISSING rows precisely because it was never examined, so
    # gating this on drifted? would make a permanently-skipped set look exactly
    # like a set in sync.
    if report.skipped_sets.any?
      warn "  [#{account.id}] SKIPPED #{report.skipped_sets.size}: #{report.skipped_sets.join(', ')}"
    end

    next unless report.drifted?

    drifted = true
    by_set = report.missing.group_by(&:set_key)
    warn "  [#{account.id}] MISSING #{report.missing.size} across #{by_set.size} set(s)"
    by_set.each do |set_key, rows|
      warn "    #{set_key}: #{rows.size} — #{rows.map(&:action_category).join(', ')}"
    end
  end

  if drifted
    warn "❌ Governance drift detected — run /usr/local/bin/governance-reconcile.rb (or restart the backend)"
    exit 1
  end

  puts "✅ No governance drift"
  exit 0
rescue StandardError => e
  warn "[governance-drift] failed: #{e.class}: #{e.message}"
  exit 2
end
