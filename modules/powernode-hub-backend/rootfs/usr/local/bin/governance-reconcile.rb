# frozen_string_literal: true

# Boot-time governance policy reconcile (IMP-d02b258eb303). Run by
# rails-start.sh right after the schema-drift backstop. Creates the declared
# governance rows an account is MISSING (System::Governance::PolicyReconciler is
# absence-only: it never updates a verb and never deletes), then reconciles
# the agent ↔ skill bindings from the SkillBindings registry (HIER-P2G,
# System::Ai::Skills::SkillBindingsReconciler — upserts declared pairs,
# removes undeclared ones on registry agents), then lands CORE's account-wide
# engineering floors (release.build_dispatch and the two refine categories —
# the seam's CATEGORIES) through Ai::Engineering::ReleaseDispatchFloorSeeder
# behind a `defined?` probe (IMP-99988ef54942 — absence-only; a core tree
# without the seam is a named skip, never a boot failure), then attaches the
# AGENT HIERARCHY (HIER-P1, IMP-01a089d3 — System::Governance::HierarchyReconciler
# over the teams pass's accounts), and finally
# reconciles the CANONICAL TEAMS (HIER-P4, IMP-01a06cd4 —
# Ai::Teams::CanonicalTeamReconciler, membership only, over
# `reconcilable_accounts` rather than every account).
#
# FIVE PASSES, matching `rails system:governance:reconcile`
# (extensions/system/server/lib/tasks/governance_reconcile.rake) step for step.
# That task's header has always claimed the two doors carry the same steps; it
# grew the team pass and this file did not, so until IMP-01a06cd4 the claim was
# false and a drifted canonical team was repaired only by an operator running
# the task by hand. Keep them in step: a pass added to one belongs in the other.
#
# WHY AT BOOT: `db:seed` is first-boot only (rails-start.sh gates it behind the
# durable .db-initialized marker), so a policy row added to a seed after an
# install's first boot never reaches that install. Measured on live ops-hub
# 2026-08-24: nine such rows had never landed.
#
# Advisory only, exactly like schema-drift-check.rb: it ALWAYS prints a summary
# line (the positive per-boot execution artifact — its ABSENCE from the journal
# is how you tell "wired and running" from "wired and silently skipped"), emits
# a System::FleetEvent on failure, and NEVER raises. Invoked with `|| true` and
# guarded here so a reconciler bug cannot brick a sole control plane.
begin
  unless defined?(::System::Governance::PolicyReconciler)
    # A hub booting without the system extension is a supported configuration;
    # hub-backend must not hard-depend on it.
    warn "[governance-reconcile] system extension not loaded — skipping"
  else
    accounts = 0
    created_total = 0
    present_total = 0
    created_by_account = {}
    skipped_by_account = {}
    shadowed_by_account = {}
    rehomed_by_account = {}
    failed = []

    Account.find_each do |account|
      accounts += 1
      begin
        result = ::System::Governance::PolicyReconciler.new(account: account).reconcile!
        created_total += result.created
        present_total += result.already_present
        created_by_account[account.id] = result.created_categories if result.changed?
        skipped_by_account[account.id] = result.skipped_sets if result.skipped_sets.any?
        shadowed_by_account[account.id] = result.shadowed if result.shadowed.any?
        rehomed_by_account[account.id] = result.rehomed if result.rehomed.any?
      rescue StandardError => e
        # One bad account must not stop the rest.
        failed << { account_id: account.id, error: "#{e.class}: #{e.message}" }
        warn "[governance-reconcile] account #{account.id} failed (non-fatal): #{e.class}: #{e.message}"
      end
    end

    created_by_account.each do |account_id, categories|
      warn "[governance-reconcile]   account #{account_id} created: #{categories.join(', ')}"
    end

    # A re-homed row MOVED agent (HIER-P2A): its declared owner changed and
    # the reconciler updated ai_agent_id in place, verb and tuning preserved,
    # with an AuditLog row. Named per row because it is the one mutation here
    # that touches an existing row an operator may have tuned.
    rehomed_by_account.each do |account_id, rows|
      warn "[governance-reconcile]   account #{account_id} re-homed onto declared owner: #{rows.join(', ')}"
    end

    # A skipped set is a whole policy group NOT reconciled — most likely its
    # agent row is absent. Named per set, because a set that skips forever is
    # indistinguishable from one that is in sync unless it says so.
    skipped_by_account.each do |account_id, sets|
      warn "[governance-reconcile]   account #{account_id} SKIPPED: #{sets.join(', ')}"
    end

    # A skipped set is an UNRECONCILED set, and the usual cause is that the
    # agents were never seeded — an install that enabled this extension after
    # its first boot. That state is permanent until someone acts, and a journal
    # line nobody alerts on is not a report. Emit the same way a failure does.
    if skipped_by_account.any?
      begin
        account = Account.first
        if account && defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account_id: account.id,
            kind: "governance_reconcile_skipped",
            severity: "medium",
            source: "governance_policy_reconciler",
            payload: {
              skipped: skipped_by_account,
              accounts_scanned: accounts,
              detected_at: Time.current.utc.iso8601
            }
          )
          warn "[governance-reconcile] emitted System::FleetEvent(kind=governance_reconcile_skipped, severity=medium)"
        end
      rescue StandardError => e
        warn "[governance-reconcile] skip-event emission failed (non-fatal): #{e.class}: #{e.message}"
      end
    end

    # Creating an agent-scoped row where a global row already exists changes
    # what an agent caller resolves, without this run touching the global row
    # (agent out-ranks global on specificity at any priority). Not an error —
    # but it is the one mutation here that nobody can see from the row we wrote.
    shadowed_by_account.each do |account_id, categories|
      warn "[governance-reconcile]   account #{account_id} now shadowing a global row: #{categories.join(', ')}"
    end

    # Skill bindings (HIER-P2G). The SkillBindings registry — every executor's
    # `binds_to` — materialised as Ai::AgentSkill rows, GLOBAL skill to GLOBAL
    # agent. Same reason as the policies above: db:seed is first-boot only, so
    # an executor re-bound after an install's first boot never reached it
    # (HIER-P2B: no boot-time reconciler re-materialised Ai::AgentSkill).
    # Lenient: a registered skill whose Ai::Skill row this install lacks is
    # named and skipped, never raised. ALWAYS prints its own summary line.
    begin
      bindings = ::System::Ai::Skills::SkillBindingsReconciler.new(strict: false).reconcile!
      warn "[governance-reconcile] skill-bindings upserted=#{bindings.upserted} removed=#{bindings.removed} " \
           "missing_skills=#{bindings.missing_skills.size} unknown_agents=#{bindings.unknown_agents.size}"
      if bindings.registry_empty
        warn "[governance-reconcile]   skill-bindings: registry loaded EMPTY (executor files not found) — " \
             "nothing upserted and drift correction SKIPPED (never an unbind-everything instruction)"
      end
      if bindings.missing_skills.any?
        warn "[governance-reconcile]   skill-bindings: no Ai::Skill row for #{bindings.missing_skills.join(', ')} " \
             "(the skill catalog seeds never ran here — the bindings were skipped)"
      end
      if bindings.unknown_agents.any?
        warn "[governance-reconcile]   skill-bindings: agents not seeded: #{bindings.unknown_agents.join(', ')}"
      end
    rescue StandardError => e
      failed << { account_id: "(skill-bindings)", error: "#{e.class}: #{e.message}" }
      warn "[governance-reconcile] skill-bindings reconcile failed (non-fatal): #{e.class}: #{e.message}"
    end

    # Core's account-wide engineering FLOORS (HIER-P2B-ENG, IMP-99988ef54942;
    # release.build_dispatch and, since IMP-a51963f8717f, dev.prompt_refine and
    # dev.skill_refine — the seam's CATEGORIES is the authority, and a category
    # added there lands here on the next boot). Those verbs are gate-routed and
    # the principals that call them over MCP (an operator's mcp_client session,
    # a dev-cell instance principal) match no agent-scoped row, so without the
    # floors every such call parks behind the require_approval default. Core
    # writes them from its engineering seed — first boot only — and exposes
    # the same absence-only seam for an ESTABLISHED install; until this step
    # nothing at boot called it, and the row had to be landed by hand after a
    # deploy. `defined?` because hub-backend and the core
    # tree are separate modules that can skew by one deploy: an older core has
    # no seam, and that is a named skip, not a boot failure. Absence-only and
    # never destructive, like every other write in this file. ALWAYS prints its
    # own summary line, written=0 in the steady state.
    if defined?(::Ai::Engineering::ReleaseDispatchFloorSeeder)
      begin
        floors_written = ::Ai::Engineering::ReleaseDispatchFloorSeeder.ensure_all!
        warn "[governance-reconcile] engineering-floors written=#{floors_written} accounts=#{accounts}"
      rescue StandardError => e
        failed << { account_id: "(engineering-floors)", error: "#{e.class}: #{e.message}" }
        warn "[governance-reconcile] engineering-floors ensure failed (non-fatal): #{e.class}: #{e.message}"
      end
    else
      warn "[governance-reconcile] engineering-floors: core seam not present (module skew) — skipped"
    end

    # Agent hierarchy (HIER-P1, IMP-01a089d3). Every declared system agent's
    # lineage edge under System Concierge, plus the delegation rows that go
    # with it (System::Governance::HierarchyReconciler). Same reason as every
    # pass above: its only writer was db/seeds/system_agent_hierarchy.rb, and
    # `db:seed` is first-boot only, so an identity declared after an install's
    # first boot never got its edge unless a governance-gap offer was
    # materialised by hand. Edges are effectively GLOBAL (a unique parent/child
    # index); the per-account half is the delegation rows, so the write set is
    # the canonical-teams pass's `reconcilable_accounts`, never every tenant.
    # It runs BEFORE that pass because a team's manager delegates along these
    # rows. `drift` taken first names the edges this boot actually attached.
    # ALWAYS prints its own summary line, attached=0 policies_written=0 in the
    # steady state.
    if defined?(::Ai::Teams::CanonicalTeamReconciler)
      begin
        hier_accounts = ::Ai::Teams::CanonicalTeamReconciler.reconcilable_accounts
        hier_attached = 0
        hier_written = 0
        hier_skipped = 0
        hier_accounts.find_each do |account|
          hierarchy = ::System::Governance::HierarchyReconciler.new(account: account)
          missing_edges = hierarchy.drift.missing_edges
          result = hierarchy.reconcile!
          hier_attached += missing_edges.size
          hier_written += result.policies_written
          hier_skipped += result.skipped.size
          if missing_edges.any?
            warn "[governance-reconcile]   account #{account.id} hierarchy attached: #{missing_edges.join(', ')}"
          end
          if result.skipped.any?
            # A declared identity this install never seeded: permanent until
            # someone acts, so it is named, like a skipped policy set.
            warn "[governance-reconcile]   account #{account.id} hierarchy SKIPPED (agent absent): " \
                 "#{result.skipped.join(', ')}"
          end
        end
        warn "[governance-reconcile] hierarchy accounts=#{hier_accounts.count} attached=#{hier_attached} " \
             "policies_written=#{hier_written} skipped=#{hier_skipped}"
      rescue StandardError => e
        failed << { account_id: '(hierarchy)', error: "#{e.class}: #{e.message}" }
        warn "[governance-reconcile] hierarchy reconcile failed (non-fatal): #{e.class}: #{e.message}"
      end
    else
      warn '[governance-reconcile] hierarchy: core teams seam not present (module skew) — skipped'
    end

    # Canonical teams (HIER-P4, IMP-01a06cd4). The per-account materialisation
    # of every canonical Ai::TeamTemplate ("System Operations", "Platform
    # Engineering") — team, members, roles and lead repaired to the template on
    # the account's EXECUTING PRINCIPALS (ruling 8). Membership only: lineage
    # edges and delegation rows keep their own writer (the hierarchy pass above).
    #
    # Same reason as every pass above: `db:seed` is first-boot only, so a seat
    # added to a team seed after an install's first boot — or a seat an operator
    # removed by hand — was converged ONLY by someone running
    # `rails system:governance:reconcile`. That task has carried this pass since
    # HIER-P4 and its own header claimed the boot runner did too; it did not,
    # and the two doors are now the same four steps.
    #
    # NOT Account.all. Materialising a canonical team MINTS an account principal
    # per seat, so a walk over every account would create two teams and up to
    # twenty agent rows in every tenant on every boot. The write set is
    # `reconcilable_accounts` — the accounts that already hold a canonical team,
    # plus the primary account the seeds materialise in — exactly the set the
    # rake task writes. `drift` stays free to read every account.
    #
    # `defined?` because hub-backend and the core tree are separate modules that
    # can skew by one deploy, like the engineering floors above. ALWAYS prints
    # its own summary line, changed=0 in the steady state.
    if defined?(::Ai::Teams::CanonicalTeamReconciler)
      begin
        team_accounts = ::Ai::Teams::CanonicalTeamReconciler.reconcilable_accounts
        team_changed = 0
        team_skipped = 0
        team_accounts.find_each do |account|
          ::Ai::Teams::CanonicalTeamReconciler.reconcile_all!(account: account).each do |team|
            if team.changed?
              team_changed += 1
              warn "[governance-reconcile]   account #{account.id} team #{team.template.slug}: " \
                   "#{team.created ? 'materialised' : 'present'}, +#{team.members_added} " \
                   "-#{team.members_removed} ~#{team.members_updated} member(s)"
            end
            next if team.skipped.empty?

            # A skipped seat is a seat the template declares that this install
            # cannot fill — its canonical is absent. Named for the same reason a
            # skipped policy set is: permanent until someone acts.
            team_skipped += team.skipped.size
            warn "[governance-reconcile]   account #{account.id} team #{team.template.slug} " \
                 "SKIPPED seat(s): #{team.skipped.join(', ')}"
          end
        end
        warn "[governance-reconcile] canonical-teams accounts=#{team_accounts.count} " \
             "changed=#{team_changed} skipped_seats=#{team_skipped}"
      rescue StandardError => e
        failed << { account_id: "(canonical-teams)", error: "#{e.class}: #{e.message}" }
        warn "[governance-reconcile] canonical-teams reconcile failed (non-fatal): #{e.class}: #{e.message}"
      end
    else
      warn "[governance-reconcile] canonical-teams: core seam not present (module skew) — skipped"
    end

    # ALWAYS printed, including the created=0 steady state — the one line an
    # operator greps. It CLOSES the run rather than opening it so that
    # `failed=` covers the whole reconcile: the per-account loop above and
    # every step below it (skill bindings, engineering floors, hierarchy, canonical teams).
    # Printed before the
    # steps it read failed=0 while the banner below said RECONCILE FAILED and
    # the FleetEvent carried the step, which is the one place the three must
    # agree.
    warn "[governance-reconcile] accounts=#{accounts} created=#{created_total} " \
         "already_present=#{present_total} skipped_sets=#{skipped_by_account.values.sum(&:size)} " \
         "shadowed=#{shadowed_by_account.values.sum(&:size)} " \
         "rehomed=#{rehomed_by_account.values.sum(&:size)} failed=#{failed.size}"

    if failed.any?
      warn "=" * 72
      warn "[governance-reconcile] !!! RECONCILE FAILED for #{failed.size} account(s)/step(s) !!!"
      failed.each { |f| warn "[governance-reconcile]   account #{f[:account_id]}: #{f[:error]}" }
      warn "[governance-reconcile] declared governance rows may be MISSING — the gate will"
      warn "[governance-reconcile] resolve them through the require_approval default"
      warn "=" * 72

      begin
        account = Account.first
        if account && defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account_id: account.id,
            kind: "governance_reconcile_failed",
            severity: "high",
            source: "governance_policy_reconciler",
            payload: {
              failed: failed,
              accounts_scanned: accounts,
              detected_at: Time.current.utc.iso8601
            }
          )
          warn "[governance-reconcile] emitted System::FleetEvent(kind=governance_reconcile_failed, severity=high)"
        end
      rescue StandardError => e
        warn "[governance-reconcile] fleet-event emission failed (non-fatal): #{e.class}: #{e.message}"
      end
    end
  end
rescue StandardError => e
  # Absolute backstop: the reconcile must never break boot.
  warn "[governance-reconcile] unexpected error (non-fatal): #{e.class}: #{e.message}"
end
