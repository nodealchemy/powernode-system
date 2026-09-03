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
    desc "Create declared governance policy rows this database is missing (absence only; never overwrites) and reconcile skill bindings"
    task reconcile: :environment do
      accounts = ::Account.all
      total = 0

      accounts.find_each do |account|
        result = ::System::Governance::PolicyReconciler.new(account: account).reconcile!
        total += result.created
        if result.skipped_sets.any?
          puts "  [#{account.id}] skipped #{result.skipped_sets.size}: #{result.skipped_sets.join(', ')}"
        end
        if result.shadowed.any?
          puts "  [#{account.id}] now shadowing a global row: #{result.shadowed.join(', ')}"
        end
        if result.rehomed.any?
          puts "  [#{account.id}] re-homed #{result.rehomed.size} onto their declared owner: #{result.rehomed.join(', ')}"
        end
        next unless result.changed?

        puts "  [#{account.id}] created #{result.created}: #{result.created_categories.join(', ')}" if result.created.positive?
      end

      puts(total.zero? ? "✅ Governance policies already in sync" : "✅ Governance reconcile created #{total} row(s)")

      # Skill bindings (HIER-P2G): the SkillBindings registry (every
      # executor's `binds_to`) materialised as Ai::AgentSkill rows, GLOBAL
      # skill to GLOBAL agent. Lenient — a registered skill whose row this
      # install lacks is reported, not raised; the seed is the strict caller.
      bindings = ::System::Ai::Skills::SkillBindingsReconciler.new(strict: false).reconcile!
      if bindings.registry_empty
        puts "  ⚠️  skill bindings: the SkillBindings registry loaded EMPTY (executors not loaded) — " \
             "nothing upserted and drift correction SKIPPED"
      end
      if bindings.unknown_agents.any?
        puts "  skill bindings: agents not seeded (their bindings skipped): #{bindings.unknown_agents.join(', ')}"
      end
      if bindings.missing_skills.any?
        puts "  skill bindings: registered skills with no Ai::Skill row (skipped): #{bindings.missing_skills.join(', ')}"
      end
      puts(bindings.changed? ? "✅ Skill bindings reconcile upserted #{bindings.upserted}, removed #{bindings.removed}" \
                             : "✅ Skill bindings already in sync")
    end

    desc "Report declared governance rows and skill bindings missing from this database (read-only; exits 1 on drift)"
    task drift: :environment do
      drifted = false

      ::Account.find_each do |account|
        report = ::System::Governance::PolicyReconciler.new(account: account).drift

        # Reported INDEPENDENTLY of drift: a set whose agent is absent
        # contributes no missing rows, so gating this on `drifted?` would make a
        # permanently-skipped set look exactly like a set in sync.
        if report.skipped_sets.any?
          warn "  [#{account.id}] SKIPPED #{report.skipped_sets.size}: #{report.skipped_sets.join(', ')}"
        end
        next unless report.drifted?

        drifted = true
        warn "  [#{account.id}] MISSING #{report.missing.size}: #{report.missing.join(', ')}"
      end

      bindings = ::System::Ai::Skills::SkillBindingsReconciler.new(strict: false).drift
      if bindings.registry_empty
        warn "  ⚠️  skill bindings: the SkillBindings registry loaded EMPTY (executors not loaded) — " \
             "no binding drift can be reported"
      end
      if bindings.missing_skills.any?
        warn "  skill bindings: registered skills with no Ai::Skill row: #{bindings.missing_skills.join(', ')}"
      end
      if bindings.drifted?
        drifted = true
        warn "  skill bindings MISSING #{bindings.missing.size}: #{bindings.missing.join(', ')}" if bindings.missing.any?
        warn "  skill bindings STALE #{bindings.stale.size}: #{bindings.stale.join(', ')}" if bindings.stale.any?
      end

      if drifted
        warn "❌ Governance drift detected — run `rails system:governance:reconcile`"
        exit 1
      end
      puts "✅ No governance drift"
    end
  end
end
