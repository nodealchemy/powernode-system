# frozen_string_literal: true

require "rails_helper"

# Phase 2 — KubernetesClusterProvisionerService.
#
# Covers the bootstrap → join_request → register_node_join → mark_ready
# → mark_stopped flow at the service level. The HTTP-layer handshake
# coverage lives in runtime_controller_spec.
RSpec.describe System::KubernetesClusterProvisionerService do
  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:server_instance) { sdwan_test_node_instance(node: node, name: "i-server") }
  let(:agent_instance) { sdwan_test_node_instance(node: node, name: "i-agent") }
  let!(:network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "k8s-test-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let(:server_peer) do
    ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                          node_instance: server_instance, publicly_reachable: false)
  end
  let(:agent_peer) do
    ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                          node_instance: agent_instance, publicly_reachable: false)
  end

  describe ".bootstrap!" do
    context "with an SDWAN-attached server NodeInstance" do
      before { server_peer }

      it "creates a Devops::KubernetesCluster + 1 server KubernetesNode" do
        cluster = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "fake-kubeconfig",
          server_token: "K10server-token",
          agent_token: "K10agent-token",
          k8s_version: "v1.30.4+k3s1"
        )

        expect(cluster).to be_persisted
        expect(cluster.flavor).to eq("k3s")
        expect(cluster.status).to eq("bootstrapping")
        expect(cluster.k8s_version).to eq("v1.30.4+k3s1")
        expect(cluster.node_count).to eq(1)
        expect(cluster.api_endpoint).to start_with("https://[")
        expect(cluster.api_endpoint).to end_with(":6443")

        node_row = cluster.kubernetes_nodes.first
        expect(node_row.role).to eq("server")
        expect(node_row.status).to eq("active")
        expect(node_row.node_instance_id).to eq(server_instance.id)
      end

      it "stores credentials on the cluster row" do
        cluster = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "fake-kubeconfig",
          server_token: "K10server",
          agent_token: "K10agent",
          k8s_version: "v1.30.4+k3s1"
        )
        expect(cluster.encrypted_kubeconfig).to eq("fake-kubeconfig")
        expect(cluster.encrypted_server_token).to eq("K10server")
        expect(cluster.encrypted_agent_token).to eq("K10agent")
      end

      it "is idempotent — second bootstrap on the same instance returns the existing cluster" do
        first = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-1", server_token: "tok-1", agent_token: "agent-1",
          k8s_version: "v1.30.4+k3s1"
        )
        second = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-2", server_token: "tok-2", agent_token: "agent-2",
          k8s_version: "v1.30.5+k3s1"
        )
        expect(second.id).to eq(first.id)
        expect(::Devops::KubernetesCluster.where(account: account).count).to eq(1)
      end

      it "refreshes credentials on idempotent re-bootstrap (rotation)" do
        first = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-old", server_token: "tok-old", agent_token: "agent-old",
          k8s_version: "v1.30.4+k3s1"
        )
        described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-new", server_token: "tok-new", agent_token: "agent-new",
          k8s_version: "v1.30.5+k3s1"
        )
        first.reload
        expect(first.encrypted_kubeconfig).to eq("kc-new")
        expect(first.encrypted_server_token).to eq("tok-new")
        expect(first.k8s_version).to eq("v1.30.5+k3s1")
      end
    end

    context "without an SDWAN peer" do
      it "raises MissingSdwanPeerError" do
        expect {
          described_class.bootstrap!(
            node_instance: server_instance,
            kubeconfig: "kc", server_token: "tok",
            agent_token: "agent", k8s_version: "v1.30"
          )
        }.to raise_error(described_class::MissingSdwanPeerError, /no SDWAN peer/)
      end
    end

    context "with missing required args" do
      before { server_peer }

      it "raises ArgumentError for missing kubeconfig" do
        expect {
          described_class.bootstrap!(
            node_instance: server_instance,
            kubeconfig: nil, server_token: "tok",
            agent_token: "agent", k8s_version: "v1.30"
          )
        }.to raise_error(ArgumentError, /kubeconfig required/)
      end

      it "raises ArgumentError for missing server_token" do
        expect {
          described_class.bootstrap!(
            node_instance: server_instance,
            kubeconfig: "kc", server_token: nil,
            agent_token: "agent", k8s_version: "v1.30"
          )
        }.to raise_error(ArgumentError, /server_token required/)
      end
    end
  end

  describe ".join_request!" do
    context "when a cluster exists in the account" do
      before do
        server_peer
        described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-yaml", server_token: "tok",
          agent_token: "agent-tok", k8s_version: "v1.30.4+k3s1"
        )
      end

      it "returns api_endpoint + agent_token for the agent to use" do
        result = described_class.join_request!(node_instance: agent_instance)
        expect(result[:api_endpoint]).to start_with("https://[")
        expect(result[:agent_token]).to eq("agent-tok")
        expect(result[:cluster_id]).to be_present
      end
    end

    context "when no cluster exists" do
      it "raises NoClusterAvailableError" do
        expect {
          described_class.join_request!(node_instance: agent_instance)
        }.to raise_error(described_class::NoClusterAvailableError, /no Kubernetes cluster/)
      end
    end
  end

  describe ".register_node_join!" do
    before do
      server_peer
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "agent-tok", k8s_version: "v1.30"
      )
    end

    it "creates a KubernetesNode for an agent joining the cluster" do
      node_row = described_class.register_node_join!(
        node_instance: agent_instance, role: "agent", k8s_version: "v1.30"
      )
      expect(node_row).to be_persisted
      expect(node_row.role).to eq("agent")
      expect(node_row.status).to eq("joining")
      expect(node_row.node_instance_id).to eq(agent_instance.id)
    end

    it "increments cluster.node_count" do
      cluster = ::Devops::KubernetesCluster.last
      expect {
        described_class.register_node_join!(
          node_instance: agent_instance, role: "agent"
        )
      }.to change { cluster.reload.node_count }.from(1).to(2)
    end

    it "is idempotent — second call updates instead of duplicating" do
      first = described_class.register_node_join!(
        node_instance: agent_instance, role: "agent"
      )
      second = described_class.register_node_join!(
        node_instance: agent_instance, role: "agent", k8s_version: "v1.30.5"
      )
      expect(second.id).to eq(first.id)
      expect(::Devops::KubernetesNode.where(node_instance_id: agent_instance.id).count).to eq(1)
    end
  end

  describe ".mark_node_ready!" do
    before do
      server_peer
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "agent-tok", k8s_version: "v1.30"
      )
      described_class.register_node_join!(
        node_instance: agent_instance, role: "agent"
      )
    end

    it "flips the node status from joining → active" do
      node_row = described_class.mark_node_ready!(
        node_instance: agent_instance, k8s_version: "v1.30"
      )
      expect(node_row.status).to eq("active")
    end

    it "updates last_heartbeat_at" do
      node_row = described_class.mark_node_ready!(
        node_instance: agent_instance, k8s_version: "v1.30"
      )
      expect(node_row.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "promotes cluster from bootstrapping → active when the bootstrap server reports ready" do
      cluster = ::Devops::KubernetesCluster.last
      expect(cluster.status).to eq("bootstrapping")

      described_class.mark_node_ready!(node_instance: server_instance, k8s_version: "v1.30")
      expect(cluster.reload.status).to eq("active")
    end

    it "raises NoClusterAvailableError when the instance has no cluster membership" do
      orphan = sdwan_test_node_instance(node: node, name: "i-orphan")
      expect {
        described_class.mark_node_ready!(node_instance: orphan)
      }.to raise_error(described_class::NoClusterAvailableError)
    end
  end

  describe ".mark_node_stopped!" do
    before do
      server_peer
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "agent", k8s_version: "v1.30"
      )
    end

    it "flips status to disconnected" do
      node_row = described_class.mark_node_stopped!(node_instance: server_instance)
      expect(node_row.status).to eq("disconnected")
    end

    it "is a no-op (returns nil) for non-member instances" do
      orphan = sdwan_test_node_instance(node: node, name: "i-orphan")
      expect(described_class.mark_node_stopped!(node_instance: orphan)).to be_nil
    end
  end
end
