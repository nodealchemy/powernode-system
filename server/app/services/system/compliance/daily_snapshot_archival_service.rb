# frozen_string_literal: true

module System
  module Compliance
    # Audit plan P2.8d — daily snapshot persistence + retention.
    #
    # Per-account: generates today's compliance snapshot via
    # ComplianceSnapshotService, then emits a FleetEvent with
    # kind="system.compliance.snapshot" whose payload carries the snapshot.
    # The FleetEvent serves as the durable record:
    #   - Auto-pruned by SystemFleetEventRetentionJob (90-day default;
    #     critical-severity bonus retention applies)
    #   - Account-scoped via the existing FleetEvent.account_id
    #   - Audit-trail discoverable via `platform.recent_events kind:`
    #
    # Why FleetEvent instead of a dedicated table or Ai::Document:
    #   - Zero new infrastructure (model/migration/retention sweep)
    #   - Retention semantics inherited from existing fleet event sweep
    #   - Audit-discoverable via the same `recent_events` operators already use
    #   - JSON payload column comfortably holds typical snapshot sizes (<1 MB)
    #
    # Triggered by SystemComplianceSnapshotJob (worker side, daily) which
    # POSTs to the worker_api/compliance/archive endpoint that wraps this.
    class DailySnapshotArchivalService
      SNAPSHOT_EVENT_KIND = "system.compliance.snapshot"

      Result = Struct.new(:ok?, :snapshots_emitted, :accounts_failed, :errors,
                          keyword_init: true)

      def self.run!
        new.run!
      end

      def run!
        snapshots_emitted = 0
        accounts_failed = 0
        errors = []

        ::Account.find_each do |account|
          result = generate_and_persist_for!(account: account)
          if result.ok?
            snapshots_emitted += 1
          else
            accounts_failed += 1
            errors << { account_id: account.id, error: result.error }
          end
        end

        Result.new(
          ok?: accounts_failed.zero?,
          snapshots_emitted: snapshots_emitted,
          accounts_failed: accounts_failed,
          errors: errors
        )
      end

      def generate_and_persist_for!(account:)
        snapshot_result = ::System::Compliance::ComplianceSnapshotService.snapshot!(account: account, scope: :all)
        unless snapshot_result.ok?
          return Result.new(ok?: false, snapshots_emitted: 0, accounts_failed: 1,
                             errors: [{ account_id: account.id, error: snapshot_result.error }])
        end

        # Severity bumped to medium so the retention sweep's "critical bonus
        # window" doesn't apply (snapshots ARE the audit trail; we don't want
        # them retained past the standard window — that's redundant with the
        # incremental snapshots that follow).
        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: SNAPSHOT_EVENT_KIND,
          severity: :medium,
          source: "compliance_archival",
          payload: {
            schema_version: 1,
            generated_at: snapshot_result.generated_at.iso8601,
            counts: snapshot_result.snapshot[:counts],
            metadata: snapshot_result.snapshot[:metadata],
            snapshot: snapshot_result.snapshot
          }
        )

        Result.new(ok?: true, snapshots_emitted: 1, accounts_failed: 0, errors: [])
      rescue StandardError => e
        Result.new(ok?: false, snapshots_emitted: 0, accounts_failed: 1,
                   errors: [{ account_id: account&.id, error: "#{e.class}: #{e.message}" }])
      end
    end
  end
end
