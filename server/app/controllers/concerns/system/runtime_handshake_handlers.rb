# frozen_string_literal: true

module System
  # Per-phase handshake handlers for
  # Api::V1::System::NodeApi::RuntimeController#handshake.
  #
  # Behavior-preserving relocation: the docker/k3s phase handlers are an
  # exact move out of the controller (which keeps the handshake action's
  # allow-list guards — RUNTIME_MODULES / ALLOWED_PHASES / module_assigned?
  # — and the phase dispatch). Mixed in as private instance methods, so
  # render_success / render_error / params / current_instance resolve
  # against the controller exactly as before. DAEMON_CERT_TTL_SECONDS moves
  # with handle_wants_cert (its only consumer).
  module RuntimeHandshakeHandlers
    extend ActiveSupport::Concern

    # Server cert TTL for Docker daemon-side mTLS. Matches the
    # platform's client cert TTL chosen by
    # DockerDaemonProvisionerService — keeps both halves on the
    # same rotation cadence. Not used for K3s (k3s manages its
    # own PKI).
    DAEMON_CERT_TTL_SECONDS = 90 * 24 * 3600

    private

    def handle_wants_cert(runtime)
      csr_pem = params[:csr_pem].to_s
      if csr_pem.blank?
        return render_error("csr_pem required for phase=wants_cert", :unprocessable_content)
      end

      case runtime
      when "docker"
        # Idempotent — creates the managed DockerHost on first cert
        # request, no-op on subsequent (rotation) requests.
        ::System::DockerDaemonProvisionerService.provision!(
          node_instance: current_instance,
          account: current_instance.account
        )
        common_name = "docker-daemon-#{current_instance.id}"
      end

      result = ::System::InternalCaService.issue_certificate(
        csr_pem: csr_pem,
        ttl_seconds: DAEMON_CERT_TTL_SECONDS,
        common_name: common_name
      )

      render_success(
        certificate: {
          cert_pem: result[:cert_pem],
          ca_chain_pem: result[:ca_chain_pem],
          serial: result[:serial],
          not_after: result[:not_after]&.utc&.iso8601
        }
      )
    rescue ::System::DockerDaemonProvisionerService::MissingSdwanPeerError => e
      render_error(e.message, :unprocessable_content)
    rescue ::System::InternalCaService::CsrError => e
      render_error("invalid CSR: #{e.message}", :bad_request)
    rescue ::System::InternalCaService::CaError => e
      Rails.logger.error("[RuntimeController] CA error: #{e.class}: #{e.message}")
      render_error("certificate authority unavailable", :service_unavailable)
    end

    def handle_ready(runtime)
      case runtime
      when "docker"
        handle_docker_ready
      when "k3s_server", "k3s_agent"
        handle_k3s_ready
      end
    end

    def handle_stopped(runtime)
      case runtime
      when "docker"
        handle_docker_stopped
      when "k3s_server", "k3s_agent"
        handle_k3s_stopped
      end
    end

    # ────────────────────────────────────────────────────────────
    # Docker-specific handlers
    # ────────────────────────────────────────────────────────────

    def handle_docker_ready
      host = managed_docker_host_for_current_instance
      unless host
        return render_error(
          "no managed DockerHost found for this NodeInstance — " \
          "wants_cert must precede ready",
          :unprocessable_content
        )
      end

      ::System::DockerDaemonProvisionerService
        .new(docker_host: host, account: current_instance.account)
        .mark_daemon_ready!(host: host, docker_version: params[:version])

      render_success(data: {
        host_id: host.id,
        host_status: host.reload.status,
        api_endpoint: host.api_endpoint
      })
    end

    def handle_docker_stopped
      host = managed_docker_host_for_current_instance
      host&.update!(status: "disconnected")
      render_success(data: { acknowledged: true, host_id: host&.id })
    end

    def managed_docker_host_for_current_instance
      ::Devops::DockerHost.managed.find_by(node_instance_id: current_instance.id)
    end

    # ────────────────────────────────────────────────────────────
    # K3s-specific handlers
    # ────────────────────────────────────────────────────────────

    # phase=bootstrap (k3s_server only) — agent reports cluster up.
    # Body: { kubeconfig, server_token, agent_token, k8s_version }.
    # Idempotent: re-bootstrapping refreshes credentials.
    def handle_bootstrap(_runtime)
      kubeconfig = params[:kubeconfig].to_s
      server_token = params[:server_token].to_s
      if kubeconfig.blank? || server_token.blank?
        return render_error(
          "kubeconfig and server_token required for phase=bootstrap",
          :unprocessable_content
        )
      end

      cluster = ::System::KubernetesClusterProvisionerService.bootstrap!(
        node_instance: current_instance,
        kubeconfig: kubeconfig,
        server_token: server_token,
        agent_token: params[:agent_token].to_s.presence || server_token,
        k8s_version: params[:k8s_version].to_s
      )

      render_success(data: {
        cluster_id: cluster.id,
        cluster_status: cluster.status,
        api_endpoint: cluster.api_endpoint
      })
    rescue ::System::KubernetesClusterProvisionerService::MissingSdwanPeerError => e
      render_error(e.message, :unprocessable_content)
    end

    # phase=join_request (k3s_agent only) — agent asks for the
    # cluster's api_endpoint + agent_token so it can run
    # `k3s agent --server <api> --token <token>`.
    #
    # Multi-cluster awareness: the agent must include target_cluster_id
    # when the account has more than one active cluster. A single active
    # cluster is resolved without one; with several, the request is
    # refused (409) rather than auto-selecting the wrong cluster.
    def handle_join_request(_runtime)
      payload = ::System::KubernetesClusterProvisionerService.join_request!(
        node_instance: current_instance,
        target_cluster_id: params[:target_cluster_id].presence
      )
      render_success(data: payload)
    rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e
      render_error(e.message, :unprocessable_content)
    rescue ::System::KubernetesClusterProvisionerService::AmbiguousClusterError => e
      render_error(e.message, :conflict)
    end

    # Generic K3s ready handler — applies to both server (HA
    # additional control-plane joining) and agent (worker
    # joining).
    #
    # phase=ready re-fires on every k3s version change / rolling
    # upgrade / state loss, so cluster_id (the agent's own cached
    # join/bootstrap cluster_id — see k3sd.HandshakeRequest.ClusterID)
    # is forwarded as target_cluster_id. Without it,
    # register_node_join! would have to guess "most recent cluster in
    # the account" on every re-fire, silently relocating an
    # already-joined node the moment a second cluster exists.
    def handle_k3s_ready
      role = params[:role].to_s.presence ||
             (params[:runtime] == "k3s_server" ? "server" : "agent")
      version = params[:version].to_s.presence || params[:k8s_version].to_s.presence

      # First time we see this NodeInstance ready, register the
      # join (if not already). Idempotent.
      ::System::KubernetesClusterProvisionerService.register_node_join!(
        node_instance: current_instance,
        role: role,
        k8s_version: version,
        target_cluster_id: params[:cluster_id].presence
      )
      node = ::System::KubernetesClusterProvisionerService.mark_node_ready!(
        node_instance: current_instance,
        k8s_version: version
      )

      render_success(data: {
        node_id: node.id,
        cluster_id: node.kubernetes_cluster_id,
        node_status: node.status,
        role: node.role
      })
    rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e
      render_error(e.message, :unprocessable_content)
    rescue ::System::KubernetesClusterProvisionerService::AmbiguousClusterError => e
      render_error(e.message, :conflict)
    end

    def handle_k3s_stopped
      node = ::System::KubernetesClusterProvisionerService.mark_node_stopped!(
        node_instance: current_instance
      )
      render_success(data: { acknowledged: true, node_id: node&.id })
    end
  end
end
