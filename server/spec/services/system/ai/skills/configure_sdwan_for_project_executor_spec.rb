# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
RSpec.describe System::Ai::Skills::ConfigureSdwanForProjectExecutor do
  let(:account)        { create(:account) }
  let(:mission)        { create(:ai_mission, account: account, mission_type: "infrastructure") }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)         { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)         { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a)     { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b)     { create(:system_node_instance, :running, node: node_b) }
  let(:exec)           { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("configure_sdwan_for_project")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :project_id, :required)).to be true
      expect(d.dig(:inputs, :instance_ids, :required)).to be true
      expect(d.dig(:inputs, :network_name, :required)).to be true
      expect(d.dig(:inputs, :topology, :required)).to be true
      expect(d.dig(:inputs, :with_vip, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:sdwan_network_id, :sdwan_peer_ids,
                                                    :virtual_ip_id, :topology_preview)
      expect(d[:rollback]).to eq(:rollback_configure_sdwan_for_project)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with an unknown topology" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, instance_ids: [instance_a.id],
                         network_name: "proj", topology: "ring")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/topology must be/)
      end
    end

    context "with no instance ids" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, instance_ids: [],
                         network_name: "proj", topology: "mesh")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/instance_ids must contain/)
      end
    end

    context "with a missing project" do
      it "returns failure" do
        r = exec.execute(project_id: SecureRandom.uuid, instance_ids: [instance_a.id],
                         network_name: "proj", topology: "mesh")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/project not found/)
      end
    end

    context "with an instance that does not belong to the account" do
      it "returns failure listing the missing id" do
        stranger_id = SecureRandom.uuid
        r = exec.execute(project_id: mission.id, instance_ids: [stranger_id],
                         network_name: "proj", topology: "mesh")
        expect(r[:success]).to be false
        expect(r[:error]).to include(stranger_id)
      end
    end

    context "with_vip but no vip_cidr" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, instance_ids: [instance_a.id],
                         network_name: "proj", topology: "mesh", with_vip: true)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/vip_cidr is required/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without persisting Sdwan rows" do
        expect(::Sdwan::PeerEnroller).not_to receive(:call)
        expect {
          r = exec.execute(project_id: mission.id, instance_ids: [instance_a.id, instance_b.id],
                           network_name: "proj", topology: "hub_and_spoke", dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:count]).to eq(2)
          expect(d[:topology]).to eq("hub_and_spoke")
          expect(d[:planned_actions].first[:step]).to eq("create_network")
          expect(d[:outputs][:sdwan_network_id]).to be_nil
          expect(d[:outputs][:sdwan_peer_ids]).to be_empty
        }.not_to change(::Sdwan::Network, :count)
      end
    end

    context "in execute mode (PeerEnroller stubbed at the boundary)" do
      let(:peer_a) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }
      let(:peer_b) { instance_double("Sdwan::Peer", id: SecureRandom.uuid) }

      before do
        allow(::Sdwan::PeerEnroller).to receive(:call).and_return(peer_a, peer_b)
        allow(::Sdwan::TopologyCompiler).to receive(:compile_for_network).and_return([
          { peer_id: peer_a.id, interface: {}, peers: [] },
          { peer_id: peer_b.id, interface: {}, peers: [] }
        ])
      end

      it "creates a network, attaches peers, and compiles the topology preview" do
        r = exec.execute(project_id: mission.id, instance_ids: [instance_a.id, instance_b.id],
                         network_name: "proj-overlay", topology: "mesh")

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:sdwan_network_id]).to be_present
        expect(d[:outputs][:sdwan_peer_ids]).to contain_exactly(peer_a.id, peer_b.id)
        expect(d[:outputs][:topology_preview].size).to eq(2)
        expect(::Sdwan::PeerEnroller).to have_received(:call).twice
      end

      it "marks the run partial when one peer attach fails" do
        call_count = 0
        allow(::Sdwan::PeerEnroller).to receive(:call) do
          call_count += 1
          call_count == 1 ? peer_a : raise("peer_b cross_account")
        end

        r = exec.execute(project_id: mission.id, instance_ids: [instance_a.id, instance_b.id],
                         network_name: "proj-overlay", topology: "mesh")

        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:outputs][:sdwan_peer_ids]).to eq([peer_a.id])
        expect(r[:data][:failures].any? { |f| f[:step] == "attach_peer" }).to be true
      end
    end
  end

  describe "#rollback_configure_sdwan_for_project" do
    let(:network) { create(:account).then { create(:account) } } # placeholder — replaced below

    it "destroys the VIP, peers, and network in reverse order, returning success when all clear" do
      net = ::Sdwan::Network.create!(account_id: account.id, name: "rollback-net",
                                     description: "x", settings: {})
      peer = instance_double("Sdwan::Peer", id: SecureRandom.uuid, destroy!: true)
      vip  = instance_double("Sdwan::VirtualIp", id: SecureRandom.uuid, destroy!: true)

      relation_p = double
      allow(::Sdwan::Peer).to receive(:where).with(account_id: account.id).and_return(relation_p)
      allow(relation_p).to receive(:find_by).with(id: peer.id).and_return(peer)

      relation_v = double
      allow(::Sdwan::VirtualIp).to receive(:where).with(account_id: account.id).and_return(relation_v)
      allow(relation_v).to receive(:find_by).with(id: vip.id).and_return(vip)

      r = exec.rollback_configure_sdwan_for_project(
        sdwan_network_id: net.id,
        sdwan_peer_ids: [peer.id],
        virtual_ip_id: vip.id
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
      expect(vip).to have_received(:destroy!)
      expect(peer).to have_received(:destroy!)
      expect(::Sdwan::Network.where(id: net.id).exists?).to be false
    end

    it "collects errors when destroy raises but continues with siblings" do
      net = ::Sdwan::Network.create!(account_id: account.id, name: "rollback-err",
                                     description: "x", settings: {})
      bad_peer = instance_double("Sdwan::Peer", id: SecureRandom.uuid)
      allow(bad_peer).to receive(:destroy!).and_raise(StandardError.new("constraint failed"))

      relation_p = double
      allow(::Sdwan::Peer).to receive(:where).with(account_id: account.id).and_return(relation_p)
      allow(relation_p).to receive(:find_by).with(id: bad_peer.id).and_return(bad_peer)

      r = exec.rollback_configure_sdwan_for_project(
        sdwan_network_id: net.id,
        sdwan_peer_ids: [bad_peer.id],
        virtual_ip_id: nil
      )

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "sdwan_peer", id: bad_peer.id)
      expect(r[:errors].first[:error]).to match(/constraint failed/)
    end

    it "tolerates extra kwargs (topology_preview) and missing rows" do
      r = exec.rollback_configure_sdwan_for_project(
        sdwan_network_id: nil,
        sdwan_peer_ids: [],
        virtual_ip_id: nil,
        topology_preview: [{ peer_id: SecureRandom.uuid }]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
