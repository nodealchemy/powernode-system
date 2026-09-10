# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per storage assignment (campaign 01a08c9b B3).
      #
      # ── TWO STATE COLUMNS, BOTH MAPPED ──────────────────────────────────
      # `status` is the mount lifecycle and `chown_state` is the ownership
      # operation that runs across it. A mounted volume whose recursive chown
      # failed is mounted AND broken, and one column cannot say both.
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # Nothing is gone: the model has no archived or deleted state and rows are
      # hard-destroyed. `disabled` is operator intent and reports `held`;
      # `failed` is the row an operator most needs and stays on the screen.
      class StorageAssignmentContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "storage_assignment"
        MODEL = ::System::StorageAssignment

        LIFECYCLE = {
          "mounted"      => { status: true,  reason: "Mounted" },
          "pending"      => { status: true,  reason: "Pending" },
          "provisioning" => { status: true,  reason: "Provisioning" },
          "unmounting"   => { status: true,  reason: "Unmounting" },
          "disabled"     => { status: true,  reason: "Disabled" },
          "degraded"     => { status: false, reason: "Degraded" },
          "failed"       => { status: false, reason: "Failed",
                              severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        CHOWN = {
          "complete"        => { status: true,  reason: "Complete" },
          # In flight, not failed — Progressing carries it.
          "pending"         => { status: true,  reason: "Queued" },
          "running"         => { status: true,  reason: "Running" },
          "failed"          => { status: false, reason: "ChownFailed" },
          "manual_required" => { status: false, reason: "ChownManualRequired",
                                 message: "the platform cannot reach this provider; chown by hand, " \
                                          "then force_complete the assignment" }
        }.freeze

        PROGRESSING_STATUSES = %w[pending provisioning unmounting].freeze

        def kind = KIND

        def account_scoped? = true

        # StorageAssignmentDriftSensor already escalates this kind
        # (system.storage_assignment_drift) and claims through
        # SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id)
               .includes(:node_instance)
               .find_each { |assignment| yield assignment }
        end

        def ref_for(record) = record.id.to_s

        # No name column at all; the mount path is the identifying string an
        # operator recognises.
        def display_name_for(record)
          record.mount_path.presence || record.id.to_s
        end

        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "HardDrive", "label" => "Storage assignment", "group_order" => 80 }
        end

        def links_for(_record)
          [ { "label" => "Volumes", "path" => "/app/system/compute/volumes" } ]
        end

        def dependencies_for(record)
          return [] if record.node_instance_id.blank?

          [ { "kind" => "node_instance", "ref" => record.node_instance_id.to_s,
              "relation" => "requires" } ]
        end

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          evidence = { "mount_path" => record.mount_path.to_s,
                       "owner_kind" => record.owner_kind.to_s,
                       "enabled" => record.enabled? }

          [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status,
                           evidence: evidence, now: now),
            held_condition(cause: held_cause(record), now: now),
            progressing_condition(cause: progressing_cause(record), now: now),
            enum_condition(type: "Chown", mapping: CHOWN, value: record.chown_state,
                           evidence: { "chown_last_error" => record.chown_last_error }, now: now)
          ]
        end

        private

        def held_cause(record)
          return "Disabled" unless record.enabled?

          "Disabled" if record.status.to_s == "disabled"
        end

        def progressing_cause(record)
          return "Unmounting" if record.status.to_s == "unmounting"
          return "Mounting"   if PROGRESSING_STATUSES.include?(record.status.to_s)

          "ChownInFlight" if record.chown_in_flight?
        end
      end
    end
  end
end
