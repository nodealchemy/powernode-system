# frozen_string_literal: true

require "rails_helper"

# IMP-2f34679b6b73 — a host that belongs to two iBGP networks gets ONE global
# `vtysh show bgp summary` from the agent, replayed once per network id. The
# writer used to accept each replay at face value, so network B's local peer
# was credited with network A's live neighbours: sessions the platform never
# measured for B, which the BGP health sensor then senses and the remediate
# executor acts on.
#
# The writer is the last place that can tell the difference without a rebuilt
# agent: a network's iBGP neighbours are always peers of that network, so their
# overlay addresses always fall inside that network's own /64.
RSpec.describe Sdwan::BgpSessionWriter, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::BgpSession.delete_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:net_a) do
    Sdwan::Network.create!(account_id: account.id, name: "mis-a-#{SecureRandom.hex(3)}", routing_protocol: "ibgp")
  end
  let!(:net_b) do
    Sdwan::Network.create!(account_id: account.id, name: "mis-b-#{SecureRandom.hex(3)}", routing_protocol: "ibgp")
  end

  let!(:node) { sdwan_test_node(account: account) }
  let!(:host)  { sdwan_test_node_instance(node: node) }
  let!(:other) { sdwan_test_node_instance(node: node) }

  # The host is enrolled in BOTH networks — the multi-iBGP shape.
  let!(:host_peer_a) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: net_a.id, node_instance: host,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:host_peer_b) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: net_b.id, node_instance: host,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51821)
  end
  # A real neighbour, in network A only.
  let!(:neighbor_a) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: net_a.id, node_instance: other,
                        publicly_reachable: false)
  end

  let(:neighbor_a_addr) { neighbor_a.assigned_address.to_s.split("/").first }

  # What an agent that polls one global vtysh actually POSTs: the same session
  # list under every iBGP network id it knows about.
  let(:replayed_payload) do
    session = {
      neighbor_address: neighbor_a_addr, state: "established",
      uptime_seconds: 3600, prefixes_received: 5, prefixes_sent: 3
    }
    [
      { network_id: net_a.id, router_id: "10.0.0.1", local_as: 4_231_866_913, sessions: [ session ] },
      { network_id: net_b.id, router_id: "10.0.0.1", local_as: 4_231_866_913, sessions: [ session ] }
    ]
  end

  let(:peer_by_network) { { net_a.id => host_peer_a, net_b.id => host_peer_b } }

  def write!
    described_class.new(instance: host, peer_by_network: peer_by_network,
                        networks_payload: replayed_payload).write!
  end

  it "does not create any BgpSession row under the network the neighbour does not belong to" do
    write!
    expect(Sdwan::BgpSession.where(sdwan_network_id: net_b.id).count).to eq(0)
  end

  it "still records the network whose neighbour really is its own" do
    write!
    rows = Sdwan::BgpSession.where(sdwan_network_id: net_a.id)
    expect(rows.count).to eq(1)
    expect(rows.first.neighbor_address).to eq(neighbor_a_addr)
  end

  it "records that network B's observation was UNATTRIBUTABLE, not that it measured zero sessions" do
    write!
    obs = host_peer_b.reload.bgp_session_state["observation"]
    expect(obs).to be_present
    expect(obs["status"]).to eq("unattributable")
    expect(obs["sessions_rejected"]).to eq(1)
  end

  it "distinguishes an agent that reports nothing measured from one that measured zero sessions" do
    described_class.new(
      instance: host, peer_by_network: peer_by_network,
      networks_payload: [
        { network_id: net_b.id, measured: false, not_measured_reason: "vrf_scope_unconfirmed", sessions: [] }
      ]
    ).write!

    obs = host_peer_b.reload.bgp_session_state["observation"]
    expect(obs["status"]).to eq("not_measured")
    expect(obs["reason"]).to eq("vrf_scope_unconfirmed")

    described_class.new(
      instance: host, peer_by_network: peer_by_network,
      networks_payload: [ { network_id: net_b.id, measured: true, sessions: [] } ]
    ).write!

    obs = host_peer_b.reload.bgp_session_state["observation"]
    expect(obs["status"]).to eq("measured")
    expect(obs["sessions_accepted"]).to eq(0)
  end
end
