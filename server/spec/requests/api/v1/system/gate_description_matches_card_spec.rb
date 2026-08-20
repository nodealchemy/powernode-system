# frozen_string_literal: true

require "rails_helper"

# IMP-1dd3ed2b5353 — ONE APPROVAL, TWO LABELS.
#
# The approvals API serves both fields for the same operation: `description`,
# frozen at gate time by the controller, and `preview[:impact]`, recomputed from
# the executor. IMP-4a5094b22df0 taught ExecuteTask#impact to name the operable
# ("stop on System::NodeInstance web-1"), but every gate site kept building its
# own raw "stop on System::NodeInstance#<uuid>" — so one card shows an approver
# two different labels for the thing they are deciding about.
#
# Same shape IMP-ee57d0fbe859 fixed for DeletePeer by centralising on one label
# source, and the convention already exists in NodeInstanceGating itself:
# #create_instance_operation builds "Stop node instance: web-1" for the UNGATED
# path. Only the gated paths were left on the raw pair.
#
# This is a DRIFT GUARD, one example per gate surface. It asserts the two
# surfaces agree, not what either says — so it keeps holding if the label
# wording changes, and fails the moment a new gate site invents its own.
RSpec.describe "gate description matches the approval card", type: :request do
  let(:user) do
    user_with_permissions("system.infra_tasks.create", "system.instances.control",
                          "system.nodes.read", "system.instances.read")
  end
  let(:account)  { user.account }
  let(:node)     { create(:system_node, account: account) }
  let!(:instance) { create(:system_node_instance, node: node, name: "web-1") }

  # A fresh spec account has no InterventionPolicy rows, so the service falls
  # through to its require_approval default — which is the branch that parks a
  # deferred operation and therefore the one with a card to compare against.
  def latest_operation
    ::Ai::DeferredOperation.order(created_at: :desc).first
  end

  def assert_surfaces_agree!(op)
    expect(op).to be_present, "no deferred operation was parked — nothing to compare"
    card = op.preview
    expect(card[:impact]).to be_present, "the card has no impact line to agree with"
    expect(op.description).to eq(card[:impact]),
                              "the approver sees two labels for one operation:\n" \
                              "  description: #{op.description.inspect}\n" \
                              "  card impact: #{card[:impact].inspect}"
  end

  it "agrees on the tasks#create surface" do
    post "/api/v1/system/tasks",
         params: { task: { command: "sync", operable_type: "System::NodeInstance",
                           operable_id: instance.id } }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")

    assert_surfaces_agree!(latest_operation)
  end

  it "agrees on the instance lifecycle surface (gate_or_execute)" do
    # node_instances is nested under nodes on purpose (NodeInstancesController
    # #set_node always runs), so the flat path 404s.
    post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/stop",
         headers: auth_headers_for(user)

    assert_surfaces_agree!(latest_operation)
  end
end
