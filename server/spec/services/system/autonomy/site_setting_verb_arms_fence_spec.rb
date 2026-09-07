# frozen_string_literal: true

require "rails_helper"

# IMP-7723206bc137, the half of the acceptance that cannot live in the core
# suite: core owns Ai::Tools::SiteSettingTool, but core must never name
# System::Autonomy::SelfManagementFence (core-purity-check.sh blocks exactly
# that, and blocked an earlier draft of the tool for it). So the END-TO-END
# oracle — write the key through the MCP verb, watch the fence change state —
# belongs here, in the extension that owns both the key and the fence.
#
# WHAT THIS PINS, and why the absence of an error would not have been enough:
# the fence is nil-safe-inert by design. `self_managed_target?` returns false
# for every target while self_hosting_node_id is unset, so a green run against
# an unconfigured fence proves nothing at all — it is indistinguishable from a
# fence that never refuses anything. The assertion is therefore the REFUSAL
# ITSELF, observed to be absent before the write and present after it.
RSpec.describe "site_setting_set arms the self-management fence" do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:tool) { ::Ai::Tools::SiteSettingTool.new(account: account, user: admin) }

  # A bare consumer of the fence, so the oracle reads the fence's own verdict
  # rather than any one actuator's handling of it.
  let(:fence_consumer) do
    Class.new do
      include ::System::Autonomy::SelfManagementFence
    end.new
  end

  before do
    allow(admin).to receive(:has_permission?).and_return(false)
    allow(admin).to receive(:has_permission?).with("admin.access").and_return(true)
  end

  def set_key!(value)
    tool.execute(
      params: {
        action: "site_setting_set",
        key: ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
        value: value
      }
    )
  end

  it "registers the key the fence reads, taking it from the fence's own constant" do
    expect(::Ai::Tools::SiteSettingTool.operator_configurable_keys)
      .to include(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY)
  end

  it "is inert before the write — the precondition that makes the next example meaningful" do
    expect(fence_consumer.self_managed_target?(instance)).to be false
    expect { fence_consumer.assert_not_self_managed!(instance, action: "terminate") }.not_to raise_error
  end

  it "goes live once the key is written through the MCP verb" do
    result = set_key!(node.id)
    expect(result[:success]).to be true

    # A fresh consumer: the fence memoizes self_hosting_node_id for the life of
    # the including object, so reusing the one from the previous example would
    # read a cached nil and pass for the wrong reason.
    live = Class.new { include ::System::Autonomy::SelfManagementFence }.new

    expect(live.self_managed_target?(instance)).to be true
    expect { live.assert_not_self_managed!(instance, action: "terminate") }
      .to raise_error(::System::Autonomy::SelfManagementFence::SelfManagementViolation, /INV-1/)
  end

  it "arms the fence for the NODE, not merely the one instance that named it" do
    set_key!(node.id)
    sibling = create(:system_node_instance, :running, node: node)

    live = Class.new { include ::System::Autonomy::SelfManagementFence }.new

    expect(live.self_managed_target?(sibling)).to be true
  end

  it "leaves an unrelated node unfenced, so the write is not a global kill switch" do
    other_node = create(:system_node, account: account)
    other_instance = create(:system_node_instance, :running, node: other_node)

    set_key!(node.id)
    live = Class.new { include ::System::Autonomy::SelfManagementFence }.new

    expect(live.self_managed_target?(other_instance)).to be false
  end

  # The refusal that matters most on this key: a node must not be able to
  # declare ITSELF the self-hosting node, nor clear the declaration. Asserted
  # here as well as in the core suite because the consequence is
  # extension-side — a node that could write this key could disarm the fence
  # protecting the plane it hosts.
  it "refuses an instance principal, and the fence stays inert" do
    node_tool = ::Ai::Tools::SiteSettingTool.new(account: account, user: nil)
    node_tool.instance_authorized = true

    result = node_tool.execute(
      params: {
        action: "site_setting_set",
        key: ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
        value: node.id
      }
    )

    expect(result[:success]).to be false
    # The oracle is the fence's state, not the error string.
    live = Class.new { include ::System::Autonomy::SelfManagementFence }.new
    expect(live.self_managed_target?(instance)).to be false
  end
end
