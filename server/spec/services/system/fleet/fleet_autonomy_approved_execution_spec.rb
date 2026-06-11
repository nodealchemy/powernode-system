# frozen_string_literal: true

require "rails_helper"

# Audit F3-01 — the require_approval lane was a dead end: approving a
# system_fleet ApprovalRequest executed nothing (source_type
# "system_fleet" is not constantizable, so the generic
# notify_source_of_decision hook can never fire, and no code polled
# approved fleet requests). Operator decision 2026-06-11: tick-polling
# model — FleetAutonomyService#tick! consumes approved-unexecuted
# requests, routes them through DecisionEngine's applier table, and
# stamps request_data["execution"] with the result.
RSpec.describe "FleetAutonomyService approved-action execution (F3-01)" do
  before do
    skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  let(:chain) do
    create(:ai_approval_chain, account: account,
           trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
  end

  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance) do
    create(:system_node_instance, :running, node: node, variety: "cloud",
           cloud_instance_id: "vm-silent-1")
  end

  def approved_request!(payload:, action_category: "system.instance_reprovision")
    Ai::ApprovalRequest.create!(
      account: account, approval_chain: chain, source_type: "system_fleet",
      status: "approved", description: "Fleet action: #{action_category}",
      request_data: {
        "action_category" => action_category,
        "payload" => payload,
        "agent_role" => "fleet"
      }
    )
  end

  describe "#execute_approved_actions!" do
    it "executes an approved instance_reprovision as a provider-side reboot and stamps the result" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: { action: "reboot" }))

      request = approved_request!(payload: {
        "instance_id" => instance.id,
        "signal_kind" => "system.instance_silent",
        "signal_severity" => "high"
      })

      executed = service.execute_approved_actions!(engine)

      expect(System::InstanceControlService).to have_received(:execute)
        .with(hash_including(instance: instance, action: "reboot"))
      expect(executed).to contain_exactly(hash_including(request_id: request.id, applied: true))

      execution = request.reload.request_data["execution"]
      expect(execution["applied"]).to be true
      expect(execution["executed_at"]).to be_present
    end

    it "does not re-execute an already-stamped request on the next poll" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: {}))
      approved_request!(payload: {
        "instance_id" => instance.id, "signal_kind" => "system.instance_silent"
      })

      service.execute_approved_actions!(engine)
      second_pass = service.execute_approved_actions!(engine)

      expect(second_pass).to be_empty
      expect(System::InstanceControlService).to have_received(:execute).once
    end

    it "stamps applied:false with a reason for kinds without an applier (never a silent no-op)" do
      request = approved_request!(
        action_category: "system.observation",
        payload: { "signal_kind" => "system.unknown_kind", "thing" => "x" }
      )

      executed = service.execute_approved_actions!(engine)

      expect(executed).to contain_exactly(hash_including(request_id: request.id, applied: false))
      execution = request.reload.request_data["execution"]
      expect(execution["applied"]).to be false
      expect(execution["reason"]).to match(/no applier/)
    end

    it "stamps pre-F3-01 requests (no signal_kind) as unexecutable without raising" do
      request = approved_request!(payload: { "instance_id" => instance.id })

      expect { service.execute_approved_actions!(engine) }.not_to raise_error

      execution = request.reload.request_data["execution"]
      expect(execution["applied"]).to be false
      expect(execution["reason"]).to match(/signal_kind/)
    end

    it "isolates a raising execution — remaining requests still run" do
      bad  = approved_request!(payload: { "instance_id" => "nope", "signal_kind" => "system.instance_silent" })
      good = approved_request!(payload: { "instance_id" => instance.id, "signal_kind" => "system.instance_silent" })
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: {}))
      allow(engine).to receive(:execute_approved!).and_wrap_original do |original, req|
        raise "boom" if req.id == bad.id
        original.call(req)
      end

      executed = service.execute_approved_actions!(engine)

      expect(executed.size).to eq(2)
      expect(bad.reload.request_data.dig("execution", "error")).to match(/boom/)
      expect(good.reload.request_data.dig("execution", "applied")).to be true
    end
  end

  describe "signal identity stamping at approval-creation time" do
    it "skill_metadata_payload carries signal_kind/severity/fingerprint for later replay" do
      signal = System::Fleet::Signal.from_hash(
        "kind" => "system.instance_silent", "severity" => "high",
        "payload" => { "instance_id" => instance.id }, "fingerprint" => "fp-123"
      )

      payload = engine.send(:skill_metadata_payload, signal, nil)

      expect(payload["signal_kind"]).to eq("system.instance_silent")
      expect(payload["signal_severity"]).to eq("high")
      expect(payload["signal_fingerprint"]).to eq("fp-123")
      expect(payload["instance_id"]).to eq(instance.id)
    end
  end

  describe "tick! integration" do
    it "consumes approved requests during the tick" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: {}))
      allow(service).to receive(:collect_signals).and_return([ [], [] ])
      allow(service).to receive(:collect_project_metrics!)
      approved_request!(payload: {
        "instance_id" => instance.id, "signal_kind" => "system.instance_silent"
      })

      result = service.tick!

      expect(result[:approved_executed]).to eq(1)
      expect(System::InstanceControlService).to have_received(:execute).once
    end
  end
end
