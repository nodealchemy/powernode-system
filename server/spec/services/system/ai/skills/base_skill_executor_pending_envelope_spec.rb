# frozen_string_literal: true

require "rails_helper"

# APO-1f (IMP-117b34656921) — a PARKED executor must speak the platform's
# pending envelope, not a failure.
#
# APO-1c gave BaseSkillExecutor#gate_action! a :pending arm that returned
# `{ success: false, error: "Approval required: ..." }`. APO-8a (core) had
# already declared the platform's third outcome on every tool's outputSchema —
# `success: true` with a `data.pending` body (Ai::Tools::BaseTool
# ::PENDING_RESULT_PROPERTIES) — and SdwanTool emits exactly that at its own
# gate sites. So the SAME parked category answered "failed" through the ingress
# tool / REST doors and "pending" through the SDWAN door, and an agent reading
# the failure retries an action an operator is still deciding.
RSpec.describe "System::Ai::Skills::BaseSkillExecutor pending envelope" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  let(:gated_class) do
    Class.new(System::Ai::Skills::BaseSkillExecutor) do
      def self.performed_on
        @performed_on ||= []
      end

      skill_descriptor(
        name: "zz_pending_fixture",
        description: "pending-envelope fixture",
        category: "fleet",
        requires_approval: true,
        inputs: { widget_id: { type: "string", required: true } },
        outputs: { widget_id: :string }
      )

      protected

      def perform(widget_id:)
        self.class.performed_on << object_id
        success(widget_id: widget_id)
      end
    end
  end

  before { stub_const("ZzPendingFixtureExecutor", gated_class) }

  def require_approval!
    Ai::InterventionPolicy.create!(
      account: account, action_category: "system.zz_pending_fixture",
      scope: "action_type", policy: "require_approval", priority: 10, is_active: true
    )
  end

  subject(:result) do
    require_approval!
    ZzPendingFixtureExecutor.new(account: account, user: user).execute(widget_id: "w-1")
  end

  it "reports success: true — the CALL succeeded, the action is parked" do
    expect(result[:success]).to be true
  end

  it "carries a top-level pending marker for in-process consumers" do
    expect(result[:pending]).to be true
  end

  it "still does not reach #perform" do
    result
    expect(ZzPendingFixtureExecutor.performed_on).to be_empty
  end

  it "answers exactly the platform's declared pending body" do
    expect(result[:data].keys.map(&:to_s).sort)
      .to eq(Ai::Tools::BaseTool::PENDING_RESULT_PROPERTIES.keys.map(&:to_s).sort)
  end

  it "names the category, the approval request and the deferred operation" do
    data = result[:data]
    op = Ai::DeferredOperation.where(account: account).last

    expect(data[:pending]).to be true
    expect(data[:action_category]).to eq("system.zz_pending_fixture")
    expect(data[:deferred_operation_id]).to eq(op.id)
    expect(data[:approval_request_id]).to eq(op.approval_request&.id)
    expect(data[:message]).to match(/Approval required: system\.zz_pending_fixture/)
  end

  # The MCP door that already spoke this shape at its OWN gate sites, and the
  # one that did not. Both must now hand a caller the same envelope.
  describe "the MCP doors" do
    it "SdwanTool#run_skill_executor passes the pending body through" do
      require_approval!
      tool = ::Ai::Tools::SdwanTool.new(account: account, user: user)
      out = tool.send(:run_skill_executor, ZzPendingFixtureExecutor, widget_id: "w-1")

      expect(out[:success]).to be true
      expect(out.dig(:data, :pending)).to be true
      expect(out.dig(:data, :action_category)).to eq("system.zz_pending_fixture")
    end

    it "SystemIngressTool#run_executor passes the pending body through" do
      require_approval!
      stub_const(
        "Ai::Tools::SystemIngressTool::ACTION_EXECUTORS",
        ::Ai::Tools::SystemIngressTool::ACTION_EXECUTORS.merge(
          "zz_pending_action" => "ZzPendingFixtureExecutor"
        )
      )
      tool = ::Ai::Tools::SystemIngressTool.new(account: account, user: user)
      out = tool.send(:run_executor, "zz_pending_action", { widget_id: "w-1" })

      expect(out[:success]).to be true
      expect(out.dig(:data, :pending)).to be true
    end

    # DRIFT ORACLE for the claim in Ai::Tools::BaseTool.pending_payload's
    # docstring: three producers, ONE spelling. A second hand-spelling of this
    # body is exactly what let the same parked category answer "pending"
    # through one door and "failed" through another, so a key added to the
    # builder (or to PENDING_RESULT_PROPERTIES beside it) must appear here
    # without anyone remembering to copy it.
    it "SdwanTool's own gate arm emits the shared pending body, not a second spelling" do
      operation = instance_double("Ai::DeferredOperation", id: "op-drift")
      approval  = instance_double("Ai::ApprovalRequest", id: "req-drift")
      gate = instance_double(
        "Ai::AutonomyGate::Result",
        decision: :pending, deferred_operation: operation, approval_request: approval
      )
      allow(::Ai::AutonomyGate).to receive(:evaluate).and_return(gate)

      tool = ::Ai::Tools::SdwanTool.new(account: account, user: user)
      out = tool.send(
        :gated_result,
        action_category: "system.sdwan.zz_drift", executor_class: "ZzPendingFixtureExecutor",
        executor_params: {}, description: "drift", pending_extra: { grant_id: "g-1" }
      ) { {} }

      expect(out[:success]).to be true
      expect(out[:data]).to eq(
        ::Ai::Tools::BaseTool.pending_payload(
          action_category: "system.sdwan.zz_drift",
          deferred_operation: operation, approval_request: approval
        ).merge(grant_id: "g-1")
      )
    end
  end
end
