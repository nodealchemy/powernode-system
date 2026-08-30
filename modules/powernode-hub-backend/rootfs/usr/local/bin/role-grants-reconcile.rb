# frozen_string_literal: true

# Boot-time role-grant reconcile (IMP-c043800b3f21). Run by rails-start.sh
# right after the governance policy reconcile. Creates the catalog grants a
# GLOBAL role is MISSING (Permissions::RoleGrantReconciler is absence-only: it
# never updates a role and never deletes a grant).
#
# WHY AT BOOT: `db:seed` is first-boot only (rails-start.sh gates it behind the
# durable .db-initialized marker), and every other caller of
# Role.sync_from_config! is first-install-only as well. So a grant registered in
# the catalog after an install's first boot never reaches its role_permissions
# rows — the permission resolves for the role in config, the row does not exist,
# and the operator is refused with nothing logged.
#
# WHY NOT Role.sync_from_config! HERE: Role#sync_permissions! is full
# destructive reconciliation, and its `desired` set is filtered by the catalog
# LOADED IN THIS PROCESS. Instances are module-composed, so a boot without an
# extension mounted would delete every grant for that extension's permissions.
# See the class comment for the rest.
#
# Advisory only, exactly like governance-reconcile.rb: it ALWAYS prints a
# summary line (the positive per-boot execution artifact — its ABSENCE from the
# journal is how you tell "wired and running" from "wired and silently
# skipped"), emits a System::FleetEvent on failure, and NEVER raises. Invoked
# with `|| true` and guarded here so a reconciler bug cannot brick a sole
# control plane.
begin
  unless defined?(::Permissions::RoleGrantReconciler)
    # Should not happen (the reconciler is CORE, not an extension), but a
    # hub running an older server tree must not fail its boot over it.
    warn "[role-grants-reconcile] Permissions::RoleGrantReconciler not loaded — skipping"
  else
    result = ::Permissions::RoleGrantReconciler.new.reconcile!

    # ALWAYS printed, including the created=0 steady state.
    warn "[role-grants-reconcile] created_grants=#{result.created} " \
         "created_roles=#{result.created_roles.size} " \
         "already_present=#{result.already_present} failed=#{result.failed.size}"

    # Every created row WIDENS what a role can do. Name them: this converges an
    # established install onto what its own first boot would have written, but
    # it is an operator-visible change in reachable capability, not a silent
    # repair.
    result.created_roles.each { |name| warn "[role-grants-reconcile]   created role: #{name}" }
    result.created_grants.each { |grant| warn "[role-grants-reconcile]   created grant: #{grant}" }

    if result.failed.any?
      warn "=" * 72
      warn "[role-grants-reconcile] !!! RECONCILE FAILED for #{result.failed.size} role(s) !!!"
      result.failed.each { |f| warn "[role-grants-reconcile]   role #{f[:role]}: #{f[:error]}" }
      warn "[role-grants-reconcile] catalog grants may be MISSING — operators holding those"
      warn "[role-grants-reconcile] roles will be refused with no error logged (silent 403)"
      warn "=" * 72

      begin
        account = Account.first
        if account && defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account_id: account.id,
            kind: "role_grant_reconcile_failed",
            severity: "high",
            source: "permissions_role_grant_reconciler",
            payload: {
              failed: result.failed,
              created_grants: result.created,
              detected_at: Time.current.utc.iso8601
            }
          )
          warn "[role-grants-reconcile] emitted System::FleetEvent(kind=role_grant_reconcile_failed, severity=high)"
        end
      rescue StandardError => e
        warn "[role-grants-reconcile] fleet-event emission failed (non-fatal): #{e.class}: #{e.message}"
      end
    end
  end
rescue StandardError => e
  # Absolute backstop: the reconcile must never break boot.
  warn "[role-grants-reconcile] unexpected error (non-fatal): #{e.class}: #{e.message}"
end
