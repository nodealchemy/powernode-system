# frozen_string_literal: true

require "rails_helper"

# Round-3 L-1: an executor built by a tool (Ai::Tools::BaseTool#build_skill_executor)
# is a step of that call. Its gate is handed the call's driver explicitly, even
# nil on a stand-in door, so it never falls back to @user (on the agent bridge,
# the agent's creator). The driver and door travel to nested peers and tools.
RSpec.describe System::Ai::Skills::BaseSkillExecutor, "driving user" do
  let(:account) { create(:account) }
  let(:creator) { create(:user, account: account) }
  let(:runner) { create(:user, account: account) }

  let(:gated_class) do
    Class.new(described_class) do
      skill_descriptor(
        name: "zz_driver_fixture", description: "driver fixture", category: "fleet", requires_approval: true,
        inputs: { widget_id: { type: "string", required: true } }, outputs: { widget_id: :string }
      )

      protected

      def perform(widget_id:)
        success(widget_id: widget_id)
      end
    end
  end

  before do
    stub_const("ZzDriverFixtureExecutor", gated_class)
    Ai::InterventionPolicy.create!(account: account, action_category: "system.zz_driver_fixture", scope: "global",
                                   policy: "require_approval", priority: 5, is_active: true)
  end

  def gate_kwargs_for(executor)
    seen = nil
    allow(Ai::AutonomyGate).to receive(:evaluate).and_wrap_original { |m, **kw| seen = kw; m.call(**kw) }
    executor.execute(widget_id: "w1")
    seen
  end

  it "hands the gate an explicit nil driver and the parent's door from a stand-in door" do
    executor = ZzDriverFixtureExecutor.new(account: account, user: creator)
    executor.driving_user = nil
    executor.parent_call_origin = Ai::Tools::CallOrigin::AGENT_BRIDGE

    kwargs = gate_kwargs_for(executor)
    expect(kwargs).to include(driving_user: nil, call_origin: Ai::Tools::CallOrigin::AGENT_BRIDGE,
                              requested_by: creator)
  end

  it "hands the gate the real driver when one is known" do
    executor = ZzDriverFixtureExecutor.new(account: account, user: creator)
    executor.driving_user = runner
    expect(gate_kwargs_for(executor)).to include(driving_user: runner)
  end

  it "leaves the gate to decide when nobody set a driver (a direct, non-tool door)" do
    kwargs = gate_kwargs_for(ZzDriverFixtureExecutor.new(account: account, user: creator))
    expect(kwargs).not_to have_key(:driving_user)
  end

  it "carries the driver and door to a nested peer and a nested tool" do
    parent = ZzDriverFixtureExecutor.new(account: account, user: creator)
    parent.driving_user = nil
    parent.parent_call_origin = Ai::Tools::CallOrigin::AGENT_BRIDGE

    peer = parent.send(:executor, ZzDriverFixtureExecutor)
    expect(peer.instance_variable_get(:@driving_user_known)).to be(true)
    expect(peer.driving_user).to be_nil
    expect(peer.parent_call_origin).to eq(Ai::Tools::CallOrigin::AGENT_BRIDGE)

    nested_tool = parent.send(:tool, Ai::Tools::SystemFleetTool)
    expect(nested_tool.instance_variable_defined?(:@driving_user)).to be(true)
    expect(nested_tool.instance_variable_get(:@driving_user)).to be_nil
  end
end
