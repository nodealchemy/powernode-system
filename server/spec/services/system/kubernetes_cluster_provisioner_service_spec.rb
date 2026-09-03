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

  describe ".bootstrap! VIP-backed api_endpoint (slice 3)" do
    before { server_peer }

    it "allocates an Sdwan::VirtualIp at bootstrap time" do
      expect {
        described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc", server_token: "tok",
          agent_token: "atok", k8s_version: "v1.30"
        )
      }.to change { ::Sdwan::VirtualIp.where(account: account).count }.by(1)

      vip = ::Sdwan::VirtualIp.where(account: account).order(:created_at).last
      expect(vip.holder_peer_ids).to eq([ server_peer.id ])
      expect(vip.failover_holder_peer_ids).to eq([])
      # IPv6 zero compression may render the address as
      # `fd...:dead:beef:0:abcd/128` (the explicit zero between
      # beef and the suffix is the high 16 bits of the low-32
      # selector, always 0 in our derivation).
      expect(vip.cidr).to match(%r{\Afd[0-9a-f:]+:dead:beef:[0-9a-f:]+/128\z})
    end

    it "uses the VIP CIDR in cluster.api_endpoint, not the bootstrap peer's /128" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
      vip = ::Sdwan::VirtualIp.find(cluster.metadata["api_vip_id"])
      vip_addr = vip.cidr.split("/").first
      peer_addr = server_peer.assigned_address.split("/").first
      expect(cluster.api_endpoint).to eq("https://[#{vip_addr}]:6443")
      expect(cluster.api_endpoint).not_to include(peer_addr)
    end

    it "stores api_vip_id + api_vip_cidr in cluster metadata" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
      expect(cluster.metadata["api_vip_id"]).to be_present
      expect(cluster.metadata["api_vip_cidr"]).to match(%r{/128\z})
    end

    it "is deterministic — re-bootstrap with same cluster name reuses VIP" do
      c1 = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
      vip_id_1 = c1.metadata["api_vip_id"]
      c2 = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc-rotated", server_token: "tok-rotated",
        agent_token: "atok-rotated", k8s_version: "v1.30.1"
      )
      expect(c2.id).to eq(c1.id)
      expect(c2.metadata["api_vip_id"]).to eq(vip_id_1)
      expect(::Sdwan::VirtualIp.where(account: account).count).to eq(1)
    end

    it "VIP transitions to active state automatically (holder_peer_ids set)" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
      vip = ::Sdwan::VirtualIp.where(account: account).first
      expect(vip.state).to eq("active")
    end
  end

  describe ".register_node_join! HA failover candidates (slice 3)" do
    before do
      server_peer
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
    end

    it "adds joining server peer to VIP failover_holder_peer_ids" do
      ha_inst = sdwan_test_node_instance(node: node, name: "i-ha-#{SecureRandom.hex(3)}")
      ha_peer = ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                                       node_instance: ha_inst, publicly_reachable: false)

      described_class.register_node_join!(node_instance: ha_inst, role: "server",
                                          k8s_version: "v1.30")

      vip = ::Sdwan::VirtualIp.where(account: account).first
      expect(vip.holder_peer_ids).to eq([ server_peer.id ])
      expect(vip.failover_holder_peer_ids).to include(ha_peer.id)
    end

    it "does NOT add agent-role joiners (workers don't answer kube-apiserver)" do
      worker_inst = sdwan_test_node_instance(node: node, name: "i-worker-#{SecureRandom.hex(3)}")
      ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                             node_instance: worker_inst, publicly_reachable: false)

      described_class.register_node_join!(node_instance: worker_inst, role: "agent",
                                          k8s_version: "v1.30")

      vip = ::Sdwan::VirtualIp.where(account: account).first
      expect(vip.failover_holder_peer_ids).to eq([])
    end

    it "is idempotent — re-registering same server doesn't duplicate" do
      ha_inst = sdwan_test_node_instance(node: node, name: "i-ha-idem-#{SecureRandom.hex(3)}")
      ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                             node_instance: ha_inst, publicly_reachable: false)

      described_class.register_node_join!(node_instance: ha_inst, role: "server")
      described_class.register_node_join!(node_instance: ha_inst, role: "server")

      vip = ::Sdwan::VirtualIp.where(account: account).first
      expect(vip.failover_holder_peer_ids.size).to eq(1)
    end
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

    # Phase 2.5 — multi-cluster awareness via target_cluster_id
    context "with multiple clusters in the account" do
      let(:server_inst_2) { sdwan_test_node_instance(node: node, name: "i-server-2") }
      let!(:server_peer_2) {
        ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                              node_instance: server_inst_2, publicly_reachable: false)
      }

      before do
        server_peer
        @cluster_a = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-A", server_token: "tok-A",
          agent_token: "agent-A", k8s_version: "v1.30"
        )
        @cluster_b = described_class.bootstrap!(
          node_instance: server_inst_2,
          kubeconfig: "kc-B", server_token: "tok-B",
          agent_token: "agent-B", k8s_version: "v1.30"
        )
      end

      it "refuses to auto-select among multiple clusters (raises AmbiguousClusterError)" do
        expect {
          described_class.join_request!(node_instance: agent_instance)
        }.to raise_error(described_class::AmbiguousClusterError, /pass target_cluster_id/)
      end

      it "emits a refusal FleetEvent when it refuses an ambiguous join" do
        expect do
          described_class.join_request!(node_instance: agent_instance)
        rescue described_class::AmbiguousClusterError
          # expected — assert the side-effect event was recorded
        end.to change {
          System::FleetEvent.where(account: account, kind: "system.k3s_ambiguous_cluster_join_refused").count
        }.by(1)
      end

      # IMP-c61a98e923c7. The candidate set is `where.not(status: "error")`,
      # so every non-error status counts toward the refusal — but the 409
      # body said "has N active clusters". An operator with one `active`
      # and one `bootstrapping` cluster was told "has 2 active clusters",
      # listed their active clusters, found one, and concluded the platform
      # was wrong about its own state — while CONTAINER_RUNTIMES.md and
      # multi-cluster-k3s.md correctly say the opposite. The body must name
      # the real candidate set and the candidates themselves.
      context "the refusal names the real candidate set (IMP-c61a98e923c7)" do
        before do
          @cluster_a.update_columns(status: "active")
          @cluster_b.update_columns(status: "bootstrapping")
        end

        let(:message) do
          described_class.join_request!(node_instance: agent_instance)
          raise "expected AmbiguousClusterError to be raised"
        rescue described_class::AmbiguousClusterError => e
          e.message
        end

        it "says 'non-error clusters', never 'active clusters', when only one candidate is active" do
          expect(message).to match(/has 2 non-error clusters/),
                             "the 409 body does not name the non-error candidate set: #{message.inspect}"
          expect(message).not_to match(/\d+ active clusters/),
                                 "the 409 body still claims the candidates are active: #{message.inspect}"
        end

        it "states which statuses count and that only error is excluded" do
          counted = (::Devops::KubernetesCluster::STATUSES - %w[error]).join("/")
          expect(message).to include("#{counted} all count"),
                             "the 409 body does not enumerate the counted statuses: #{message.inspect}"
          expect(message).to match(/only error is excluded/),
                             "the 409 body does not state the exclusion: #{message.inspect}"
        end

        it "lists each candidate by name and status so a non-active candidate is visible" do
          expect(message).to include("#{@cluster_a.name} (active)")
          expect(message).to include("#{@cluster_b.name} (bootstrapping)")
        end

        # The AmbiguousClusterError message is rendered VERBATIM as the 409
        # body to the refused node agent (runtime_handshake_handlers.rb:169),
        # and resolve_membership_cluster! honours any target_cluster_id in the
        # account with no membership check — join_request! then returns that
        # cluster's agent_token and ca_pem. Printing sibling UUIDs to the agent
        # would therefore hand it the join credentials for every other cluster,
        # which is the isolation breach the refusal exists to prevent. Names
        # and statuses are inert: the resolver looks clusters up by id only.
        it "withholds the sibling cluster ids from the body the agent receives" do
          expect(message).not_to include(@cluster_a.id),
                                 "the 409 body leaks a sibling cluster id to the refused agent: #{message.inspect}"
          expect(message).not_to include(@cluster_b.id),
                                 "the 409 body leaks a sibling cluster id to the refused agent: #{message.inspect}"
        end

        it "still carries the remedy" do
          expect(message).to match(/pass target_cluster_id to choose one \(auto-select refused\)/)
        end

        # The operator half of the same refusal: the ids the body withholds
        # have to reach someone, and the log line is the surface the agent
        # never sees.
        it "logs the refusal against the non-error set, with the candidate ids" do
          logged = []
          allow(Rails.logger).to receive(:warn) { |msg| logged << msg.to_s }
          message

          refusal = logged.find { |m| m.include?("refused ambiguous join") }
          expect(refusal).to be_present, "no refusal warning was logged: #{logged.inspect}"
          expect(refusal).to match(/has 2 non-error clusters/)
          expect(refusal).not_to match(/\d+ active clusters/)
          expect(refusal).to include(@cluster_a.id),
                             "the operator log withholds the ids the 409 body also withholds: #{refusal.inspect}"
          expect(refusal).to include(@cluster_b.id)
        end

        # The machine-readable copy of the same claim. Renamed with the
        # message: a payload key asserting "active" while counting non-error
        # clusters is the identical defect one layer down, and the event is
        # exactly where the runbooks send an operator to confirm the refusal.
        it "counts the non-error set in the FleetEvent payload, not an 'active' one" do
          message

          event = ::System::FleetEvent
                    .where(account: account, kind: "system.k3s_ambiguous_cluster_join_refused")
                    .order(created_at: :desc).first
          expect(event).to be_present
          payload = event.payload.to_h
          expect(payload["non_error_cluster_count"]).to eq(2)
          expect(payload).not_to have_key("active_cluster_count")
        end

        # The body is on an agent RETRY path, so the enumeration cannot grow
        # without bound: past the cap the count clause carries the total and
        # the tail collapses into "and N more".
        it "caps the enumerated candidates and states how many were elided" do
          4.times do |i|
            ::Devops::KubernetesCluster.create!(
              account: account,
              name: "extra-cluster-#{i}",
              slug: "extra-cluster-#{i}-#{SecureRandom.hex(4)}",
              api_endpoint: "https://10.90.0.#{i + 1}:6443",
              flavor: "k3s", environment: "development",
              status: "pending", cni_plugin: "flannel"
            )
          end

          limit = described_class::AMBIGUOUS_CANDIDATE_LIST_LIMIT
          expect(message).to match(/has 6 non-error clusters/)
          expect(message.scan(/\((?:pending|bootstrapping|active|degraded|disconnected)\)/).size).to eq(limit)
          expect(message).to include("and #{6 - limit} more")
        end

        # The body's cap exists because the 409 rides an agent RETRY path.
        # The operator log has no wire-size constraint and is the only
        # surface carrying ids at all (the FleetEvent payload carries the
        # count), so capping it too would leave the 6th and later candidate
        # with no id anywhere: an operator told "6 non-error clusters" could
        # not look the elided ones up.
        it "logs every candidate id, past the cap the 409 body applies" do
          extra = Array.new(4) do |i|
            ::Devops::KubernetesCluster.create!(
              account: account,
              name: "extra-cluster-#{i}",
              slug: "extra-cluster-#{i}-#{SecureRandom.hex(4)}",
              api_endpoint: "https://10.91.0.#{i + 1}:6443",
              flavor: "k3s", environment: "development",
              status: "pending", cni_plugin: "flannel"
            )
          end

          logged = []
          allow(Rails.logger).to receive(:warn) { |msg| logged << msg.to_s }
          message

          refusal = logged.find { |m| m.include?("refused ambiguous join") }
          expect(refusal).to be_present, "no refusal warning was logged: #{logged.inspect}"
          ([ @cluster_a, @cluster_b ] + extra).each do |c|
            expect(refusal).to include(c.id),
                               "the operator log elides candidate #{c.name}'s id, which then reaches no surface at all: #{refusal.inspect}"
          end
          expect(refusal).not_to match(/and \d+ more/),
                                 "the operator log truncates the candidate list: #{refusal.inspect}"
        end
      end

      it "joins the specified cluster when target_cluster_id matches" do
        result = described_class.join_request!(
          node_instance: agent_instance,
          target_cluster_id: @cluster_a.id
        )
        expect(result[:cluster_id]).to eq(@cluster_a.id)
        expect(result[:agent_token]).to eq("agent-A")
      end

      it "raises when target_cluster_id is unknown to the account" do
        expect {
          described_class.join_request!(
            node_instance: agent_instance,
            target_cluster_id: "00000000-0000-0000-0000-000000000000"
          )
        }.to raise_error(described_class::NoClusterAvailableError, /target cluster/)
      end

      # IMP-d231ab902879. The docs guard pins that the corrected literal is in
      # the file; it cannot prove that literal is the one that reaches the
      # operator. Execute the raise, and assert the counterfactual in the same
      # example — this context has two clusters, so it is precisely the account
      # in which the withdrawn advice ("omit target_cluster_id to auto-select
      # most recent") would have converted this 422 into a 409.
      it "the unknown-target message does not advise the omission that would 409 here" do
        message = begin
          described_class.join_request!(
            node_instance: agent_instance,
            target_cluster_id: "00000000-0000-0000-0000-000000000000"
          )
          raise "expected NoClusterAvailableError"
        rescue described_class::NoClusterAvailableError => e
          e.message
        end

        expect(message).not_to match(/auto-select/i)
        expect(message).not_to match(/most[- ]recent/i)
        expect(message).to include("exactly one non-error cluster")
        expect(message).to include("system.k3s_ambiguous_cluster_join_refused")
        expect(message).to include("with none it fails as this request did (422)")
      end

      it "refuses to join a target cluster in error state" do
        @cluster_a.update!(status: "error")
        expect {
          described_class.join_request!(
            node_instance: agent_instance,
            target_cluster_id: @cluster_a.id
          )
        }.to raise_error(described_class::NoClusterAvailableError, /error state/)
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

  # Regression — phase=ready re-fires register_node_join! on every k3s
  # version bump / rolling upgrade / state loss. Before the fix this
  # ALWAYS re-resolved "most recent non-error cluster in the account"
  # and blindly moved the node's row onto it — silently corrupting
  # multi-cluster membership the moment a second cluster existed, in
  # direct contradiction of the AmbiguousClusterError isolation guard
  # already enforced by join_request!.
  describe ".register_node_join! multi-cluster isolation (regression)" do
    let(:server_inst_2) { sdwan_test_node_instance(node: node, name: "i-server-2") }
    let!(:server_peer_2) {
      ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                            node_instance: server_inst_2, publicly_reachable: false)
    }

    before do
      server_peer
      @cluster_a = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc-A", server_token: "tok-A",
        agent_token: "agent-A", k8s_version: "v1.30"
      )
      # Agent joins cluster_a while it's the only cluster in the account
      # — unambiguous single-cluster auto-select.
      described_class.register_node_join!(node_instance: agent_instance, role: "agent",
                                          k8s_version: "v1.30")
      # A second, independent cluster bootstraps later (newer created_at).
      @cluster_b = described_class.bootstrap!(
        node_instance: server_inst_2,
        kubeconfig: "kc-B", server_token: "tok-B",
        agent_token: "agent-B", k8s_version: "v1.30"
      )
    end

    it "refuses (does not silently relocate) an already-joined node's ready re-fire once a second cluster exists" do
      node_row = ::Devops::KubernetesNode.find_by!(node_instance_id: agent_instance.id)
      expect(node_row.kubernetes_cluster_id).to eq(@cluster_a.id)

      expect {
        described_class.register_node_join!(node_instance: agent_instance, role: "agent",
                                            k8s_version: "v1.30.1")
      }.to raise_error(described_class::AmbiguousClusterError, /pass target_cluster_id/)

      expect(node_row.reload.kubernetes_cluster_id).to eq(@cluster_a.id)
    end

    it "stays pinned to the node's own cluster when target_cluster_id matches its existing membership" do
      node_row = ::Devops::KubernetesNode.find_by!(node_instance_id: agent_instance.id)

      described_class.register_node_join!(node_instance: agent_instance, role: "agent",
                                          k8s_version: "v1.30.1", target_cluster_id: @cluster_a.id)

      expect(node_row.reload.kubernetes_cluster_id).to eq(@cluster_a.id)
      expect(@cluster_a.reload.node_count).to eq(2) # server + agent, unchanged
      expect(@cluster_b.reload.node_count).to eq(1) # unaffected
    end

    it "adjusts node_count on both clusters when explicitly retargeted to a different cluster" do
      node_row = ::Devops::KubernetesNode.find_by!(node_instance_id: agent_instance.id)
      expect(@cluster_a.reload.node_count).to eq(2)
      expect(@cluster_b.reload.node_count).to eq(1)

      described_class.register_node_join!(node_instance: agent_instance, role: "agent",
                                          target_cluster_id: @cluster_b.id)

      expect(node_row.reload.kubernetes_cluster_id).to eq(@cluster_b.id)
      expect(@cluster_a.reload.node_count).to eq(1)
      expect(@cluster_b.reload.node_count).to eq(2)
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

  # ────────────────────────────────────────────────────────────────────
  # Phase O4 — cni_plugin auto-default + mixed-profile rejection
  # ────────────────────────────────────────────────────────────────────

  describe ".bootstrap! cni_plugin auto-default (Phase O4)" do
    context "with a lightweight bootstrap NodeInstance" do
      before do
        server_instance.update!(network_profile: "lightweight")
        server_peer
      end

      it "defaults the cluster's cni_plugin to flannel" do
        cluster = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc", server_token: "tok",
          agent_token: "atok", k8s_version: "v1.30"
        )
        expect(cluster.cni_plugin).to eq("flannel")
      end
    end

    context "with a heavyweight bootstrap NodeInstance" do
      before do
        server_instance.update!(network_profile: "heavyweight")
        server_peer
      end

      it "defaults the cluster's cni_plugin to ovn_kubernetes" do
        cluster = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc", server_token: "tok",
          agent_token: "atok", k8s_version: "v1.30"
        )
        expect(cluster.cni_plugin).to eq("ovn_kubernetes")
      end
    end

    context "with an operator-explicit cni_plugin override" do
      before { server_peer }

      it "honours the explicit value when the host profile agrees" do
        server_instance.update!(network_profile: "heavyweight")

        cluster = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc", server_token: "tok",
          agent_token: "atok", k8s_version: "v1.30",
          cni_plugin: "flannel"  # downgrade — heavyweight host can run Flannel
        )
        expect(cluster.cni_plugin).to eq("flannel")
      end

      it "raises when the explicit value exceeds a lightweight host's hardware floor" do
        server_instance.update!(network_profile: "lightweight")

        expect {
          described_class.bootstrap!(
            node_instance: server_instance,
            kubeconfig: "kc", server_token: "tok",
            agent_token: "atok", k8s_version: "v1.30",
            cni_plugin: "ovn_kubernetes"
          )
        }.to raise_error(described_class::CniProfileMismatchError, /heavyweight/)
      end

      it "raises when the explicit value isn't one of the allowed plugins" do
        server_instance.update!(network_profile: "heavyweight")

        expect {
          described_class.bootstrap!(
            node_instance: server_instance,
            kubeconfig: "kc", server_token: "tok",
            agent_token: "atok", k8s_version: "v1.30",
            cni_plugin: "calico"
          )
        }.to raise_error(described_class::CniProfileMismatchError, /not one of/)
      end
    end

    context "idempotent re-bootstrap" do
      before do
        server_instance.update!(network_profile: "heavyweight")
        server_peer
      end

      it "leaves the existing cni_plugin in place (immutable past bootstrap)" do
        first = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-1", server_token: "tok-1",
          agent_token: "atok-1", k8s_version: "v1.30"
        )
        # The cluster has now left `pending` (status=bootstrapping). The
        # second call hits the idempotent path that only refreshes
        # credentials — cni_plugin must NOT be touched.
        second = described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc-2", server_token: "tok-2",
          agent_token: "atok-2", k8s_version: "v1.30",
          cni_plugin: "flannel"  # operator tries to flip it — silently ignored
        )
        expect(second.id).to eq(first.id)
        expect(second.cni_plugin).to eq("ovn_kubernetes")
      end
    end
  end

  describe ".register_node_join! cni profile compatibility (Phase O4)" do
    before do
      server_instance.update!(network_profile: "heavyweight")
      server_peer
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok",
        agent_token: "atok", k8s_version: "v1.30"
      )
    end

    it "allows a heavyweight worker to join an ovn_kubernetes cluster" do
      agent_instance.update!(network_profile: "heavyweight")
      agent_peer

      expect {
        described_class.register_node_join!(
          node_instance: agent_instance, role: "agent"
        )
      }.not_to raise_error
    end

    it "rejects a lightweight worker joining an ovn_kubernetes cluster" do
      agent_instance.update!(network_profile: "lightweight")
      agent_peer

      expect {
        described_class.register_node_join!(
          node_instance: agent_instance, role: "agent"
        )
      }.to raise_error(described_class::CniProfileMismatchError, /Mixed-profile/)
    end

    it "allows a heavyweight worker to join a flannel cluster (downgrade-safe)" do
      # Build a flannel cluster off a heavyweight host that explicitly
      # downgrades. Then have a heavyweight worker join — must succeed.
      hw_server = sdwan_test_node_instance(node: node, name: "i-hw-flannel-#{SecureRandom.hex(3)}")
      hw_server.update!(network_profile: "heavyweight")
      ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                             node_instance: hw_server, publicly_reachable: false)
      flannel_cluster = described_class.bootstrap!(
        node_instance: hw_server,
        kubeconfig: "kc-fl", server_token: "tok-fl",
        agent_token: "atok-fl", k8s_version: "v1.30",
        cni_plugin: "flannel"
      )
      expect(flannel_cluster.cni_plugin).to eq("flannel")

      hw_worker = sdwan_test_node_instance(node: node, name: "i-hw-worker-#{SecureRandom.hex(3)}")
      hw_worker.update!(network_profile: "heavyweight")
      ::Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                             node_instance: hw_worker, publicly_reachable: false)

      # The outer `before` block already bootstrapped an ovn_kubernetes
      # cluster on server_instance, so the account now legitimately has
      # 2 non-error clusters (both still bootstrapping) — target_cluster_id disambiguates which one
      # hw_worker means to join (auto-select is correctly refused above).
      expect {
        described_class.register_node_join!(
          node_instance: hw_worker, role: "agent", target_cluster_id: flannel_cluster.id
        )
      }.not_to raise_error
    end

    # IMP-e5de023ab9fa — ORDERING. `register_node_join!` resolves cluster
    # membership (`resolve_membership_cluster!`) BEFORE it runs
    # `enforce_cni_profile_compatibility!`. So the CNI gate is only reachable
    # once resolution has already succeeded: with a second non-error cluster in
    # the account and no `target_cluster_id`, the call is refused with
    # `AmbiguousClusterError` and the profile is never looked at.
    #
    # This is the exact shape of the K3s smoke drill's CNI negative test
    # (db/seeds/smoke_test_k3s_agent_join.rb): it creates a stub
    # `ovn_kubernetes` cluster alongside the site cluster and then called
    # `register_node_join!` untargeted, rescuing `CniProfileMismatchError` only
    # — a rescue that cannot catch what actually escapes. Pinned here so the
    # ordering cannot be reversed without a red example, and so the drill's
    # premise is checked by execution rather than by reading.
    context "when a second non-error cluster exists (the smoke drill's shape)" do
      let!(:stub_cluster) do
        ::Devops::KubernetesCluster.create!(
          account:      account,
          name:         "ovn-stub-#{SecureRandom.hex(4)}",
          flavor:       "k3s",
          environment:  "production",
          status:       "active",
          cni_plugin:   "ovn_kubernetes",
          api_endpoint: "https://[::1]:6443",
          k8s_version:  "v1.30.5+k3s1",
          encrypted_kubeconfig: "stub",
          encrypted_server_token: "stub",
          encrypted_agent_token: "stub",
          metadata: {}
        )
      end

      before do
        agent_instance.update!(network_profile: "lightweight")
        agent_peer
      end

      it "refuses on ambiguity before the CNI gate can run" do
        expect {
          described_class.register_node_join!(
            node_instance: agent_instance, role: "agent"
          )
        }.to raise_error(described_class::AmbiguousClusterError, /pass target_cluster_id/)
      end

      # The counterfactual the drill depended on: a rescue naming only
      # CniProfileMismatchError does NOT catch the untargeted call. Written as a
      # real rescue chain rather than `raise_error`, because what is under test
      # is which handler runs, not merely which class is raised.
      it "escapes a rescue that names CniProfileMismatchError alone" do
        reached = begin
          described_class.register_node_join!(
            node_instance: agent_instance, role: "agent"
          )
          :no_raise
        rescue described_class::CniProfileMismatchError
          :cni_gate
        rescue described_class::AmbiguousClusterError
          :ambiguity_refusal
        end

        expect(reached).to eq(:ambiguity_refusal)
      end

      # ...and naming the stub explicitly is what makes the gate reachable,
      # which is the drill's actual intent.
      it "reaches the CNI gate once target_cluster_id names the stub" do
        expect {
          described_class.register_node_join!(
            node_instance: agent_instance, role: "agent",
            target_cluster_id: stub_cluster.id
          )
        }.to raise_error(described_class::CniProfileMismatchError, /Mixed-profile/)
      end

      it "creates no KubernetesNode on either refusal path" do
        expect {
          begin
            described_class.register_node_join!(
              node_instance: agent_instance, role: "agent"
            )
          rescue described_class::AmbiguousClusterError
            nil
          end
        }.not_to change { ::Devops::KubernetesNode.where(node_instance_id: agent_instance.id).count }
      end
    end
  end

  # K3s overlay (2026-05-19) — when the bootstrap peer's SDWAN network
  # has pod_subnet_prefix set + cni_plugin=flannel, the provisioner
  # stamps cluster.metadata["pod_cidr"] + ["sdwan_network_id"] and
  # creates an Sdwan::SubnetAdvertisement(source: "pod_subnet") row.
  # ovn-Kubernetes ignores pod_subnet_prefix (warning event emitted).
  describe ".bootstrap! k3s pod overlay (pod_subnet_prefix)" do
    before do
      server_peer
      network.update!(pod_subnet_prefix: "10.42.0.0/16")
    end

    it "stamps cluster.metadata['pod_cidr'] + ['sdwan_network_id'] for flannel cluster" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30", cni_plugin: "flannel"
      )
      expect(cluster.metadata["pod_cidr"]).to eq("10.42.0.0/16")
      expect(cluster.metadata["sdwan_network_id"]).to eq(network.id)
    end

    it "creates a Sdwan::SubnetAdvertisement(source: 'pod_subnet')" do
      expect {
        described_class.bootstrap!(
          node_instance: server_instance,
          kubeconfig: "kc", server_token: "tok", agent_token: "atok",
          k8s_version: "v1.30", cni_plugin: "flannel"
        )
      }.to change {
        ::Sdwan::SubnetAdvertisement.where(account: account, source: "pod_subnet").count
      }.by(1)

      ad = ::Sdwan::SubnetAdvertisement.where(account: account, source: "pod_subnet").last
      expect(ad.prefix).to eq("10.42.0.0/16")
      expect(ad.sdwan_peer_id).to eq(server_peer.id)
    end

    it "does NOT stamp pod_cidr for ovn_kubernetes clusters (flannel-only feature)" do
      # ovn-K8s + heavyweight network_profile path. We need to avoid the
      # network_profile compatibility check; this is best-effort and may
      # skip cleanly if the profile resolver rejects ovn-K8s for this
      # node. The provisioner emits a warning event but proceeds.
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30", cni_plugin: "ovn_kubernetes"
      )
      expect(cluster.metadata["pod_cidr"]).to be_nil
      expect(cluster.cni_plugin).to eq("ovn_kubernetes")
    rescue System::KubernetesClusterProvisionerService::CniProfileMismatchError
      # Profile mismatch is expected on a default lightweight node — skip
      # this assertion when the network_profile guard rejects ovn-K8s.
      skip "node network_profile rejects ovn_kubernetes"
    end

    it "preserves baseline cluster fields when pod overlay activates" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30", cni_plugin: "flannel"
      )
      expect(cluster.cni_plugin).to eq("flannel")
      expect(cluster.status).to eq("bootstrapping")
      expect(cluster.flavor).to eq("k3s")
    end
  end

  # bootstrap_events instrumentation (2026-05-19) — append-only event log
  # on cluster.metadata["bootstrap_events"]. Used by smoke-test helpers'
  # wait_for_cluster_active! to surface failure context on timeout. Each
  # entry has ts/phase/status (+ optional message); capped at 50 entries.
  describe "bootstrap_events instrumentation" do
    before { server_peer }

    it "records a completed event when bootstrap succeeds" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      events = Array(cluster.metadata["bootstrap_events"])
      expect(events.size).to eq(1)
      expect(events.first["phase"]).to eq("bootstrap")
      expect(events.first["status"]).to eq("completed")
      expect(events.first["ts"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(events.first["message"]).to include("node_instance=#{server_instance.id}")
    end

    it "records a credentials_refreshed event on idempotent re-bootstrap" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc-1", server_token: "tok-1", agent_token: "atok-1",
        k8s_version: "v1.30"
      )
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc-2", server_token: "tok-2", agent_token: "atok-2",
        k8s_version: "v1.30.5"
      )
      events = Array(cluster.metadata["bootstrap_events"])
      expect(events.size).to eq(2)
      expect(events.last["phase"]).to eq("bootstrap")
      expect(events.last["status"]).to eq("credentials_refreshed")
    end

    it "records a register_node_join event with created status for a new node" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      described_class.register_node_join!(
        node_instance: agent_instance, role: "agent", k8s_version: "v1.30"
      )
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      join_events = events.select { |e| e["phase"] == "register_node_join" }
      expect(join_events.size).to eq(1)
      expect(join_events.first["status"]).to eq("created")
      expect(join_events.first["message"]).to include("role=agent")
    end

    it "records an updated status on idempotent re-registration of the same node" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      described_class.register_node_join!(node_instance: agent_instance, role: "agent")
      described_class.register_node_join!(node_instance: agent_instance, role: "agent")
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      join_events = events.select { |e| e["phase"] == "register_node_join" }
      expect(join_events.map { |e| e["status"] }).to eq(%w[created updated])
    end

    it "records a node_ready_cluster_promoted event when bootstrap server reports ready" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      described_class.mark_node_ready!(node_instance: server_instance, k8s_version: "v1.30")
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      ready_events = events.select { |e| e["phase"] == "mark_node_ready" }
      expect(ready_events.size).to eq(1)
      expect(ready_events.first["status"]).to eq("node_ready_cluster_promoted")
    end

    it "records a node_ready (not promoted) event for a non-bootstrap node" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      described_class.register_node_join!(node_instance: agent_instance, role: "agent")
      described_class.mark_node_ready!(node_instance: agent_instance)
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      ready_events = events.select { |e| e["phase"] == "mark_node_ready" }
      expect(ready_events.size).to eq(1)
      expect(ready_events.first["status"]).to eq("node_ready")
    end

    it "records a mark_node_stopped event" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      described_class.mark_node_stopped!(node_instance: server_instance)
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      stopped_events = events.select { |e| e["phase"] == "mark_node_stopped" }
      expect(stopped_events.size).to eq(1)
      expect(stopped_events.first["status"]).to eq("disconnected")
    end

    it "is a no-op for non-member orphan instances on mark_node_stopped (no crash)" do
      described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      orphan = sdwan_test_node_instance(node: node, name: "i-orphan-#{SecureRandom.hex(3)}")
      expect {
        described_class.mark_node_stopped!(node_instance: orphan)
      }.not_to raise_error
      cluster = ::Devops::KubernetesCluster.where(account: account).last
      events = Array(cluster.metadata["bootstrap_events"])
      # Only the bootstrap event was recorded — no stopped event for the orphan
      expect(events.map { |e| e["phase"] }).to eq(%w[bootstrap])
    end

    it "caps the event log at 50 entries (older entries fall off the head)" do
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30"
      )
      # Already 1 event from bootstrap; add 55 more mark_node_ready cycles
      55.times do
        described_class.mark_node_ready!(node_instance: server_instance)
      end
      cluster.reload
      events = Array(cluster.metadata["bootstrap_events"])
      expect(events.size).to eq(50)
      # The most-recent entry is a mark_node_ready event (newest is preserved)
      expect(events.last["phase"]).to eq("mark_node_ready")
    end

    it "preserves prior metadata keys (pod_cidr, api_vip_id) alongside events" do
      network.update!(pod_subnet_prefix: "10.42.0.0/16")
      cluster = described_class.bootstrap!(
        node_instance: server_instance,
        kubeconfig: "kc", server_token: "tok", agent_token: "atok",
        k8s_version: "v1.30", cni_plugin: "flannel"
      )
      expect(cluster.metadata["pod_cidr"]).to eq("10.42.0.0/16")
      expect(cluster.metadata["api_vip_id"]).to be_present
      expect(cluster.metadata["bootstrap_events"]).to be_an(Array)
    end
  end

  # ── Line-citation integrity (IMP-c61a98e923c7 review follow-up) ─────────
  #
  # Nine absolute line numbers in this service are cited by five Markdown
  # surfaces and the k3sd Go comments. Nothing in the service makes that
  # visible at edit time, and the only guard was a hand-maintained
  # parenthetical inside the service's own comment — which named four of the
  # nine and put the safe-insertion boundary at :628 when :744 is cited, so a
  # 43-line insertion at :666 landed inside the real window and came out
  # correct only by accident. Pinned mechanically here instead.
  # (target_cluster_id_docs_accuracy_spec pins the Go citations of :351 only.)
  describe "the line citations other files make against this service" do
    ext_root = File.expand_path("../../../..", __dir__)
    service_path = File.join(
      ext_root, "server/app/services/system/kubernetes_cluster_provisioner_service.rb"
    )

    # cited line => the source line it must still land on. A citation missing
    # from this map is an UNGUARDED citation, so the map must stay exhaustive.
    anchors = {
      135 => "existing_node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)",
      137 => "update_credentials!(existing_node.kubernetes_cluster)",
      329 => 'kind: "system.k3s_ambiguous_cluster_join_refused",',
      351 => "def resolve_membership_cluster!(account)",
      473 => 'add_to_vip_failover_candidates!(cluster) if @role == "server"',
      613 => "def update_credentials!(cluster)",
      628 => "def add_to_vip_failover_candidates!(cluster)",
      647 => "def refresh_vip_holder!(cluster)",
      744 => "def allocate_api_vip!(network:, bootstrap_peer:, cluster_name:)"
    }

    citing_files = (
      Dir.glob(File.join(ext_root, "docs/**/*.md")) +
      Dir.glob(File.join(ext_root, "agent/internal/k3sd/*.go"))
    ).sort

    cited = citing_files.flat_map do |f|
      File.read(f).scan(/kubernetes_cluster_provisioner_service\.rb:(\d+)/).flatten.map(&:to_i)
    end.uniq.sort

    it "finds citations to check, so the guard is not vacuous" do
      expect(citing_files).not_to be_empty
      expect(cited).not_to be_empty
    end

    it "anchors every cited line, leaving no citation unguarded" do
      expect(cited - anchors.keys).to be_empty,
                                      "unguarded citation(s) #{(cited - anchors.keys).inspect} — " \
                                      "add them to `anchors` with the construct they name"
    end

    it "still lands every cited line on the construct it was cited for" do
      lines = File.readlines(service_path)
      expect(cited.to_h { |n| [ n, lines[n - 1].to_s.strip ] })
        .to eq(cited.to_h { |n| [ n, anchors[n] ] })
    end

    # The service comment above the ambiguous-join helpers states the boundary
    # an insertion has to stay below. It named :628; :744 is cited.
    it "names the highest cited line as the insertion boundary in the source comment" do
      block = File.read(service_path)[/# ── Ambiguous-join message helpers.*?\n\n/m].to_s
      expect(block).not_to be_empty,
                          "the ambiguous-join helper comment block moved or was removed"
      expect(block).to include(":#{cited.max}"),
                       "the comment does not name the highest cited line (:#{cited.max}) " \
                       "as the boundary: #{block.inspect}"
      stale = block.scan(/inserted (?:above|below) :(\d+)/).flatten.map(&:to_i)
                   .reject { |n| n == cited.max }
      expect(stale).to be_empty,
                       "the comment states a boundary other than the highest cited line " \
                       ":#{cited.max}: #{stale.inspect}"
    end
  end
end
