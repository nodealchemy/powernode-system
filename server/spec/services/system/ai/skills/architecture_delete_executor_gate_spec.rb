# frozen_string_literal: true

require "rails_helper"

# c13-2 batch E-D. system_delete_architecture is gated at the TOOL
# (Ai::Executors::DeferredToolCall, category system.architecture.delete), and
# ArchitectureDeleteExecutor reaches that tool through CrudFactory. The executor
# must therefore not park a gate of its own: with both, one approved delete
# produced a SECOND pending DeferredToolCall and the row survived. Nothing here
# stubs the tool.
RSpec.describe System::Ai::Skills::ArchitectureDeleteExecutor do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner
  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }
  let(:caller_user) do
    create(:user, account: account, permissions: %w[system.architectures.manage system.architectures.read])
  end
  let!(:architecture) { create(:system_node_architecture) }

  def run_executor
    described_class.new(account: account, user: caller_user).execute(architecture_id: architecture.id)
  end

  def approve!(deferred_operation_id)
    operation = Ai::DeferredOperation.find(deferred_operation_id)
    decided = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                                   .approve(request: operation.approval_request, approver: approver,
                                                            origin: Ai::ApprovalDecision::REST_SESSION)
    expect(decided).to be(true)
    operation.reload
  end

  it "declares no gate of its own, keeping the seeded category" do
    expect(described_class.gate_required?).to be(false)
    expect(described_class.action_category).to eq("system.architecture.delete")
  end

  it "parks exactly one operation, the tool's, and deletes nothing yet" do
    result = run_executor

    # Top-level pending (BaseSkillExecutor#pending_result's shape), so a caller
    # reading only success cannot report an unexecuted delete as done.
    expect(result).to include(success: true, pending: true)
    expect(result[:data]).to include(pending: true)
    operations = Ai::DeferredOperation.all.to_a
    expect(operations.size).to eq(1)
    expect(operations.first.executor_class).to eq("Ai::Executors::DeferredToolCall")
    expect(operations.first.action_category).to eq("system.architecture.delete")
    expect(System::NodeArchitecture.where(id: architecture.id)).to exist
  end

  it "deletes on a single approval and creates no second pending operation" do
    parked = run_executor
    operation = approve!(parked.dig(:data, :deferred_operation_id))

    expect(operation.status).to eq("completed")
    expect(operation.result.with_indifferent_access).not_to include(success: false)
    expect(System::NodeArchitecture.where(id: architecture.id)).not_to exist
    expect(Ai::DeferredOperation.count).to eq(1)
    expect(Ai::DeferredOperation.where(status: "pending")).to be_empty
  end

  it "still refuses a canonical architecture, leaving it intact" do
    canonical = create(:system_node_architecture, :canonical)
    result = described_class.new(account: account, user: caller_user).execute(architecture_id: canonical.id)
    approve!(result.dig(:data, :deferred_operation_id)) if result[:pending]

    expect(System::NodeArchitecture.where(id: canonical.id)).to exist
  end
end
