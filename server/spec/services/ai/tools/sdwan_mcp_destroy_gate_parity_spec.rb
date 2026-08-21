# frozen_string_literal: true

require "rails_helper"

# IMP-800b25c1cc45 — the SDWAN destroy family on the MCP surface was outside
# the gate regime while its REST twin was inside it.
#
# SdwanTool's own header claims the two gating surfaces "can no longer
# disagree", and that "an agent refused on one surface cannot reach for the
# other". For seven arms that claim was false in the worse direction: the
# controller routed the write through Ai::AutonomyGate and the tool arm called
# `destroy!` (or `save`) inline on the very same row.
#
#   REST (gated)                                    MCP (was inline)
#   NetworksController#destroy      sdwan.network_delete       system_sdwan_delete_network
#   PeersController#destroy         sdwan.peer_delete          system_sdwan_detach_peer
#   FirewallRulesController#destroy sdwan.firewall_rule_delete system_sdwan_delete_firewall_rule
#   VirtualIpsController#destroy    sdwan.virtual_ip_delete    system_sdwan_delete_virtual_ip
#   PortMappingsController#destroy  sdwan.port_mapping_delete  system_sdwan_delete_port_mapping
#   RoutePoliciesController#destroy sdwan.route_policy_delete  system_sdwan_delete_route_policy
#   RoutePoliciesController#create  sdwan.route_policy_create  system_sdwan_create_route_policy
#
# Nothing was missing but the call: every executor class, every ACTION_CATEGORY,
# every engine registration and every seeded policy row already existed and were
# already exercised through the controller. An operator who set
# sdwan.network_delete to require_approval got exactly that from the console and
# an unreviewed cascade destroy from the agent.
#
# This is a CLASS guard in the shape of sdwan_o6_write_gating_spec.rb, and for
# the same reason: the defect was never one arm. Each arm asserts three
# properties, because only the three together mean "gated":
#
#   1. :pending — the response is the gate's parked shape, and the row is
#      UNCHANGED. Shape alone would pass for an arm that wrote first and
#      reported `pending` afterwards.
#   2. approval — the operation the gate parked actually performs the write.
#      "It parks" and "the feature still works" are different claims, and a
#      params-key mismatch between arm and executor only shows up here.
#   3. :proceed — under an explicit notify_and_proceed row the arm writes
#      inline and answers the pre-gate body, so gating did not become refusing.
#
# The default policy resolution is require_approval and this tool carries no
# agent, so (1) and (2) run against the tier a fresh account gets with nothing
# stubbed; (3) seeds one operator row for the category under test.
RSpec.describe "SdwanTool destroy-family gate parity (IMP-800b25c1cc45)" do
  let(:account) { create(:account) }
  let(:tool)    { Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def expect_parked(response)
    expect(response[:success]).to be(true), "gated arm reported failure: #{response.inspect}"
    expect(response[:data][:pending]).to be(true),
                                         "arm wrote inline instead of parking for approval: #{response.inspect}"
    response
  end

  # Resolved by the response's own deferred_operation_id rather than "the latest
  # row", so an example that parks more than one cannot execute the wrong one.
  def approve!(response)
    deferred = Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
    expect(deferred).to be_present, "no deferred operation was parked: #{response.inspect}"
    deferred.execute_now!
    deferred
  end

  def parked_operation(response)
    Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
  end

  describe "system_sdwan_delete_network" do
    let!(:network) { create(:sdwan_network, account: account) }

    it "parks the cascade destroy instead of running it" do
      parked = expect_parked(call("system_sdwan_delete_network", network_id: network.id))

      expect(::Sdwan::Network.exists?(network.id)).to be(true),
                                                     "the network was destroyed before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.network_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeleteNetwork")
      expect(op.params["network_id"]).to eq(network.id)
    end

    it "destroys the network once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_delete_network", network_id: network.id))
      approve!(parked)

      expect(::Sdwan::Network.exists?(network.id)).to be(false)
    end

    it "destroys inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.network_delete")

      r = call("system_sdwan_delete_network", network_id: network.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:deleted]).to be(true)
      expect(r[:data][:id]).to eq(network.id)
      expect(::Sdwan::Network.exists?(network.id)).to be(false)
    end

    # AutonomyGate opens the DeferredOperation BEFORE it branches on policy, so
    # "no row was opened" proves the gate was never reached — i.e. the arm
    # refused on scope rather than parking an operation that could not run.
    it "refuses a network in another account without opening a gate row" do
      foreign = create(:sdwan_network, account: create(:account))

      expect {
        r = call("system_sdwan_delete_network", network_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::Network.exists?(foreign.id)).to be(true)
    end
  end

  describe "system_sdwan_detach_peer" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:peer)   { create(:sdwan_peer, account: account, network: network) }

    it "parks the detach instead of destroying the peer" do
      parked = expect_parked(call("system_sdwan_detach_peer", peer_id: peer.id))

      expect(::Sdwan::Peer.exists?(peer.id)).to be(true),
                                               "the peer was detached before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.peer_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeletePeer")
      expect(op.params["peer_id"]).to eq(peer.id)
    end

    it "destroys the peer once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_detach_peer", peer_id: peer.id))
      approve!(parked)

      expect(::Sdwan::Peer.exists?(peer.id)).to be(false)
    end

    it "detaches inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.peer_delete")

      r = call("system_sdwan_detach_peer", peer_id: peer.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:detached]).to be(true)
      expect(r[:data][:id]).to eq(peer.id)
      expect(::Sdwan::Peer.exists?(peer.id)).to be(false)
    end

    it "refuses a peer in another account without opening a gate row" do
      other_account = create(:account)
      foreign = create(:sdwan_peer, account: other_account,
                                    network: create(:sdwan_network, account: other_account))

      expect {
        r = call("system_sdwan_detach_peer", peer_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::Peer.exists?(foreign.id)).to be(true)
    end
  end

  describe "system_sdwan_delete_firewall_rule" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:rule)   { create(:sdwan_firewall_rule, account: account, network: network) }

    it "parks the destroy instead of removing the filter" do
      parked = expect_parked(call("system_sdwan_delete_firewall_rule", firewall_rule_id: rule.id))

      expect(::Sdwan::FirewallRule.exists?(rule.id)).to be(true),
                                                       "the rule was destroyed before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.firewall_rule_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeleteFirewallRule")
      expect(op.params["rule_id"]).to eq(rule.id)
    end

    it "destroys the rule once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_delete_firewall_rule", firewall_rule_id: rule.id))
      approve!(parked)

      expect(::Sdwan::FirewallRule.exists?(rule.id)).to be(false)
    end

    it "destroys inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.firewall_rule_delete")

      r = call("system_sdwan_delete_firewall_rule", firewall_rule_id: rule.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:deleted]).to be(true)
      expect(r[:data][:id]).to eq(rule.id)
      expect(::Sdwan::FirewallRule.exists?(rule.id)).to be(false)
    end

    it "refuses a rule in another account without opening a gate row" do
      other = create(:account)
      foreign = create(:sdwan_firewall_rule, account: other,
                                             network: create(:sdwan_network, account: other))

      expect {
        r = call("system_sdwan_delete_firewall_rule", firewall_rule_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::FirewallRule.exists?(foreign.id)).to be(true)
    end
  end

  describe "system_sdwan_delete_virtual_ip" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:vip)    { create(:sdwan_virtual_ip, network: network) }

    it "parks the destroy instead of releasing the floating address" do
      parked = expect_parked(call("system_sdwan_delete_virtual_ip", virtual_ip_id: vip.id))

      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(true),
                                                   "the VIP was destroyed before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.virtual_ip_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeleteVirtualIp")
      expect(op.params["vip_id"]).to eq(vip.id)
    end

    it "destroys the VIP once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_delete_virtual_ip", virtual_ip_id: vip.id))
      approve!(parked)

      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(false)
    end

    # A VIP with a LIVE holder is the case the inline arm wrapped in a
    # transaction, and the one where a half-applied destroy would leave a
    # dangling holder row behind. Asserted on the branch that still writes.
    it "destroys inline with its holder history under notify_and_proceed" do
      seed_operator_policy!("sdwan.virtual_ip_delete")
      peer = create(:sdwan_peer, account: account, network: network)
      assignment = ::Sdwan::VirtualIpAssignment.create!(
        virtual_ip: vip, peer: peer, assumed_at: Time.current,
        reason: "initial", released_at: nil
      )

      r = call("system_sdwan_delete_virtual_ip", virtual_ip_id: vip.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:deleted]).to be(true)
      expect(r[:data][:id]).to eq(vip.id)
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(false)
      expect(::Sdwan::VirtualIpAssignment.exists?(assignment.id)).to be(false)
    end

    # Sdwan::VirtualIp takes account_id from its network through a
    # before_validation hook rather than by direct assignment, so "scoped to the
    # account" is a derived property here and worth its own guard.
    it "refuses a VIP in another account without opening a gate row" do
      other = create(:account)
      foreign = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: other))

      expect {
        r = call("system_sdwan_delete_virtual_ip", virtual_ip_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::VirtualIp.exists?(foreign.id)).to be(true)
    end

    # Same holder shape on the branch that PARKS: the approval path must leave
    # the VIP and its live holder row intact until an operator acts.
    it "leaves a live holder row untouched while the destroy is parked" do
      peer = create(:sdwan_peer, account: account, network: network)
      assignment = ::Sdwan::VirtualIpAssignment.create!(
        virtual_ip: vip, peer: peer, assumed_at: Time.current,
        reason: "initial", released_at: nil
      )

      expect_parked(call("system_sdwan_delete_virtual_ip", virtual_ip_id: vip.id))

      # reload, not find_by: an inline destroy takes the assignment with it
      # through dependent: :destroy, and `find_by(...)&.released_at` would then
      # read nil — passing for the exact write this example exists to catch.
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(true)
      expect(assignment.reload.released_at).to be_nil
    end
  end

  describe "system_sdwan_delete_port_mapping" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:mapping) { create(:sdwan_port_mapping, account: account, network: network) }

    it "parks the destroy instead of tearing down the DNAT entry" do
      parked = expect_parked(call("system_sdwan_delete_port_mapping", port_mapping_id: mapping.id))

      expect(::Sdwan::PortMapping.exists?(mapping.id)).to be(true),
                                                         "the mapping was destroyed before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.port_mapping_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeletePortMapping")
      expect(op.params["mapping_id"]).to eq(mapping.id)
    end

    it "destroys the mapping once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_delete_port_mapping", port_mapping_id: mapping.id))
      approve!(parked)

      expect(::Sdwan::PortMapping.exists?(mapping.id)).to be(false)
    end

    # port_mapping_in_account scopes through joins(:network) on the NETWORK's
    # account_id rather than a column on the mapping, and answers nil rather
    # than raising — a different refusal path from the other arms here.
    it "refuses a mapping in another account without opening a gate row" do
      other = create(:account)
      foreign_network = create(:sdwan_network, account: other)
      foreign = create(:sdwan_port_mapping, account: other, network: foreign_network)

      expect {
        r = call("system_sdwan_delete_port_mapping", port_mapping_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::PortMapping.exists?(foreign.id)).to be(true)
    end

    it "destroys inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.port_mapping_delete")

      r = call("system_sdwan_delete_port_mapping", port_mapping_id: mapping.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:deleted]).to be(true)
      expect(r[:data][:id]).to eq(mapping.id)
      expect(::Sdwan::PortMapping.exists?(mapping.id)).to be(false)
    end
  end

  describe "system_sdwan_delete_route_policy" do
    let!(:policy) { create(:sdwan_route_policy, account: account) }

    it "parks the destroy instead of dropping the BGP filter" do
      parked = expect_parked(call("system_sdwan_delete_route_policy", route_policy_id: policy.id))

      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(true),
                                                        "the policy was destroyed before any approval"
      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.route_policy_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeleteRoutePolicy")
      expect(op.params["policy_id"]).to eq(policy.id)
    end

    it "destroys the policy once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_delete_route_policy", route_policy_id: policy.id))
      approve!(parked)

      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(false)
    end

    it "destroys inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.route_policy_delete")

      r = call("system_sdwan_delete_route_policy", route_policy_id: policy.id)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:deleted]).to be(true)
      expect(r[:data][:id]).to eq(policy.id)
      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(false)
    end

    it "refuses a policy in another account without opening a gate row" do
      foreign = create(:sdwan_route_policy, account: create(:account))

      expect {
        r = call("system_sdwan_delete_route_policy", route_policy_id: foreign.id)
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(::Sdwan::RoutePolicy.exists?(foreign.id)).to be(true)
    end
  end

  describe "system_sdwan_create_route_policy" do
    let(:create_params) do
      { name: "gated-policy", scope: "account", direction: "import",
        statements: [ { "action" => { "type" => "accept" } } ] }
    end

    it "parks the create instead of writing the row" do
      expect {
        parked = expect_parked(call("system_sdwan_create_route_policy", **create_params))

        op = parked_operation(parked)
        expect(op.action_category).to eq("sdwan.route_policy_create")
        expect(op.executor_class).to eq("Sdwan::Executors::CreateRoutePolicy")
        expect(op.params["attributes"]["name"]).to eq("gated-policy")
      }.not_to change(::Sdwan::RoutePolicy, :count)
    end

    it "creates the policy once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_create_route_policy", **create_params))

      expect { approve!(parked) }.to change(::Sdwan::RoutePolicy, :count).by(1)
      expect(::Sdwan::RoutePolicy.where(account_id: account.id).last.name).to eq("gated-policy")
    end

    it "creates inline and renders the row under notify_and_proceed" do
      seed_operator_policy!("sdwan.route_policy_create")

      r = call("system_sdwan_create_route_policy", **create_params)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:route_policy][:name]).to eq("gated-policy")
      expect(::Sdwan::RoutePolicy.where(account_id: account.id).count).to eq(1)
    end

    # A payload that could never save must not park an approval an operator has
    # to dispose of — the same validate-before-gate contract the REST twin keeps.
    it "refuses an invalid payload up front without opening a gate row" do
      expect {
        expect {
          r = call("system_sdwan_create_route_policy", **create_params.merge(name: ""))
          expect(r[:success]).to be(false)
        }.not_to change(Ai::DeferredOperation, :count)
      }.not_to change(::Sdwan::RoutePolicy, :count)
    end
  end
end
