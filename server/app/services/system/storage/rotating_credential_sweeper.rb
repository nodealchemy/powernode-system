# frozen_string_literal: true

module System
  module Storage
    # IMP-a366d6fb6b80 - bounds the deferred revocation of a rotated SMB
    # credential.
    #
    # A scheme-crossing SMB rotation leaves the OUTGOING credential "rotating"
    # (its samba user and password still valid) until the consumer confirms a
    # remount (RemountCoordinator -> CredentialIssuer#retire_rotating_smb_credentials!).
    # Until this existed, a node that was offline, wedged, deleted without
    # teardown, or compromised and deliberately silent kept that old user and
    # password valid forever. This retires a credential that has been
    # "rotating" longer than the operator's window.
    #
    # ONE REVOCATION PATH. The retirement is CredentialIssuer's own
    # (#retire_overdue_rotating_smb_credential!, which shares its body with the
    # confirmation's #retire_rotating_smb_credentials! - deprovision! then
    # revoke!, which is what creates the samba delete task). This class decides
    # WHICH credentials are overdue, stamps the ones with no clock, records the
    # audit row and raises the alert. It never revokes anything itself.
    #
    # WHERE IT RUNS. Sensors are read-side, so this is not a sensor; it is the
    # act arm of an existing lane. StorageAssignmentDriftSensor emits
    # system.storage_assignment_drift for an assignment with an overdue rotating
    # credential, and DecisionEngine#reconcile_storage_assignment - the applier
    # that lane already has, run when the system.storage_assignment_reconcile
    # gate proceeds - calls .sweep_assignment! before reconciling. That sensor
    # is in FleetAutonomyService::SENSORS, ticked every minute by the
    # system_fleet_reconcile cron (extensions/system/worker/config/sidekiq_system.yml).
    #
    # RACING A LATE CONFIRMATION. The forced retirement re-checks status AND
    # overdue-ness under the credential row's lock, the same lock a
    # confirmation's retirement takes, so exactly one of them retires it and
    # the other finds it revoked: no double delete task, no double alert.
    class RotatingCredentialSweeper
      SETTING_KEY = "system.storage.smb_rotation_retire_window_hours"

      # Unit: hours. 24h covers a node that is merely rebooting, being patched
      # or briefly partitioned, while still ending the exposure within a day.
      DEFAULT_WINDOW_HOURS = 24

      # 1h floor: a remount normally confirms within minutes, but a window
      # shorter than the node's own heartbeat / boot time would retire the old
      # user out from under a consumer that is simply mid-reconnect, which is
      # the lock-out the deferral exists to prevent. 168h (7 days) ceiling: a
      # week already covers a weekend outage plus a slow response; past it the
      # setting stops being a bound at all and is the "valid forever" this
      # closes.
      MIN_WINDOW_HOURS = 1
      MAX_WINDOW_HOURS = 168

      AUDIT_ACTION = "system.storage.smb_credential.force_retire"
      AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze
      EVENT_KIND = "system.storage.smb_credential_force_retired"

      class << self
        # The effective window. Fails to the default for anything that is not a
        # whole number of hours inside the bounds - a bad stored value must
        # neither disable the sweep (zero) nor retire everything at once
        # (negative), and the value check below refuses those at write time.
        def window
          (whole_hours(::SiteSetting.get(SETTING_KEY)) || DEFAULT_WINDOW_HOURS).hours
        rescue StandardError => e
          Rails.logger.warn("[RotatingCredentialSweeper] window fell back to the default: #{e.class}: #{e.message}")
          DEFAULT_WINDOW_HOURS.hours
        end

        # nil when `value` is an acceptable window, else why it is not. The
        # SiteSetting value check delegates here.
        def window_problem(value)
          return nil if whole_hours(value)

          "must be a whole number of hours from #{MIN_WINDOW_HOURS} to #{MAX_WINDOW_HOURS}"
        end

        def sweep_assignment!(assignment, now: Time.current)
          new(assignment: assignment, now: now).sweep!
        end

        private

        def whole_hours(raw)
          hours = case raw
          when Integer then raw
          when String then raw.strip.match?(/\A\d+\z/) ? raw.strip.to_i : nil
          end
          hours if hours && hours.between?(MIN_WINDOW_HOURS, MAX_WINDOW_HOURS)
        end
      end

      def initialize(assignment:, now:)
        @assignment = assignment
        @now = now
      end

      # @return [Hash] { retired: [credential ids this call retired],
      #   stamped: [ids given a clock], failed: [ids whose retirement raised] }
      def sweep!
        result = { retired: [], stamped: [], failed: [] }
        return result unless @assignment.file_storage&.smb?

        window = self.class.window
        cutoff = @now - window
        issuer = CredentialIssuer.new(assignment: @assignment)

        @assignment.storage_credentials.rotating_overdue(cutoff).find_each do |credential|
          if credential.rotating_since.nil?
            result[:stamped] << credential.id if stamp!(credential)
          elsif retire!(issuer, credential, cutoff: cutoff, window: window)
            result[:retired] << credential.id
          end
        rescue StandardError => e
          # The transaction rolled back, so the credential is still rotating
          # and overdue: the drift signal persists and the next tick retries.
          Rails.logger.error(
            "[RotatingCredentialSweeper] could not retire credential #{credential.id} " \
            "of assignment #{@assignment.id}: #{e.class}: #{e.message}"
          )
          result[:failed] << credential.id
        end

        result
      end

      private

      # A row with no clock (written by the previous release, or during a
      # rolling deploy) gets one now, so it neither retires instantly nor
      # stays unbounded. State-guarded, so a concurrent stamp or a retirement
      # in between makes this a no-op.
      def stamp!(credential)
        ::System::StorageCredential
          .where(id: credential.id, status: "rotating", rotating_since: nil)
          .update_all(rotating_since: @now, updated_at: @now).positive?
      end

      def retire!(issuer, credential, cutoff:, window:)
        rotating_since = credential.rotating_since
        retired = issuer.retire_overdue_rotating_smb_credential!(credential, cutoff: cutoff) do |row, delete_task|
          write_audit!(row, delete_task, rotating_since: rotating_since, window: window)
        end
        emit_event(credential, rotating_since: rotating_since, window: window) if retired
        retired
      end

      # Inside the retirement's transaction: the record and the revocation
      # commit or roll back together.
      def write_audit!(credential, delete_task, rotating_since:, window:)
        ::AuditLog.log_action(
          action: AUDIT_ACTION,
          resource: credential,
          user: nil,
          account: @assignment.account,
          old_values: { "status" => "rotating" },
          new_values: { "status" => "revoked" },
          source: "system",
          severity: "high",
          risk_level: "high",
          # No key here may contain "credential": AuditLog masks any such key as
          # [FILTERED]. The credential's id is the row's resource_id.
          metadata: details(rotating_since: rotating_since, window: window).merge(
            "delete_task_id" => delete_task&.id,
            "reason" => "the consumer node never confirmed the remount within the window"
          ).compact
        )
      end

      # After the commit, best-effort by EventBroadcaster's contract: the audit
      # row is the record, this is the alert an operator sees.
      def emit_event(credential, rotating_since:, window:)
        ::System::Fleet::EventBroadcaster.emit!(
          account: @assignment.account,
          kind: EVENT_KIND,
          severity: :high,
          payload: details(rotating_since: rotating_since, window: window).merge("credential_id" => credential.id),
          source: "storage_rotating_credential_sweeper",
          node_instance_id: @assignment.node_instance_id
        )
      end

      def details(rotating_since:, window:)
        node = @assignment.node_instance
        {
          "storage_assignment_id" => @assignment.id,
          "node_instance_id" => @assignment.node_instance_id,
          "node_instance_name" => node&.name,
          "successor_id" => @assignment.active_credential&.id,
          "rotating_since" => rotating_since&.utc&.iso8601,
          "window_hours" => (window / 1.hour).to_i
        }
      end
    end
  end
end
