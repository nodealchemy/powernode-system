# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::DockerProvisionExecutor do
  before { ::System::InternalCaService.reset! }
  after  { ::System::InternalCaService.reset! }

  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:instance) { sdwan_test_node_instance(node: node) }
  let(:executor) { described_class.new(account: account) }

  let!(:network) do
    ::Sdwan::Network.create!(account_id: account.id,
                             name: "k-test-net-#{SecureRandom.hex(3)}",
                             routing_protocol: "static")
  end
  let(:peer) do
    ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                          node_instance: instance, publicly_reachable: false)
  end

  describe ".descriptor" do
    it "exposes name, category=devops, inputs, outputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("docker_provision")
      expect(d[:category]).to eq("devops")
      expect(d[:inputs]).to include(:node_instance_id, :dry_run)
      expect(d[:outputs]).to include(:host_id, :host_status, :api_endpoint, :already_provisioned)
    end
  end

  describe "#execute" do
    context "dry_run=true" do
      before { peer }

      it "returns plan without creating a DockerHost" do
        result = executor.execute(node_instance_id: instance.id, dry_run: true)
        expect(result[:success]).to be true
        expect(result[:data][:dry_run]).to be true
        expect(result[:data][:host_id]).to be_nil
        plan = result[:data][:plan]
        expect(plan[:instance_id]).to eq(instance.id)
        expect(plan[:sdwan_peer_id]).to eq(peer.id)
        expect(plan[:steps]).to include("issue_client_tls_pair", "create_managed_docker_host")
        expect(::Devops::DockerHost.managed.where(node_instance_id: instance.id)).to be_empty
      end
    end

    context "happy path" do
      before { peer }

      it "creates a managed DockerHost via DockerDaemonProvisionerService" do
        result = executor.execute(node_instance_id: instance.id)
        expect(result[:success]).to be true
        expect(result[:data][:dry_run]).to be false
        expect(result[:data][:already_provisioned]).to be false
        host = ::Devops::DockerHost.managed.find_by(node_instance_id: instance.id)
        expect(host).to be_present
        expect(result[:data][:host_id]).to eq(host.id)
        expect(result[:data][:host_status]).to eq("pending")
      end

      it "is idempotent — second call returns already_provisioned=true" do
        executor.execute(node_instance_id: instance.id)
        result = executor.execute(node_instance_id: instance.id)
        expect(result[:data][:already_provisioned]).to be true
      end
    end

    context "without an SDWAN peer" do
      it "returns failure (no auto-create — operator must attach peer first)" do
        # No peer created
        result = executor.execute(node_instance_id: instance.id)
        expect(result[:success]).to be false
        expect(result[:error]).to include("SDWAN")
      end
    end

    context "cross-account scoping" do
      before { peer }

      it "returns failure when the instance belongs to another account" do
        foreign_executor = described_class.new(account: create(:account))
        result = foreign_executor.execute(node_instance_id: instance.id)
        expect(result[:success]).to be false
        expect(result[:error]).to include("not found in account")
      end
    end
  end
end
