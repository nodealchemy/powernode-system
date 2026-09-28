# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — the gated executor Ai::AutonomyGate dispatches to for
# system.instance.out_of_band_exec, on both the immediate (auto_approve) and
# approved-later paths (both go through Ai::DeferredOperation#execute_now!,
# which is what this exercises directly — see approval_request_spec.rb's
# 'post-approval execution outcome' block in core for the full cascade
# through an approval decision, using the same stub-executor pattern this
# file's ExplodingPerformer/SucceedingPerformer analogues mirror).
RSpec.describe System::Executors::OutOfBandExec do
  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }
  let(:agent)    { create(:ai_agent, account: account) }

  def gated_operation(agent: nil, **extra_params)
    ::Ai::DeferredOperation.create!(
      account: account, ai_agent: agent,
      action_category: ::System::OutOfBandExecService::ACTION_CATEGORY,
      executor_class: "System::Executors::OutOfBandExec",
      params: { instance_id: instance.id, command: "uptime" }.merge(extra_params)
    )
  end

  describe "the ordinary case" do
    it "calls OutOfBandExecService.execute! and completes the operation on success" do
      allow(::System::OutOfBandExecService).to receive(:execute!).and_return(
        { success: true, exit_code: 0, timed_out: false, truncated: false }
      )
      op = gated_operation

      op.execute_now!

      expect(op.reload.status).to eq("completed")
      expect(::System::OutOfBandExecService).to have_received(:execute!).with(
        instance: instance, command: "uptime", sudo: true, pinned_ip: nil,
        agent_id: nil, deferred_operation: op, call_origin: nil
      )
    end

    it "threads agent_id, pinned_ip and call_origin through to the service" do
      allow(::System::OutOfBandExecService).to receive(:execute!).and_return({ success: true })
      op = gated_operation(agent: agent, pinned_ip: "10.0.0.9", call_origin: "mcp_oauth")

      op.execute_now!

      expect(::System::OutOfBandExecService).to have_received(:execute!).with(
        hash_including(agent_id: agent.id, pinned_ip: "10.0.0.9", call_origin: "mcp_oauth",
                       deferred_operation: op)
      )
    end

    it "passes sudo: false through when the caller requested it" do
      allow(::System::OutOfBandExecService).to receive(:execute!).and_return({ success: true })
      op = gated_operation(sudo: false)

      op.execute_now!

      expect(::System::OutOfBandExecService).to have_received(:execute!).with(hash_including(sudo: false))
    end
  end

  describe "a StatementInvalid raised inside the service" do
    it "leaves the operation failed, records the message, and re-raises" do
      allow(::System::OutOfBandExecService).to receive(:execute!)
        .and_raise(ActiveRecord::StatementInvalid, "connection reset by peer")
      op = gated_operation

      expect { op.execute_now! }.to raise_error(ActiveRecord::StatementInvalid)

      expect(op.reload.status).to eq("failed")
      expect(op.error_message).to include("connection reset by peer")
    end
  end

  describe "a System::OutOfBandExecService::Refused raised before anything runs" do
    it "leaves the operation failed and re-raises, matching every other executor refusal" do
      allow(::System::OutOfBandExecService).to receive(:execute!)
        .and_raise(::System::OutOfBandExecService::Refused, "refusing: INV-1")
      op = gated_operation

      expect { op.execute_now! }.to raise_error(::System::OutOfBandExecService::Refused)
      expect(op.reload.status).to eq("failed")
      expect(op.error_message).to include("refusing: INV-1")
    end
  end

  describe "cross-account instance resolution" do
    it "refuses an instance belonging to a different account than the operation" do
      foreign_account = create(:account)
      foreign_node = create(:system_node, account: foreign_account)
      foreign_instance = create(:system_node_instance, :running, node: foreign_node, account: foreign_account)
      op = gated_operation
      op.update_columns(params: { instance_id: foreign_instance.id, command: "uptime" })

      expect { op.reload.execute_now! }.to raise_error(::Ai::DeferredOperation::CrossAccountError)
      expect(op.reload.status).to eq("failed")
    end
  end
end
