# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::BgpSessionWriter, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::BgpSession.delete_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "bsw-net-#{SecureRandom.hex(3)}", routing_protocol: "ibgp") }
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

  let(:payload) do
    [
      {
        network_id: network.id, router_id: "1.2.3.4", local_as: 4_231_866_913,
        sessions: [
          { neighbor_address: peer2.assigned_address.split("/").first,
            state: "established", uptime_seconds: 3600,
            prefixes_received: 5, prefixes_sent: 3 }
        ]
      }
    ]
  end

  it "creates one BgpSession row per neighbor on first write" do
    expect {
      described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                          networks_payload: payload).write!
    }.to change { Sdwan::BgpSession.count }.by(1)
  end

  it "is idempotent — repeat writes don't create duplicates" do
    described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                        networks_payload: payload).write!
    expect {
      described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                          networks_payload: payload).write!
    }.not_to change { Sdwan::BgpSession.count }
  end

  it "stamps last_state_change_at only when state actually changes" do
    described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                        networks_payload: payload).write!
    row = Sdwan::BgpSession.first
    initial_stamp = row.last_state_change_at

    # Same payload, same state — stamp should not move.
    travel 2.minutes do
      described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                          networks_payload: payload).write!
    end
    expect(row.reload.last_state_change_at).to eq(initial_stamp)

    # Different state — stamp moves.
    travel 4.minutes do
      changed = payload.deep_dup
      changed[0][:sessions][0][:state] = "active"
      described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                          networks_payload: changed).write!
    end
    expect(row.reload.last_state_change_at).to be > initial_stamp
  end

  it "resolves neighbor_peer_id heuristically from assigned_address" do
    described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                        networks_payload: payload).write!
    expect(Sdwan::BgpSession.first.neighbor_peer_id).to eq(peer2.id)
  end

  # An address inside the network's own /64 that no Sdwan::Peer row claims
  # yet — a neighbour whose peer row has not been created, or one whose
  # assigned_address moved. It belongs to this network, so it is still filed;
  # only the FK resolution is missing.
  it "still writes the row when neighbor_peer_id can't be resolved" do
    unclaimed = "#{network.cidr_64.split('/').first}999"
    payload[0][:sessions][0][:neighbor_address] = unclaimed
    described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                        networks_payload: payload).write!

    row = Sdwan::BgpSession.first
    expect(row.neighbor_peer_id).to be_nil
    expect(row.neighbor_address).to eq(unclaimed)
  end

  # IMP-2f34679b6b73 — an address from outside this network's prefix cannot
  # be one of its iBGP neighbours (Bgp::ConfigCompiler#neighbors_for only ever
  # returns peers of the same network, and every peer address is allocated out
  # of that network's /64). Filing it would attribute another network's
  # session to this one.
  it "refuses a neighbour address from outside the network's own prefix" do
    payload[0][:sessions][0][:neighbor_address] = "fdf8:dead:beef::999"
    described_class.new(instance: inst1, peer_by_network: { network.id => peer1 },
                        networks_payload: payload).write!

    expect(Sdwan::BgpSession.count).to eq(0)
    observation = peer1.reload.bgp_session_state["observation"]
    expect(observation["status"]).to eq("unattributable")
    expect(observation["rejected_neighbors"]).to eq([ "fdf8:dead:beef::999" ])
  end
end
