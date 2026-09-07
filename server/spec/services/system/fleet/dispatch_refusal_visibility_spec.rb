# frozen_string_literal: true

require "rails_helper"

# IMP-b8cab7f951c7 — follow-on to IMP-ee681c537f76, which made exactly ONE of
# the refusal paths visible (the dead-target fence in
# DecisionEngine#dispatch_reconcile_task) and left an in-code acknowledgement
# naming the rest.
#
# WHY A REFUSAL THAT ONLY LIVES IN A RETURN VALUE IS INVISIBLE: emit_decision!
# builds decision.proceeded with no `applied` key, and executed_remediation?
# mints no RemediationOutcome for `applied: false`. So a lane that proceeded and
# then declined to act reads in the event stream exactly like one that acted —
# which is why the orphaned dispatches of 2026-09-06 went unnoticed for 42
# hours.
#
# Six sites, one emit path. Four in DecisionEngine, two in SystemFleetTool,
# which is why the emitter is a shared reporter rather than a private method on
# either.
#
# THE DEDUP TRAP THIS SPEC IS WRITTEN AROUND: the engine dedups its OWN
# decisions by fingerprint for 600s BEFORE the dispatcher is reached, so
# deciding the same kind twice returns :deduped without ever exercising the
# claim under test — an example written that way is vacuous and stays green
# when the claim is deleted. Every TTL example below uses two DISTINCT
# fingerprints for that reason.
RSpec.describe "dispatch refusal visibility (IMP-b8cab7f951c7)" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:instance) do
    create(:system_node_instance, :running, node: node, last_heartbeat_at: Time.current)
  end

  def refusal_events
    ::System::FleetEvent.where(account: account, kind: "fleet.dispatch_refused").order(:created_at)
  end

  describe "DecisionEngine refusal branches" do
    let(:drift_plan) do
      { success: true,
        data: { resolved: true, requires_approval: false, disruption_pct: 5,
                planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } }
    end

    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.module_assign",
                                     policy: "notify_and_proceed", is_active: true)
      allow_any_instance_of(::System::Ai::Skills::DriftRemediateExecutor)
        .to receive(:execute).and_return(drift_plan)
      Rails.cache.clear
    end

    # DISTINCT fingerprints per call — see the header.
    def decide_drift_with(fingerprint)
      engine.decide(kind: "system.module_drift", severity: :medium,
                    payload: { "instance_id" => instance.id },
                    fingerprint: fingerprint)
    end

    context "the disruption budget refusal" do
      let(:drift_plan) do
        { success: true,
          data: { resolved: true, requires_approval: true, disruption_pct: 80,
                  planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } }
      end

      it "still refuses" do
        d = decide_drift_with("budget:a:#{instance.id}")
        expect(d[:remediation]).to include(applied: false)
        expect(d.dig(:remediation, :reason)).to match(/disruption exceeds auto-apply budget/)
      end

      it "emits a durable refusal an operator can find later" do
        decide_drift_with("budget:b:#{instance.id}")

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["refusal_class"]).to eq("disruption_budget")
        # The PRODUCER, not a module-wide constant: the emitter is shared with
        # an MCP tool, and an operator reading the ledger needs to know which
        # lane declined. DecisionEngine keeps the string it has written since
        # IMP-ee681c537f76, so the extraction did not rewrite an operator-facing
        # field on rows that already exist.
        expect(event.source).to eq("decision_engine.dispatch_refused")
        expect(event.payload["reason"]).to match(/disruption exceeds auto-apply budget/)
        expect(event.payload["instance_id"]).to eq(instance.id)
      end

      it "emits ONCE per window even though the refusal re-fires every tick" do
        decide_drift_with("budget:c1:#{instance.id}")
        decide_drift_with("budget:c2:#{instance.id}")

        expect(refusal_events.count).to eq(1)
      end
    end

    context "the foreign control plane fence" do
      before do
        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:owned_by_this_control_plane?).and_return(false)
      end

      it "emits a refusal naming the fence" do
        decide_drift_with("foreign:a:#{instance.id}")

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["refusal_class"]).to eq("foreign_control_plane")
        expect(event.payload["reason"]).to match(/another control plane/)
      end

      it "emits ONCE per window" do
        decide_drift_with("foreign:b1:#{instance.id}")
        decide_drift_with("foreign:b2:#{instance.id}")

        expect(refusal_events.count).to eq(1)
      end
    end

    context "the INV-1 self-management fence" do
      before do
        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:self_managed_target?).and_return(true)
      end

      it "emits a refusal naming INV-1" do
        decide_drift_with("selfmgmt:a:#{instance.id}")

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["refusal_class"]).to eq("self_managed")
        expect(event.payload["reason"]).to match(/INV-1/)
      end
    end

    context "the in-flight guard" do
      before do
        ::System::Task.create!(account: account, operable: instance, command: "sync_modules",
                               status: "pending", options: {})
      end

      it "emits a refusal so a genuinely stuck task stops looking like an ordinary skip" do
        decide_drift_with("inflight:a:#{instance.id}")

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["refusal_class"]).to eq("task_in_flight")
        expect(event.payload["reason"]).to match(/already in flight/)
      end

      it "emits ONCE per window" do
        decide_drift_with("inflight:b1:#{instance.id}")
        decide_drift_with("inflight:b2:#{instance.id}")

        expect(refusal_events.count).to eq(1)
      end
    end

    context "a refusal whose target does not resolve" do
      # The ONLY caller that can pass a nil instance. The row is weaker — it
      # names no target — but it is the only evidence the lane declined, and
      # the emitter must not blow up on the nil.
      let(:drift_plan) do
        { success: true,
          data: { resolved: true, requires_approval: true, disruption_pct: 80,
                  planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } }
      end

      it "still records the refusal, with the target fields explicitly nil" do
        engine.decide(kind: "system.module_drift", severity: :medium,
                      payload: { "instance_id" => "00000000-0000-7000-8000-000000000000" },
                      fingerprint: "budget:missing:1")

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["refusal_class"]).to eq("disruption_budget")
        expect(event.payload["instance_id"]).to be_nil
        expect(event.payload["node_id"]).to be_nil
        expect(event.correlation_id).to be_nil
      end
    end

    context "the four fence lanes that dispatch no task" do
      # Each of these refuses through the SAME fence for the SAME instance, so
      # a shared `command` literal would collapse them into one hourly dedup
      # slot and silence three of the four — the honeypot quarantine among
      # them, which is a security lane. An earlier draft defaulted them all to
      # "actuate" and did exactly that.
      before do
        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:self_managed_target?).and_return(true)
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reboot",
                                       policy: "notify_and_proceed", is_active: true)
      end

      it "does not let one lane's refusal suppress another's on the same instance" do
        engine.decide(kind: "system.module_drift", severity: :medium,
                      payload: { "instance_id" => instance.id },
                      fingerprint: "lane:drift:#{instance.id}")
        engine.decide(kind: "system.instance_state_drifted", severity: :medium,
                      payload: { "instance_id" => instance.id, "expected_status" => "running",
                                 "actual_status" => "stopped" },
                      fingerprint: "lane:statedrift:#{instance.id}")

        commands = refusal_events.pluck(:payload).map { |p| p["command"] }
        expect(commands).to contain_exactly("sync_modules", "instance_state_converge")
      end
    end

    context "the refusal class vocabulary is closed" do
      it "refuses to write a row nobody can query for" do
        expect {
          engine.send(:emit_dispatch_refused!, account: account, instance: instance,
                                               command: "sync_modules", reason: "x",
                                               refusal_class: :not_a_real_class,
                                               source: "spec")
        }.to raise_error(ArgumentError, /unknown dispatch refusal class/)
      end

      it "names every class the six call sites actually emit" do
        expect(::System::Fleet::DispatchRefusalReporter::REFUSAL_CLASSES)
          .to include(:offline, :went_silent, :never_reported,
                      :foreign_control_plane, :self_managed,
                      :disruption_budget, :task_in_flight)
      end
    end

    context "the refusal CLASS is in the dedup key, not just the target" do
      # The whole point of keying on the class: two DIFFERENT diagnoses for the
      # same instance+command must both reach the operator. Keying on the
      # target alone would suppress the second and leave them acting on a stale
      # reason.
      it "does not suppress a different refusal class for the same target" do
        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:self_managed_target?).and_return(true)
        decide_drift_with("mixed:a:#{instance.id}")

        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:self_managed_target?).and_return(false)
        allow_any_instance_of(::System::Fleet::DecisionEngine)
          .to receive(:owned_by_this_control_plane?).and_return(false)
        decide_drift_with("mixed:b:#{instance.id}")

        expect(refusal_events.pluck(:payload).map { |p| p["refusal_class"] })
          .to contain_exactly("self_managed", "foreign_control_plane")
      end
    end
  end

  describe "the MCP producers, which never reach a decision event at all" do
    # `internal: true` is how this tool's own spec constructs an in-process
    # system caller; a bare userless construction is refused by the principal
    # check (IMP-9030413bc292).
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }

    before { Rails.cache.clear }

    def call(action, **rest)
      tool.execute(params: { action: action }.merge(rest))
    end

    context "system_refresh_instance_modules refusing an offline target" do
      before { instance.update!(status: "error") }

      it "still refuses" do
        result = call("system_refresh_instance_modules", instance_id: instance.id)
        expect(result[:success]).to be false
      end

      it "leaves a durable record, so 'how often are we refusing, and for what' is answerable" do
        call("system_refresh_instance_modules", instance_id: instance.id)

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["instance_id"]).to eq(instance.id)
        expect(event.payload["command"]).to eq("sync_modules")
        expect(event.source).to eq("mcp.refresh_instance_modules.dispatch_refused")
      end

      it "does NOT emit for the warning arm, which queues the task" do
        # A dispatch_refused row for work that WAS dispatched would be a lie in
        # the ledger, and the operator already has the warning in their reply.
        instance.update!(status: "stopped", last_heartbeat_at: Time.current)

        result = call("system_refresh_instance_modules", instance_id: instance.id)

        expect(result[:success]).to be true
        expect(result.dig(:data, :warning)).to be_present
        expect(refusal_events).to be_empty
      end
    end

    context "system_update_node's retemplate convergence skipping a dead instance" do
      it "emits for the instance it put in the skipped bucket" do
        instance.update!(last_heartbeat_at: 40.minutes.ago)

        tool.send(:dispatch_retemplate_convergence!, node)

        event = refusal_events.last
        expect(event).to be_present
        expect(event.payload["instance_id"]).to eq(instance.id)
        expect(event.payload["reason"]).to match(/went silent/)
        expect(event.source).to eq("mcp.retemplate_node.dispatch_refused")
      end

      it "stays silent for an instance it actually dispatched to" do
        # The negative oracle. Without it "emits for the skipped bucket" is
        # satisfied by an emitter that fires for every instance in the loop.
        instance.update!(last_heartbeat_at: Time.current)

        result = tool.send(:dispatch_retemplate_convergence!, node)

        expect(result[:dispatched]).to include(instance.id)
        expect(refusal_events).to be_empty
      end
    end
  end
end
