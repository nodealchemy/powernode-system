# frozen_string_literal: true

# Boot-time schema-drift backstop (imp 019f77c5). Run by rails-start.sh right
# after db:migrate. Advisory only: it LOGS loudly and emits a System::FleetEvent
# if it finds a stamped migration whose declared DDL never landed
# (stamped-without-DDL drift), but it NEVER fails the boot — invoked with
# `|| true` in rails-start, and every path here is guarded so a detector bug
# can't brick a sole control plane.
begin
  result = System::SchemaDriftDetector.run
  warn "[schema-drift-check] #{result.summary}"

  if result.drifted?
    # LOUD, greppable banner in the journal.
    warn "=" * 72
    warn "[schema-drift-check] !!! SCHEMA DRIFT DETECTED — stamped-without-DDL !!!"
    result.missing.each do |m|
      warn "[schema-drift-check]   MISSING #{m[:kind].to_s.upcase} #{m[:table]}.#{m[:name]} (migration #{m[:version]})"
    end
    warn "[schema-drift-check] remediate: reconcile the missing DDL, then investigate the DB-init path"
    warn "=" * 72

    # Emit a fleet event so it surfaces in fleet views / alerting, not just logs.
    begin
      account = Account.first
      if account && defined?(::System::FleetEvent)
        ::System::FleetEvent.create!(
          account_id: account.id,
          kind: "schema_drift_detected",
          severity: "high",
          source: "schema_drift_detector",
          payload: {
            missing: result.missing,
            migrations_scanned: result.migrations_scanned,
            detected_at: Time.current.utc.iso8601
          }
        )
        warn "[schema-drift-check] emitted System::FleetEvent(kind=schema_drift_detected, severity=high)"
      end
    rescue StandardError => e
      warn "[schema-drift-check] fleet-event emission failed (non-fatal): #{e.class}: #{e.message}"
    end
  elsif result.error
    warn "[schema-drift-check] detector could not run (non-fatal): #{result.error}"
  end
rescue StandardError => e
  # Absolute backstop: the drift check must never break boot.
  warn "[schema-drift-check] unexpected error (non-fatal): #{e.class}: #{e.message}"
end
