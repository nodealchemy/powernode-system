# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Bgp::RoutePolicyCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::RoutePolicy.where(account_id: account.id).destroy_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "rpc-net-#{SecureRandom.hex(3)}", routing_protocol: "ibgp") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:peer1) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:peer2) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "empty output when no policies match" do
    it "returns zeroed lists" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:prefix_lists]).to be_empty
      expect(out[:route_maps]).to be_empty
      expect(out[:neighbor_assignments]).to be_empty
    end
  end

  describe "v4 + v6 prefix_in match emits two prefix-lists" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "prefix_in" => ["10.0.0.0/8", "fd00::/16"] },
            "action" => { "type" => "accept", "set_local_pref" => 200 } }
        ]
      )
    end

    it "splits v4 and v6 into separate prefix-lists" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:prefix_lists]).to include(a_string_matching(/permit 10\.0\.0\.0\/8/))
      expect(out[:ipv6_prefix_lists]).to include(a_string_matching(/permit fd00::\/16/))
    end

    it "applies the policy to every other peer's neighbor assignment" do
      out = described_class.compile_for_peer(peer1)
      neighbor_addr = peer2.assigned_address.to_s.split("/").first
      expect(out[:neighbor_assignments][neighbor_addr]).to include(import: a_string_matching(/-import\z/))
    end

    it "emits a route-map clause with set local-preference 200" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:route_maps].join).to include("set local-preference 200")
    end
  end

  describe "as_path_regex match → as-path access-list + match line" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-asp-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "as_path_regex" => "^4200000000_" },
            "action" => { "type" => "reject" } }
        ]
      )
    end

    it "emits an as-path access-list referenced by match line" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:as_path_lists]).to include(a_string_matching(/permit \^4200000000_/))
      expect(out[:route_maps].join).to include("match as-path")
    end

    it "uses 'deny' as the route-map terminator for action.type=reject" do
      out = described_class.compile_for_peer(peer1)
      first_clause = out[:route_maps].first
      expect(first_clause).to match(/route-map .* deny 10/)
    end
  end

  describe "default-deny tail" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-tail-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [{ "match" => {}, "action" => { "type" => "accept" } }]
      )
    end

    it "appends an explicit final deny clause" do
      out = described_class.compile_for_peer(peer1)
      tail = out[:route_maps].last
      expect(tail).to match(/route-map .* deny \d+/)
    end
  end

  describe "scope=peer policies attach only to the matching peer" do
    let!(:peer_policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-scoped-#{SecureRandom.hex(3)}",
        scope: "peer", scope_resource_id: peer1.id,
        direction: "export",
        statements: [
          { "match" => { "prefix_in" => ["192.0.2.0/24"] },
            "action" => { "type" => "accept" } }
        ]
      )
    end

    it "is included in compile output for the matching peer" do
      out = described_class.compile_for_peer(peer1)
      neighbor_addr = peer2.assigned_address.to_s.split("/").first
      expect(out[:neighbor_assignments][neighbor_addr]).to include(export: a_string_matching(/-export\z/))
    end

    it "is not applied to a non-matching peer" do
      out = described_class.compile_for_peer(peer2)
      assignments = out[:neighbor_assignments]
      assignments.each_value do |a|
        # peer2's compile output should NOT carry peer1's peer-scoped policy
        # as an inbound route-map for any neighbor.
        expect(a[:export]).not_to match(/p-scoped/) if a[:export]
      end
    end
  end
end
