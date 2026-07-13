# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — BootstrapK3sCluster called
# KubernetesClusterProvisionerService.new(account:, attributes:), but the
# service takes node_instance:/kubeconfig:/server_token:/agent_token:/
# k8s_version:/cni_plugin: — neither kwarg exists, so every call raised
# ArgumentError before ever reaching #bootstrap!.
RSpec.describe System::Executors::Runtime::BootstrapK3sCluster do
  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:node_instance) { sdwan_test_node_instance(node: node) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }
  let!(:network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "bootstrap-k3s-test-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let!(:peer) do
    ::Sdwan::Peer.create!(
      account: account,
      sdwan_network_id: network.id,
      node_instance: node_instance,
      publicly_reachable: false
    )
  end

  describe ".execute" do
    let(:params) do
      {
        instance_id: node_instance.id,
        attributes: {
          kubeconfig: "kc", server_token: "tok",
          agent_token: "atok", k8s_version: "v1.30.4+k3s1"
        }
      }
    end

    it "bootstraps a Devops::KubernetesCluster via node_instance:, not attributes:" do
      result = described_class.execute(params, deferred_operation: deferred_operation)

      expect(result[:success]).to be true
      cluster = ::Devops::KubernetesCluster.find(result[:data][:cluster_id])
      expect(cluster.k8s_version).to eq("v1.30.4+k3s1")
      expect(cluster.encrypted_server_token).to eq("tok")
      server_node = ::Devops::KubernetesNode.find_by(node_instance_id: node_instance.id)
      expect(server_node).to be_server
      expect(result[:data]).to eq(cluster_id: cluster.id, name: cluster.name, status: cluster.status)
    end
  end
end
