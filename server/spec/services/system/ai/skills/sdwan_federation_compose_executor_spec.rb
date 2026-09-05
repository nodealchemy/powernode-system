# frozen_string_literal: true

require "rails_helper"

# Phase 3 (Federation & Multi-Site) — SDWAN-first federation composition.
# Mirrors the test shape of sdwan_compose_full_topology_executor_spec.rb +
# configure_sdwan_for_project_executor_spec.rb: descriptor contract,
# input validation, dry_run (no persistence), live execute (PeerEnroller
# stubbed at the boundary), partial failure, and reverse-order rollback.
RSpec.describe System::Ai::Skills::SdwanFederationComposeExecutor do
  let(:account)    { create(:account) }
  let(:platform)   { create(:system_node_platform, account: account) }
  let(:template)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)     { create(:system_node, account: account, node_template: template, name: "fed-a") }
  let(:node_b)     { create(:system_node, account: account, node_template: template, name: "fed-b") }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:exec)       { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_federation_compose")
      expect(d[:category]).to eq("federation")
      expect(d.dig(:inputs, :network_name, :required)).to be true
      expect(d.dig(:inputs, :topology, :required)).to be true
      expect(d.dig(:inputs, :peers, :required)).to be true
      expect(d.dig(:inputs, :routing_protocol, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:sdwan_network_id, :sdwan_peer_ids,
                                                   :hub_peer_ids, :topology_preview,
                                                   :route_policy_preview)
      expect(d[:rollback]).to eq(:rollback_sdwan_federation_compose)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:high)
    end

    it "binds to the System Topology Designer agent" do
      reg = System::Ai::Skills::SkillBindings.all
                                             .find { |r| r[:executor].name == described_class.name }
      expect(reg).to be_present
      expect(reg[:agents]).to include("topology-designer")
    end
  end

  describe "#execute — validation" do
    it "rejects an unknown topology" do
      r = exec.execute(network_name: "fed", topology: "ring",
                       peers: [ { node_instance_id: instance_a.id } ])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/topology must be/)
    end

    it "rejects an unknown routing_protocol" do
      r = exec.execute(network_name: "fed", topology: "full_mesh", routing_protocol: "ospf",
                       peers: [ { node_instance_id: instance_a.id } ])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/routing_protocol must be/)
    end

    it "rejects a blank network_name" do
      r = exec.execute(network_name: "  ", topology: "full_mesh",
                       peers: [ { node_instance_id: instance_a.id } ])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/network_name is required/)
    end

    it "rejects an empty peer set" do
      r = exec.execute(network_name: "fed", topology: "full_mesh", peers: [])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/at least one member/)
    end

    it "rejects hub_and_spoke with no hub" do
      r = exec.execute(network_name: "fed", topology: "hub_and_spoke",
                       peers: [ { node_instance_id: instance_a.id, role: "spoke" } ])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/requires at least one peer with role/)
    end

    it "rejects a hub missing an endpoint" do
      r = exec.execute(network_name: "fed", topology: "hub_and_spoke",
                       peers: [ { node_instance_id: instance_a.id, role: "hub" } ])
      expect(r[:success]).to be false
      expect(r[:error]).to match(/hub peer\(s\) require an endpoint/)
      expect(r[:error]).to include(instance_a.id)
    end

    it "rejects an instance that does not belong to the account, naming the missing id" do
      stranger = SecureRandom.uuid
      r = exec.execute(network_name: "fed", topology: "full_mesh",
                       peers: [ { node_instance_id: stranger } ])
      expect(r[:success]).to be false
      expect(r[:error]).to include(stranger)
    end
  end

  describe "#execute — dry_run" do
    it "returns a plan without persisting any Sdwan rows" do
      expect(::Sdwan::PeerEnroller).not_to receive(:call)

      expect {
        r = exec.execute(
          network_name: "fed", topology: "hub_and_spoke", routing_protocol: "ibgp",
          peers: [
            { node_instance_id: instance_a.id, role: "hub",
              endpoint_host_v4: "203.0.113.10", endpoint_port: 51_820 },
            { node_instance_id: instance_b.id, role: "spoke" }
          ],
          dry_run: true
        )
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:count]).to eq(2)
        expect(d[:topology]).to eq("hub_and_spoke")
        expect(d[:routing_protocol]).to eq("ibgp")
        expect(d[:planned_actions].first[:step]).to eq("create_network")
        expect(d[:planned_actions].map { |a| a[:step] }).to include("compile_route_policies")
        expect(d[:outputs][:sdwan_network_id]).to be_nil
        expect(d[:outputs][:sdwan_peer_ids]).to be_empty
        expect(d[:outputs][:topology_preview].first[:projected_hub_count]).to eq(1)
      }.not_to change(::Sdwan::Network, :count)
    end
  end

  describe "#execute — live (PeerEnroller stubbed at the boundary)" do
    let(:peer_a) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }
    let(:peer_b) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }

    before do
      allow(::Sdwan::PeerEnroller).to receive(:call).and_return(peer_a, peer_b)
      allow(::Sdwan::TopologyCompiler).to receive(:compile_for_network).and_return([
        { peer_id: peer_a.id, interface: {}, peers: [] },
        { peer_id: peer_b.id, interface: {}, peers: [] }
      ])
    end

    it "creates the network with topology_strategy + routing_protocol, enrolls peers, compiles previews" do
      r = exec.execute(
        network_name: "fed-overlay", topology: "hub_and_spoke", routing_protocol: "static",
        peers: [
          { node_instance_id: instance_a.id, role: "hub",
            endpoint_host_v4: "203.0.113.10", endpoint_port: 51_820 },
          { node_instance_id: instance_b.id, role: "spoke" }
        ]
      )

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:outputs][:sdwan_network_id]).to be_present
      expect(d[:outputs][:sdwan_peer_ids]).to contain_exactly(peer_a.id, peer_b.id)
      expect(d[:outputs][:hub_peer_ids]).to eq([ peer_a.id ])
      expect(d[:outputs][:topology_preview].size).to eq(2)

      net = ::Sdwan::Network.find(d[:outputs][:sdwan_network_id])
      expect(net.settings["topology_strategy"]).to eq("hub_and_spoke")
      expect(net.routing_protocol).to eq("static")
      expect(::Sdwan::PeerEnroller).to have_received(:call).twice
    end

    it "threads publicly_reachable + endpoint into the hub's enrollment" do
      exec.execute(
        network_name: "fed-overlay", topology: "hub_and_spoke",
        peers: [
          { node_instance_id: instance_a.id, role: "hub",
            endpoint_host_v4: "203.0.113.10", endpoint_port: 51_820,
            lan_subnets: [ "10.50.0.0/16" ] },
          { node_instance_id: instance_b.id, role: "spoke" }
        ]
      )

      expect(::Sdwan::PeerEnroller).to have_received(:call)
        .with(hash_including(publicly_reachable: true, endpoint_host_v4: "203.0.113.10",
                             endpoint_port: 51_820, lan_subnets: [ "10.50.0.0/16" ]))
      expect(::Sdwan::PeerEnroller).to have_received(:call)
        .with(hash_including(publicly_reachable: false))
    end

    it "marks the run partial when one peer enrollment fails" do
      call_count = 0
      allow(::Sdwan::PeerEnroller).to receive(:call) do
        call_count += 1
        call_count == 1 ? peer_a : raise("peer_b cross_account")
      end

      r = exec.execute(
        network_name: "fed-overlay", topology: "full_mesh",
        peers: [
          { node_instance_id: instance_a.id },
          { node_instance_id: instance_b.id }
        ]
      )

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:partial]).to be true
      expect(d[:outputs][:sdwan_peer_ids]).to eq([ peer_a.id ])
      expect(d[:failures].any? { |f| f[:step] == "attach_peer" }).to be true
    end
  end

  describe "#execute — route-policy compile is routing-protocol aware" do
    let(:peer_a) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }
    let(:peer_b) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }

    before do
      allow(::Sdwan::PeerEnroller).to receive(:call).and_return(peer_a, peer_b)
      allow(::Sdwan::TopologyCompiler).to receive(:compile_for_network).and_return([])
    end

    it "skips the RoutePolicyCompiler entirely for static networks and returns an empty preview" do
      expect(::Sdwan::Bgp::RoutePolicyCompiler).not_to receive(:compile_for_peer)

      r = exec.execute(
        network_name: "fed-static", topology: "full_mesh", routing_protocol: "static",
        peers: [ { node_instance_id: instance_a.id }, { node_instance_id: instance_b.id } ]
      )

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:routing_protocol]).to eq("static")
      expect(d[:outputs][:route_policy_preview]).to eq([])
      policy_step = d[:planned_actions].find { |a| a[:step] == "compile_route_policies" }
      expect(policy_step[:policy_peer_count]).to eq(0)
    end

    it "runs the RoutePolicyCompiler per peer for ibgp networks, folding the result into the preview" do
      # Enroll real peer rows so compile_route_policies walks network.peers;
      # PeerEnroller is the boundary we stub, so we materialize peers here.
      allow(::Sdwan::PeerEnroller).to receive(:call) do |network:, node_instance:, **_kw|
        create(:sdwan_peer, account: network.account, network: network, node_instance: node_instance)
      end
      allow(::Sdwan::Bgp::RoutePolicyCompiler).to receive(:compile_for_peer)
        .and_return({ route_maps: [ "rm-export" ], neighbor_assignments: [ "nbr-1" ] })

      r = exec.execute(
        network_name: "fed-ibgp", topology: "full_mesh", routing_protocol: "ibgp",
        peers: [ { node_instance_id: instance_a.id }, { node_instance_id: instance_b.id } ]
      )

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:routing_protocol]).to eq("ibgp")
      expect(d[:outputs][:route_policy_preview].size).to eq(2)
      expect(d[:outputs][:route_policy_preview].first).to include(route_maps: [ "rm-export" ],
                                                                  neighbor_assignments: [ "nbr-1" ])
      expect(::Sdwan::Bgp::RoutePolicyCompiler).to have_received(:compile_for_peer).twice
    end
  end

  describe "#execute — full_mesh live without endpoint requirement" do
    it "enrolls every peer with publicly_reachable: false when no role is given" do
      allow(::Sdwan::TopologyCompiler).to receive(:compile_for_network).and_return([])
      allow(::Sdwan::PeerEnroller).to receive(:call)
        .and_return(instance_double("Sdwan::Peer", id: SecureRandom.uuid),
                    instance_double("Sdwan::Peer", id: SecureRandom.uuid))

      r = exec.execute(
        network_name: "mesh", topology: "full_mesh",
        peers: [ { node_instance_id: instance_a.id }, { node_instance_id: instance_b.id } ]
      )

      expect(r[:success]).to be true
      expect(r[:data][:outputs][:hub_peer_ids]).to eq([])
      expect(::Sdwan::PeerEnroller).to have_received(:call)
        .with(hash_including(publicly_reachable: false)).twice
    end
  end

  describe "#rollback_sdwan_federation_compose" do
    it "destroys peers in reverse order then the network, returning success when all clear" do
      net = ::Sdwan::Network.create!(account_id: account.id, name: "rb-fed",
                                     description: "x", settings: {})
      peer1 = instance_double("Sdwan::Peer", id: SecureRandom.uuid, destroy!: true)
      peer2 = instance_double("Sdwan::Peer", id: SecureRandom.uuid, destroy!: true)

      relation_p = double
      allow(::Sdwan::Peer).to receive(:where).with(account_id: account.id).and_return(relation_p)
      allow(relation_p).to receive(:find_by).with(id: peer1.id).and_return(peer1)
      allow(relation_p).to receive(:find_by).with(id: peer2.id).and_return(peer2)

      r = exec.rollback_sdwan_federation_compose(
        sdwan_network_id: net.id,
        sdwan_peer_ids: [ peer1.id, peer2.id ],
        hub_peer_ids: [ peer1.id ],
        topology_preview: [ { peer_id: peer1.id } ]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
      expect(peer2).to have_received(:destroy!)
      expect(peer1).to have_received(:destroy!)
      expect(::Sdwan::Network.where(id: net.id).exists?).to be false
    end

    it "collects errors when a peer destroy raises but continues with siblings and the network" do
      net = ::Sdwan::Network.create!(account_id: account.id, name: "rb-fed-err",
                                     description: "x", settings: {})
      bad_peer = instance_double("Sdwan::Peer", id: SecureRandom.uuid)
      allow(bad_peer).to receive(:destroy!).and_raise(StandardError.new("constraint failed"))

      relation_p = double
      allow(::Sdwan::Peer).to receive(:where).with(account_id: account.id).and_return(relation_p)
      allow(relation_p).to receive(:find_by).with(id: bad_peer.id).and_return(bad_peer)

      r = exec.rollback_sdwan_federation_compose(
        sdwan_network_id: net.id,
        sdwan_peer_ids: [ bad_peer.id ]
      )

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "sdwan_peer", id: bad_peer.id)
      expect(r[:errors].first[:error]).to match(/constraint failed/)
      # Network still torn down despite the peer error.
      expect(::Sdwan::Network.where(id: net.id).exists?).to be false
    end

    it "tolerates missing rows + extra kwargs" do
      r = exec.rollback_sdwan_federation_compose(
        sdwan_network_id: nil, sdwan_peer_ids: [],
        route_policy_preview: [ { peer_id: SecureRandom.uuid } ]
      )
      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
