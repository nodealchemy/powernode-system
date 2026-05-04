# frozen_string_literal: true

require "json"

module System
  # Phase 2 — Kubernetes (K3s) cluster auto-registration.
  #
  # Parallel to System::DockerDaemonProvisionerService. Differences:
  #
  # - Trust model: K3s ships its own CA + signs its own certs. The
  #   platform doesn't issue cert material; instead the agent reports
  #   what it created (kubeconfig + tokens) and the platform records
  #   it. Phase 3 kubeadm is similar — kubeadm bootstraps its own PKI.
  #
  # - Topology: 1:N from cluster to NodeInstance. The first server's
  #   bootstrap creates a Devops::KubernetesCluster row + a
  #   Devops::KubernetesNode (role: server). Subsequent k3s-server
  #   joins (HA) and k3s-agent joins each create a new
  #   Devops::KubernetesNode under the same cluster.
  #
  # Service surface:
  #
  #   .bootstrap!(node_instance:, kubeconfig:, server_token:,
  #               agent_token:, k8s_version:)
  #     → idempotent; creates the cluster on first call, no-op on
  #       repeat. Returns the Devops::KubernetesCluster.
  #
  #   .join_request!(node_instance:)
  #     → caller is a k3s-agent or HA k3s-server asking for the
  #       cluster details. Returns api_endpoint + appropriate token.
  #       Raises NoClusterAvailableError if no cluster exists in the
  #       account yet.
  #
  #   .register_node_join!(node_instance:, role:, k8s_version:)
  #     → caller has joined; idempotently create the
  #       Devops::KubernetesNode row.
  #
  #   .mark_node_ready!(node_instance:, k8s_version:)
  #     → flip status to active (mirrors Docker's mark_daemon_ready).
  #
  #   .mark_node_stopped!(node_instance:)
  #     → flip status to disconnected.
  class KubernetesClusterProvisionerService
    class ProvisionError < StandardError; end
    class MissingSdwanPeerError < ProvisionError; end
    class NoClusterAvailableError < ProvisionError; end

    K3S_API_PORT = 6443

    def self.bootstrap!(**kwargs) = new(**kwargs).bootstrap!
    def self.join_request!(node_instance:) = new(node_instance: node_instance).join_request!

    def self.register_node_join!(node_instance:, role:, k8s_version: nil)
      new(node_instance: node_instance, role: role, k8s_version: k8s_version)
        .register_node_join!
    end

    def self.mark_node_ready!(node_instance:, k8s_version: nil)
      new(node_instance: node_instance, k8s_version: k8s_version).mark_node_ready!
    end

    def self.mark_node_stopped!(node_instance:)
      new(node_instance: node_instance).mark_node_stopped!
    end

    def initialize(node_instance: nil, kubeconfig: nil, server_token: nil,
                   agent_token: nil, k8s_version: nil, role: nil)
      @node_instance = node_instance
      @kubeconfig = kubeconfig
      @server_token = server_token
      @agent_token = agent_token
      @k8s_version = k8s_version
      @role = role
    end

    # ──────────────────────────────────────────────────────────────────
    # bootstrap! — first k3s-server in a cluster
    # ──────────────────────────────────────────────────────────────────

    def bootstrap!
      raise ArgumentError, "node_instance required" unless @node_instance
      raise ArgumentError, "kubeconfig required for bootstrap" if @kubeconfig.blank?
      raise ArgumentError, "server_token required for bootstrap" if @server_token.blank?

      account = @node_instance.account
      overlay_address = resolve_overlay_address!

      # Idempotent: if this NodeInstance is already a server in some
      # cluster, return that cluster. Operators can re-trigger bootstrap
      # to refresh stored credentials without duplicating rows.
      existing_node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      if existing_node && existing_node.server?
        update_credentials!(existing_node.kubernetes_cluster)
        return existing_node.kubernetes_cluster
      end

      cluster = nil
      ActiveRecord::Base.transaction do
        cluster = ::Devops::KubernetesCluster.create!(
          account: account,
          name: cluster_name_for(@node_instance),
          flavor: "k3s",
          environment: "production",
          status: "bootstrapping",
          api_endpoint: "https://[#{overlay_address}]:#{K3S_API_PORT}",
          k8s_version: @k8s_version,
          encrypted_kubeconfig: @kubeconfig,
          encrypted_server_token: @server_token,
          encrypted_agent_token: @agent_token.presence || @server_token,
          metadata: {
            "bootstrap_node_instance_id" => @node_instance.id,
            "bootstrap_overlay_address" => overlay_address,
            "bootstrapped_at" => Time.current.utc.iso8601
          }
        )

        ::Devops::KubernetesNode.create!(
          kubernetes_cluster: cluster,
          node_instance: @node_instance,
          name: kubelet_name_for(@node_instance),
          role: "server",
          status: "active",
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )

        cluster.update!(node_count: 1)
      end

      Rails.logger.info(
        "[KubernetesClusterProvisionerService] bootstrapped cluster " \
        "cluster_id=#{cluster.id} node_instance_id=#{@node_instance.id} " \
        "endpoint=#{cluster.api_endpoint}"
      )
      cluster
    end

    # ──────────────────────────────────────────────────────────────────
    # join_request! — k3s-agent asks "what cluster should I join?"
    # ──────────────────────────────────────────────────────────────────

    def join_request!
      raise ArgumentError, "node_instance required" unless @node_instance

      account = @node_instance.account

      # Find the most recent active cluster in the account. v1 only
      # supports one cluster per account; multi-cluster is a Phase 3
      # extension (operators will pick which cluster to join when
      # there are multiple).
      cluster = ::Devops::KubernetesCluster
                  .where(account_id: account.id)
                  .where.not(status: "error")
                  .order(created_at: :desc)
                  .first
      unless cluster
        raise NoClusterAvailableError,
              "no Kubernetes cluster available in account #{account.id} — " \
              "bootstrap a k3s-server first"
      end

      {
        cluster_id: cluster.id,
        api_endpoint: cluster.api_endpoint,
        agent_token: cluster.encrypted_agent_token,
        ca_pem: extract_ca_pem(cluster.encrypted_kubeconfig)
      }
    end

    # ──────────────────────────────────────────────────────────────────
    # register_node_join! — agent confirms it joined
    # ──────────────────────────────────────────────────────────────────

    def register_node_join!
      raise ArgumentError, "node_instance required" unless @node_instance
      raise ArgumentError, "role required (server|agent)" unless @role

      account = @node_instance.account
      cluster = ::Devops::KubernetesCluster
                  .where(account_id: account.id)
                  .where.not(status: "error")
                  .order(created_at: :desc)
                  .first
      raise NoClusterAvailableError, "no cluster to register against" unless cluster

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      if node
        node.update!(
          kubernetes_cluster: cluster,
          role: @role,
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )
      else
        node = ::Devops::KubernetesNode.create!(
          kubernetes_cluster: cluster,
          node_instance: @node_instance,
          name: kubelet_name_for(@node_instance),
          role: @role,
          status: "joining",
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )
        cluster.increment!(:node_count)
      end
      node
    end

    # ──────────────────────────────────────────────────────────────────
    # mark_node_ready! — agent reports kubelet/server is up
    # ──────────────────────────────────────────────────────────────────

    def mark_node_ready!
      raise ArgumentError, "node_instance required" unless @node_instance

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      raise NoClusterAvailableError, "no cluster membership for this NodeInstance" unless node

      node.update!(
        status: "active",
        k8s_version: @k8s_version || node.k8s_version,
        last_heartbeat_at: Time.current
      )

      # If this was the bootstrap server flipping to active, promote
      # the cluster status from bootstrapping to active too.
      cluster = node.kubernetes_cluster
      if cluster.bootstrapping? && node.server? && node.active?
        cluster.update!(status: "active")
      end

      node
    end

    # ──────────────────────────────────────────────────────────────────
    # mark_node_stopped! — agent reports clean shutdown
    # ──────────────────────────────────────────────────────────────────

    def mark_node_stopped!
      raise ArgumentError, "node_instance required" unless @node_instance

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      return nil unless node

      node.update!(status: "disconnected", last_heartbeat_at: Time.current)
      node
    end

    # ──────────────────────────────────────────────────────────────────
    # Internals
    # ──────────────────────────────────────────────────────────────────

    private

    def resolve_overlay_address!
      peer = ::Sdwan::Peer.where(node_instance_id: @node_instance.id)
                          .where.not(assigned_address: nil)
                          .order(:created_at)
                          .first
      unless peer
        raise MissingSdwanPeerError,
              "NodeInstance #{@node_instance.id} has no SDWAN peer with an " \
              "assigned overlay address — assign an Sdwan::Peer before " \
              "bootstrapping a k3s cluster"
      end
      peer.assigned_address.to_s.split("/").first
    end

    def update_credentials!(cluster)
      attrs = { k8s_version: @k8s_version || cluster.k8s_version }
      attrs[:encrypted_kubeconfig] = @kubeconfig if @kubeconfig.present?
      attrs[:encrypted_server_token] = @server_token if @server_token.present?
      attrs[:encrypted_agent_token] = @agent_token if @agent_token.present?
      cluster.update!(attrs) if attrs.any? { |k, v| v.present? && cluster.send(k) != v }
    end

    # Best-effort CA extraction from a kubeconfig YAML string. The
    # platform doesn't strictly need it (kubectl bundled with k3s
    # uses the kubeconfig directly), but exposing it lets non-kubectl
    # clients (Helm, Argo CD) trust the API server. We don't parse
    # YAML here — that requires the `psych` gem at parse time which
    # is heavy. Phase 3 will add a kubeconfig parser; for now we
    # return nil and clients must use the kubeconfig.
    def extract_ca_pem(_kubeconfig_yaml)
      nil
    end

    def cluster_name_for(node_instance)
      base = node_instance.name.presence || "instance-#{node_instance.id[0, 8]}"
      "#{base}-k8s"
    end

    def kubelet_name_for(node_instance)
      node_instance.name.presence || "instance-#{node_instance.id[0, 8]}"
    end
  end
end
