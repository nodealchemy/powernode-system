# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per LIVE NodeInstance (campaign 01a08c9b increment B2).
      #
      # ── SCOPE: WHAT "GONE" MEANS FOR THIS KIND ──────────────────────────
      # `terminated` and nothing else. It is the model's one terminal state
      # (AASM lands there directly and only `revert_termination` leaves it, to
      # `error`), and a terminated instance that kept a row would show a
      # permanent `down` nobody can clear. `error` is NOT gone — it is the most
      # important thing on the screen. `stopped` is not gone either; it is
      # operator intent and reports `held`.
      #
      # Deliberately NOT scoped to ACTIVE_STATUSES: that constant omits
      # `starting`, `stopping`, `rebooting` and `error`, so using it would hide
      # every instance mid-transition and every broken one — the four states an
      # operator most needs to see.
      class NodeInstanceContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "node_instance"

        MODEL  = ::System::NodeInstance
        SENSOR = ::System::Fleet::Sensors::InstanceStatusSensor

        GONE_STATUSES = %w[terminated].freeze

        # Every value of MODEL::STATUSES, mapped. A value added there without a
        # branch here falls to unknown/UnknownStatus, never to ok — and the
        # spec iterates the constant, so it reds instead of drifting.
        #
        # The in-flight and intent states report `true` here on purpose: the
        # fact "this instance is not broken" is separate from "it is mid-reboot"
        # (Progressing) and "someone stopped it" (Held), and each of those is
        # its own typed condition. Collapsing them into this one would make the
        # verdict underivable from the evidence.
        LIFECYCLE = {
          "running"      => { status: true,  reason: "Running" },
          "pending"      => { status: true,  reason: "Pending" },
          "provisioning" => { status: true,  reason: "Provisioning" },
          "starting"     => { status: true,  reason: "Starting" },
          "stopping"     => { status: true,  reason: "Stopping" },
          "rebooting"    => { status: true,  reason: "Rebooting" },
          "stopped"      => { status: true,  reason: "Stopped" },
          "error"        => { status: false, reason: "Errored",
                              severity: ::Platform::Status::Condition::SEVERITY_DOWN },
          # Never enumerated (see GONE_STATUSES) and mapped anyway: a row that
          # reached the sweep in this state is a scope defect, and it must not
          # read as healthy while someone works out why.
          "terminated"   => { status: false, reason: "Terminated",
                              severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        # Ordered: the first cause that applies is the one named. Cordon before
        # ops-hold before drain before stopped, because that is the order in
        # which an operator's intent is most specific.
        HELD_CAUSES = %w[Cordoned OpsHold Draining Stopped].freeze

        REACHABLE = "Reachable"
        ENROLLED  = "Enrolled"
        LIFECYCLE_TYPE = "Lifecycle"

        def kind = KIND

        def account_scoped? = true

        # Fleet kinds keep their lane's escalation (design §5.4). This one is
        # already escalated by InstanceStatusSensor / InstanceUnrecoverableSensor, which claims through
        # SignalState.claim_notification! — so leaving core's A7 escalation on
        # would page twice for one outage, claimed in two places, neither aware
        # of the other. The claim is fleet-side and keyed by fleet fingerprint;
        # core cannot see it. Owner: system.instance_silent and system.instance_unrecoverable.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          # Resolved ONCE per sweep: it is a SensorConfig row read, and one per
          # instance would be a query per instance per minute.
          @silent_threshold = silent_threshold_seconds(account)

          MODEL.joins(:node)
               .where(system_nodes: { account_id: account.id })
               .where.not(status: GONE_STATUSES)
               .includes(:node, :enrollment_token)
               .find_each { |instance| yield instance }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record) = record.name.presence || record.id.to_s

        def environment_id_for(record) = record.node&.environment_id

        # No version or lock column exists on system_node_instances — only
        # created_at/updated_at — so updated_at is the generation. It moves on
        # every heartbeat, which is what makes it useful here.
        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "Cpu", "label" => "Node instance", "group_order" => 40 }
        end

        # There is NO per-instance detail route. Instances render inside the
        # node modal on the nodes list, which holds its selection in React state
        # and never changes the URL, so this is the closest real destination.
        # Inventing a deep link would produce a button that 404s.
        def links_for(_record)
          [ { "label" => "Nodes", "path" => "/app/system/compute/nodes" } ]
        end

        # What this instance DEPENDS ON — the direction Platform::Status::Rollup
        # reverse-walks to compute impact.
        #
        # NOT the System::BlastRadiusService buckets, and the reason is
        # directional rather than a matter of taste: that service answers "what
        # would break if this instance went", i.e. its DEPENDENTS. Putting them
        # here would invert every edge in the graph and point root-cause ranking
        # at the wrong end of it. Those edges belong on the dependents' own
        # contributors, each declaring `requires` this instance.
        def dependencies_for(record)
          edges = []
          edges << { "kind" => "node", "ref" => record.node_id.to_s, "relation" => "hosts" } if record.node_id
          edges << { "kind" => "instance_pool", "ref" => record.instance_pool_id.to_s, "relation" => "backs" } if record.instance_pool_id
          edges
        end

        # Only verbs with a REAL REST route. Cordon, uncordon and replace are
        # MCP-only verbs on the fleet tool — there is no HTTP endpoint for any
        # of them — so they are absent rather than rendered as buttons that
        # would 404. Each permission below is the exact string the controller
        # action requires.
        def actions_for(record)
          return [] if record.node_id.blank?

          base = "/api/v1/system/nodes/#{record.node_id}/node_instances/#{record.id}"
          [
            {
              "key" => "reboot", "label" => "Reboot", "method" => "POST",
              "path" => "#{base}/reboot", "permission" => "system.instances.control",
              "destructive" => false,
              "confirm" => { "prompt" => "Reboot #{display_name_for(record)}?", "requires_reason" => false }
            },
            {
              "key" => "stop", "label" => "Stop", "method" => "POST",
              "path" => "#{base}/stop", "permission" => "system.instances.control",
              "destructive" => false,
              "confirm" => { "prompt" => "Stop #{display_name_for(record)}?", "requires_reason" => false }
            },
            {
              "key" => "start", "label" => "Start", "method" => "POST",
              "path" => "#{base}/start", "permission" => "system.instances.control",
              "destructive" => false,
              "confirm" => { "prompt" => "Start #{display_name_for(record)}?", "requires_reason" => false }
            },
            {
              "key" => "terminate", "label" => "Terminate", "method" => "POST",
              "path" => "#{base}/terminate", "permission" => "system.instances.control",
              "destructive" => true,
              "confirm" => { "prompt" => "Terminate #{display_name_for(record)}? This destroys the instance.",
                             "requires_reason" => true }
            }
          ]
        end

        def conditions_for(record)
          now = Time.current
          [
            enum_condition(type: LIFECYCLE_TYPE, mapping: LIFECYCLE, value: record.status, now: now),
            held_condition(cause: held_cause(record), message: held_message(record), now: now),
            progressing_condition(cause: progressing_cause(record), now: now),
            reachable_condition(record, now),
            enrolled_condition(record, now)
          ].compact
        end

        private

        def silent_threshold_seconds(account)
          SENSOR.resolved_threshold("silent_threshold_seconds", account: account)
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] silent threshold unresolved: #{e.class}: #{e.message}")
          nil
        end

        def held_cause(record)
          return "Cordoned" if record.cordoned?
          return "OpsHold"  if record.ops_held?
          return "Draining" if record.pool_state.to_s == "draining"
          return "Stopped"  if record.status.to_s == "stopped"

          nil
        end

        def held_message(record)
          case held_cause(record)
          when "OpsHold" then record.ops_hold_reason.presence
          when "Draining" then "draining out of its pool"
          end
        end

        def progressing_cause(record)
          case record.status.to_s
          when "pending", "provisioning" then "Provisioning"
          when "starting"  then "Starting"
          when "stopping"  then "Stopping"
          when "rebooting" then "Rebooting"
          else
            "EnrollmentPending" if enrollment_pending?(record)
          end
        end

        # Emitted ONLY where a heartbeat is expected. A stopped instance is not
        # unreachable, it is off; asserting `unknown` there would rank every
        # deliberately-stopped instance above a held one and turn an intentional
        # state amber.
        def reachable_condition(record, now)
          return nil unless MODEL::HEARTBEAT_EXPECTED_STATUSES.include?(record.status.to_s)

          last = record.last_heartbeat_at
          evidence = { "last_heartbeat_at" => last&.iso8601,
                       "silent_threshold_seconds" => @silent_threshold }

          if @silent_threshold.nil?
            return CONDITION.build(type: REACHABLE, status: CONDITION::UNKNOWN,
                                   reason: "ThresholdUnresolved", evidence: evidence, now: now)
          end

          if last.nil?
            return CONDITION.build(type: REACHABLE, status: false, reason: "NeverHeartbeat",
                                   message: "no heartbeat has ever been recorded",
                                   evidence: evidence, now: now)
          end

          age = (now - last).to_i
          fresh = age <= @silent_threshold

          CONDITION.build(
            type: REACHABLE, status: fresh,
            reason: fresh ? "HeartbeatFresh" : "HeartbeatStale",
            message: "last heartbeat #{age}s ago; silent after #{@silent_threshold}s",
            evidence: evidence.merge("age_seconds" => age), now: now
          )
        end

        # Enrolment is only a FACT where a bootstrap token was issued. Physical
        # and discovered instances legitimately have none, and a missing token
        # there is not a failed enrolment.
        #
        # A pending token is Progressing, not a false Enrolled: a freshly
        # provisioned instance would otherwise read `degraded` for its whole
        # enrolment window. An EXPIRED unconsumed token is the genuinely stuck
        # state and is the one that goes false.
        def enrolled_condition(record, now)
          token = record.enrollment_token
          return nil if token.nil?

          evidence = { "bootstrap_token_id" => token.id.to_s,
                       "expires_at" => token.expires_at&.iso8601 }

          if token.consumed_at.present?
            return CONDITION.build(type: ENROLLED, status: true, reason: "Enrolled",
                                   evidence: evidence.merge("consumed_at" => token.consumed_at.iso8601),
                                   now: now)
          end

          return nil unless token_expired?(token, now)

          CONDITION.build(type: ENROLLED, status: false, reason: "EnrollmentTokenExpired",
                          message: "the bootstrap token expired unconsumed; the agent cannot enrol",
                          evidence: evidence, now: now)
        end

        def enrollment_pending?(record)
          token = record.enrollment_token
          token.present? && token.consumed_at.nil? && !token_expired?(token, Time.current)
        end

        def token_expired?(token, now)
          token.expires_at.present? && token.expires_at <= now
        end
      end
    end
  end
end
