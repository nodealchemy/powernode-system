# frozen_string_literal: true

# Governance policy reconciliation.
#
# `db:seed` is FIRST-BOOT ONLY (rails-start.sh gates it behind a durable
# `.db-initialized` marker), so governance rows added to a seed after an
# install's first boot never reach it. These tasks close that gap WITHOUT
# re-running the seed, which is destructive on an established install — it
# resets tuned verbs and destroy_all's unlisted rows.
#
# Intended wiring: `system:governance:reconcile` runs on EVERY boot in
# rails-start.sh, immediately after `db:migrate`, in both the first-boot and
# the already-initialized branches. It is idempotent and creates absence only.
namespace :system do
  namespace :governance do
    desc "Create declared governance policy rows this database is missing (absence only; never overwrites)"
    task reconcile: :environment do
      accounts = ::Account.all
      total = 0

      accounts.find_each do |account|
        result = ::System::Governance::PolicyReconciler.new(account: account).reconcile!
        total += result.created
        next unless result.changed?

        puts "  [#{account.id}] created #{result.created}: #{result.created_categories.join(', ')}"
      end

      puts(total.zero? ? "✅ Governance policies already in sync" : "✅ Governance reconcile created #{total} row(s)")
    end

    desc "Report declared governance rows missing from this database (read-only; exits 1 on drift)"
    task drift: :environment do
      drifted = false

      ::Account.find_each do |account|
        report = ::System::Governance::PolicyReconciler.new(account: account).drift
        next unless report.drifted?

        drifted = true
        warn "  [#{account.id}] MISSING #{report.missing.size}: #{report.missing.join(', ')}"
      end

      if drifted
        warn "❌ Governance drift detected — run `rails system:governance:reconcile`"
        exit 1
      end
      puts "✅ No governance drift"
    end
  end
end
