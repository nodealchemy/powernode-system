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
#
# It carries the same steps as the hub image's per-boot governance-reconcile.rb
# — declared policy rows, skill bindings, canonical teams and core's
# `release.build_dispatch` floor — so the two doors converge the same rows
# rather than only the ones the boot script happens to have grown.
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

      # Core's account-wide `release.build_dispatch` FLOOR (IMP-99988ef54942).
      # The boot script's third step, mirrored here so the OPERATOR-invoked
      # door converges the same rows: an install with no hub image reaches
      # governance only through this verb, and the extension docs point
      # remediation at it. Core's own seam — this task already reconciles a
      # core reconciler (canonical teams, below) — called behind `defined?`
      # because core and the extension are separate trees that can skew by a
      # deploy. Absence-only, so a row an operator retuned survives.
      if defined?(::Ai::Engineering::ReleaseDispatchFloorSeeder)
        floors = ::Ai::Engineering::ReleaseDispatchFloorSeeder.ensure_all!
        puts(floors.zero? ? "✅ release.build_dispatch floor already in sync" \
                          : "✅ release.build_dispatch floor created #{floors} row(s)")
      else
        puts "  ⚠️  release.build_dispatch floor: core seam not present (tree skew) — skipped"
      end

      # Canonical teams (HIER-P4): the per-account materialisation of every
      # canonical Ai::TeamTemplate ("System Operations", "Platform
      # Engineering") — team, members, roles and lead repaired to the template
      # on the account's executing principals. Membership only: lineage edges
      # and delegation rows keep their writers above; a missing edge stays
      # reported by `drift` until the hierarchy seed runs.
      #
      # NOT Account.all: materialising a canonical team MINTS an account
      # principal per seat, so a walk over every account would create two teams
      # and up to twenty agent rows in every tenant on every boot. The write
      # set is the accounts that already hold a canonical team plus the primary
      # account the seeds materialise in (Ai::Teams::CanonicalTeamReconciler
      # .reconcilable_accounts). The `drift` task below still reads every account.
      team_accounts = ::Ai::Teams::CanonicalTeamReconciler.reconcilable_accounts
      puts "  canonical teams: reconciling #{team_accounts.count} of #{accounts.count} account(s) " \
           "(a tenant holding no canonical team is left untouched)"
      team_changes = 0
      team_accounts.find_each do |account|
        ::Ai::Teams::CanonicalTeamReconciler.reconcile_all!(account: account).each do |team|
          next unless team.changed? || team.skipped.any?

          team_changes += 1 if team.changed?
          puts "  [#{account.id}] team #{team.template.slug}: #{team.created ? 'materialised' : 'present'}, " \
               "+#{team.members_added} -#{team.members_removed} ~#{team.members_updated} member(s)" if team.changed?
          puts "  [#{account.id}] team #{team.template.slug} skipped #{team.skipped.size}: #{team.skipped.join(', ')}" if team.skipped.any?
        end
      end
      puts(team_changes.zero? ? "✅ Canonical teams already in sync" : "✅ Canonical teams reconciled on #{team_changes} account-team(s)")
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

      # Canonical teams (HIER-P4): where the template, the lineage forest, the
      # delegation graph and the materialised team disagree. Read-only — it
      # mints no principal (AccountPrincipalResolver.existing).
      ::Account.find_each do |account|
        ::Ai::Teams::CanonicalTeamReconciler.drift_all(account: account).each do |team|
          next unless team.drifted?

          drifted = true
          warn "  [#{account.id}] team #{team.template_slug} DRIFT:"
          warn "    absent canonicals: #{team.absent_agents.join(', ')}" if team.absent_agents.any?
          warn "    missing lineage edges: #{team.missing_edges.join(', ')}" if team.missing_edges.any?
          warn "    members the manager may not delegate to: #{team.undelegatable_members.join(', ')}" if team.undelegatable_members.any?
          warn "    manager delegate types no member carries: #{team.unrepresented_delegate_types.join(', ')}" if team.unrepresented_delegate_types.any?
          warn "    team not materialised" if team.team_absent
          warn "    missing members: #{team.missing_members.join(', ')}" if team.missing_members.any?
          warn "    extra members: #{team.extra_members.join(', ')}" if team.extra_members.any?
          warn "    role mismatches: #{team.role_mismatches.join(', ')}" if team.role_mismatches.any?
          warn "    lead mismatch" if team.lead_mismatch
        end
      end

      if drifted
        warn "❌ Governance drift detected — run `rails system:governance:reconcile`"
        exit 1
      end
      puts "✅ No governance drift"
    end
  end
end
