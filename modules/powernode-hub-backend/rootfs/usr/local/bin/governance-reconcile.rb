# frozen_string_literal: true

# Boot-time governance policy reconcile (IMP-d02b258eb303). Run by
# rails-start.sh right after the schema-drift backstop. Creates the declared
# governance rows an account is MISSING (System::Governance::PolicyReconciler is
# absence-only: it never updates a verb and never deletes).
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
      rescue StandardError => e
        # One bad account must not stop the rest.
        failed << { account_id: account.id, error: "#{e.class}: #{e.message}" }
        warn "[governance-reconcile] account #{account.id} failed (non-fatal): #{e.class}: #{e.message}"
      end
    end

    # ALWAYS printed, including the created=0 steady state.
    warn "[governance-reconcile] accounts=#{accounts} created=#{created_total} " \
         "already_present=#{present_total} skipped_sets=#{skipped_by_account.values.sum(&:size)} " \
         "shadowed=#{shadowed_by_account.values.sum(&:size)} failed=#{failed.size}"

    created_by_account.each do |account_id, categories|
      warn "[governance-reconcile]   account #{account_id} created: #{categories.join(', ')}"
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

    if failed.any?
      warn "=" * 72
      warn "[governance-reconcile] !!! RECONCILE FAILED for #{failed.size} account(s) !!!"
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
