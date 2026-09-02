# frozen_string_literal: true

require "rails_helper"

# APO-2d (IMP-25949cfd28fd) — the "notify" half of notify_and_proceed, and the
# BaseSkillExecutor audit trail, both terminated in Rails.logger.
#
# WHY IT MATTERS: `notify_and_proceed` is the policy an operator picks when they
# want the fleet to act AND to be told. What they got was one
# `Rails.logger.info` line on the reconciler host — invisible to the approval
# UI, to `system_recent_signals`, to `system_inspect_correlation`, and to every
# compliance read. The ten `*_investigate` notify-only lanes (no applier
# exists; the notification IS the remediation) therefore delivered nothing at
# all. Symmetrically, a skill executor driven directly — an MCP call, a
# reconciler's #invoke_skill, a replayed approval — wrote its start/finish/error
# audit to stdout only, so an operation that ran outside a fleet tick left no
# durable record that it had ever happened. (Ten such lanes, not eleven as the
# finding read: `command grep -rho "system\.[a-z_]*_investigate" app/ | sort -u`
# returns 10.)
#
# The durable record is a System::FleetEvent (persisted + broadcast on
# SystemFleetChannel by System::Fleet::EventBroadcaster). This spec pins the
# EMIT, not a frontend surface — the operator UI for the remediation lane is
# separately approved work (offer 01a053ec).
RSpec.describe "notify lanes and skill executions leave a durable operator record" do
  let(:account) { create(:account) }

  describe System::Fleet::FleetAutonomyService do
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { described_class.new(account: account, agent: agent) }

    def seed_policy!(category, policy)
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: agent.id, scope: "agent",
        action_category: category, policy: policy, is_active: true
      )
    end

    it "emits a durable, broadcast FleetEvent for a notify_and_proceed decision" do
      seed_policy!("system.module_verify_investigate", "notify_and_proceed")

      result = service.gate_action!(
        "system.module_verify_investigate",
        metadata: { "instance_id" => nil },
        reasoning: { summary: "module verify failed on 3 nodes" }
      )

      expect(result[:gate]).to eq("notify_and_proceed")

      event = System::FleetEvent.find_by(
        account_id: account.id,
        kind: described_class::NOTIFY_EVENT_KIND
      )
      expect(event).to be_present,
                       "expected notify_and_proceed to leave a durable FleetEvent, not just a log line"
      expect(event.severity).to eq("medium")
      expect(event.source).to eq("fleet_autonomy")
      expect(event.payload["action_category"]).to eq("system.module_verify_investigate")
      expect(event.payload["summary"]).to eq("module verify failed on 3 nodes")
      expect(event.payload["gate"]).to eq("notify_and_proceed")
      expect(event.correlation_id).to be_present
    end

    # The notification is worth little if it cannot be joined to the decision it
    # belongs to: system_inspect_correlation walks by correlation_id, and
    # EventBroadcaster#emit_decision! keys its decision events off the signal
    # fingerprint. A freshly minted id here would file the notification in a
    # chain of its own — a mutation the example above cannot see, because it
    # only asks that SOME correlation_id is present.
    it "correlates the notification with the signal's own decision chain" do
      seed_policy!("system.task_backlog_investigate", "notify_and_proceed")

      service.gate_action!(
        "system.task_backlog_investigate",
        metadata: { "signal_kind" => "system.task_backlog", "signal_fingerprint" => "fp-abc123" },
        reasoning: { summary: "42 tasks stuck" }
      )

      event = System::FleetEvent.find_by(account_id: account.id,
                                         kind: described_class::NOTIFY_EVENT_KIND)
      expect(event.correlation_id).to eq("fp-abc123")
      expect(event.payload["signal_kind"]).to eq("system.task_backlog")
    end

    # Mutation oracle for the emit's PLACEMENT: an unconditional emit inside
    # gate_action! would also fire here, and the example above could not tell.
    it "does not emit the notify event for an auto_approve decision" do
      seed_policy!("system.cert_rotate", "auto_approve")

      service.gate_action!("system.cert_rotate", reasoning: { summary: "rotate" })

      expect(
        System::FleetEvent.where(account_id: account.id, kind: described_class::NOTIFY_EVENT_KIND)
      ).to be_empty
    end

    it "broadcasts the notify event on the account's fleet channel" do
      seed_policy!("system.node_lkg_investigate", "notify_and_proceed")
      expect(ActionCable.server).to receive(:broadcast)
        .with("system_fleet:#{account.id}", hash_including(kind: described_class::NOTIFY_EVENT_KIND))

      service.gate_action!("system.node_lkg_investigate", reasoning: { summary: "lkg stale" })
    end
  end

  describe System::Ai::Skills::BaseSkillExecutor do
    let(:ok_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "apo2d_ok_skill", description: "for spec", category: "fleet",
          inputs: { node_instance_id: { type: "string", required: true } }, outputs: {}
        )

        protected

        def perform(node_instance_id:)
          success(seen: node_instance_id)
        end
      end
    end

    let(:boom_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "apo2d_boom_skill", description: "for spec", category: "fleet",
          inputs: {}, outputs: {}
        )

        protected

        def perform
          raise ArgumentError, "detonated"
        end
      end
    end

    def events(kind)
      System::FleetEvent.where(account_id: account.id, kind: kind)
    end

    # Deliberately shaped like the material the redaction exists for. Asserted
    # by CONTAINMENT below, so it survives a rename of the payload key.
    let(:secretish_input) { "i-SECRET-TOKEN-4f2b" }

    it "records the start and the finish of a direct invocation as FleetEvents" do
      result = ok_class.new(account: account).execute(node_instance_id: secretish_input)
      expect(result[:success]).to be(true)

      started  = events(described_class::EVENT_KIND_STARTED).first
      finished = events(described_class::EVENT_KIND_FINISHED).first

      expect(started).to be_present,
                         "expected audit_log_start to leave a durable FleetEvent, not just a log line"
      expect(finished).to be_present,
                          "expected audit_log_finish to leave a durable FleetEvent, not just a log line"

      # Both halves of one invocation must be joinable — system_inspect_correlation
      # walks by correlation_id, and a start you cannot pair with its finish is
      # not an audit trail.
      expect(started.correlation_id).to be_present
      expect(finished.correlation_id).to eq(started.correlation_id)

      expect(started.source).to eq("skill_executor")
      expect(started.payload["skill"]).to eq("apo2d_ok_skill")
      # Input KEYS only — values can carry operator secrets, and the log line
      # this replaces deliberately recorded keys alone.
      expect(started.payload["input_keys"]).to eq([ "node_instance_id" ])

      # CONTAINMENT, not a name check: `not_to have_key("inputs")` forbids one
      # literal key, so a mutant that stores the same values under "args" (or
      # merges them at the top level) walks straight past it. The property is
      # that the VALUE never reaches the row, whatever it is called — and the
      # row is persisted AND broadcast, so this is the privacy oracle for both.
      expect(started.payload.to_json).not_to include(secretish_input)

      expect(finished.payload["success"]).to be(true)
      expect(finished.severity).to eq("low")
    end

    # An executor's inputs are not the only free-form text on the row: a
    # provider's error string and an exception message both land in a jsonb
    # column and go out on the account channel, where they used to be a
    # server-local log line. Unbounded, one provider stack trace is the whole
    # payload budget.
    it "bounds the free-form error text it persists and broadcasts" do
      long = "x" * (described_class::AUDIT_TEXT_LIMIT + 500)
      klass = Class.new(described_class) do
        skill_descriptor(name: "apo2d_long_error", description: "for spec", category: "fleet",
                         inputs: {}, outputs: {})

        protected

        define_method(:perform) { raise ArgumentError, long }
      end

      klass.new(account: account).execute

      failed = events(described_class::EVENT_KIND_FAILED).first
      expect(failed.payload["error"].length).to be <= described_class::AUDIT_TEXT_LIMIT
      # The class still identifies the failure exactly; only the message is cut.
      expect(failed.payload["error_class"]).to eq("ArgumentError")
    end

    # A skill dispatched from a fleet tick belongs in the tick's correlation
    # walk. Without this seam the audit rows are unreachable from
    # system_inspect_correlation on the decision that ordered them, which is the
    # same defect #notify_action's fingerprint keying fixes on the other side.
    it "files its audit in the CALLER's correlation chain when it has one" do
      exec = ok_class.new(account: account)
      exec.caller_correlation_id = "fp-tick-99"
      exec.execute(node_instance_id: "i-1")

      expect(events(described_class::EVENT_KIND_STARTED).first.correlation_id).to eq("fp-tick-99")
      expect(events(described_class::EVENT_KIND_FINISHED).first.correlation_id).to eq("fp-tick-99")
    end

    # One chain per CALL, not per object: a memoized id would merge two runs of
    # the same executor instance into a single, unreadable audit chain.
    it "opens a new chain for each execution of the same executor object" do
      exec = ok_class.new(account: account)
      exec.execute(node_instance_id: "i-1")
      exec.execute(node_instance_id: "i-2")

      chains = events(described_class::EVENT_KIND_STARTED).pluck(:correlation_id)
      expect(chains.length).to eq(2)
      expect(chains.uniq.length).to eq(2)
    end

    it "records a raised failure as a high-severity FleetEvent naming the exception" do
      result = boom_class.new(account: account).execute
      expect(result[:success]).to be(false)

      failed = events(described_class::EVENT_KIND_FAILED).first
      expect(failed).to be_present,
                        "expected audit_log_error to leave a durable FleetEvent, not just a log line"
      expect(failed.severity).to eq("high")
      expect(failed.payload["error_class"]).to eq("ArgumentError")
      expect(failed.payload["error"]).to eq("detonated")
      expect(events(described_class::EVENT_KIND_FINISHED)).to be_empty
    end

    # Mutation oracle for the SEVERITY split: a finish that reports a failure
    # result is not the same operator signal as a successful one.
    it "raises the finish severity when perform returns a failure result" do
      klass = Class.new(described_class) do
        skill_descriptor(name: "apo2d_soft_fail", description: "for spec", category: "fleet",
                         inputs: {}, outputs: {})

        protected

        def perform
          failure("provider said no")
        end
      end

      klass.new(account: account).execute

      finished = events(described_class::EVENT_KIND_FINISHED).first
      expect(finished).to be_present
      expect(finished.payload["success"]).to be(false)
      expect(finished.severity).to eq("medium")
    end

    # The audit trail is observability: it must never be the reason a fleet
    # operation fails. EventBroadcaster swallows its own errors; this pins that
    # the executor does not reintroduce a raise around it.
    it "still returns the perform result when the event write fails" do
      allow(System::Fleet::EventBroadcaster).to receive(:emit!)
        .and_raise(ActiveRecord::StatementInvalid, "events table gone")

      result = ok_class.new(account: account).execute(node_instance_id: "i-1")

      expect(result[:success]).to be(true)
      expect(result.dig(:data, :seen)).to eq("i-1")
    end
  end
end
