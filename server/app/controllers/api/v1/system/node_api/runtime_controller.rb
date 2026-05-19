# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Phase B — runtime daemon handshake endpoint.
        #
        # Container/Kubernetes daemons (currently `docker`; Phase 2 will add
        # `k3s_server`/`k3s_agent`; Phase 3 adds `kubeadm_*`) all share the
        # same lifecycle:
        #
        #   1. Agent installs the daemon binary via NodeModule assignment +
        #      reconciler.
        #   2. Agent generates a server keypair locally, builds a CSR, posts
        #      it here with phase=`wants_cert`. Platform signs via
        #      InternalCaService and returns the cert + CA chain.
        #   3. Agent writes daemon config, starts the systemd unit. Once the
        #      daemon is listening, agent posts phase=`ready` with version +
        #      observed listen address. Platform promotes the corresponding
        #      Devops::DockerHost (or future K8s cluster row) to status
        #      `connected`.
        #   4. If the daemon stops cleanly (module unassignment, planned
        #      maintenance), agent posts phase=`stopped` so platform marks
        #      the host disconnected without waiting for the sync watchdog
        #      to time out.
        #
        # Phase 2 will extend the runtime allow-list, but the controller
        # surface stays the same — that's the whole point of having one
        # endpoint per state-machine transition rather than per daemon type.
        class RuntimeController < BaseController
          # Maps the runtime identifier the agent sends to the NodeModule
          # name that authorizes it. Phase 3 will add kubeadm_*; the
          # controller itself stays generic, only this constant changes.
          RUNTIME_MODULES = {
            "docker"     => "docker-engine",
            "k3s_server" => "k3s-server",
            "k3s_agent"  => "k3s-agent"
          }.freeze

          # Per-runtime allowed phases. Docker uses CSR-issuance flow
          # (wants_cert → ready → stopped); K3s ships its own CA so it
          # uses bootstrap/join_request instead. The dispatcher gates
          # on (runtime, phase) pairs.
          ALLOWED_PHASES = {
            "docker"     => %w[wants_cert ready stopped].freeze,
            "k3s_server" => %w[bootstrap ready stopped].freeze,
            "k3s_agent"  => %w[join_request ready stopped].freeze
          }.freeze

          # Server cert TTL for Docker daemon-side mTLS. Matches the
          # platform's client cert TTL chosen by
          # DockerDaemonProvisionerService — keeps both halves on the
          # same rotation cadence. Not used for K3s (k3s manages its
          # own PKI).
          DAEMON_CERT_TTL_SECONDS = 90 * 24 * 3600

          # GET /api/v1/system/node_api/runtime/:runtime/config
          #
          # Slice 10 — returns the merged daemon.json overrides for this
          # NodeInstance. Agent calls this per-tick when running and
          # restarts dockerd if the merged config changed (hash diff).
          #
          # Currently scoped to runtime=docker; the path includes runtime
          # as a positional segment so K3s + kubeadm config delivery can
          # use the same surface in Phase 2/3 without redirecting.
          #
          # Action method is named `runtime_config` (not `config`) to
          # avoid shadowing ActionController's framework `config` method
          # — that collision causes infinite recursion through
          # `render_success` → `render` → `config`.
          def runtime_config
            runtime = params[:runtime].to_s
            unless RUNTIME_MODULES.key?(runtime)
              return render_error("unsupported runtime: #{runtime}", :unprocessable_entity)
            end
            unless module_assigned?(runtime)
              return render_error(
                "module '#{RUNTIME_MODULES[runtime]}' not enabled for this node — assign it before " \
                "the agent attempts a runtime config fetch",
                :forbidden
              )
            end

            case runtime
            when "docker"
              overrides = ::System::DockerDaemonOverridesResolver.resolve(
                node_instance: current_instance
              )
              render_success(data: {
                runtime: runtime,
                daemon_overrides: overrides,
                # ETag-style content hash — agent can short-circuit
                # on-disk writes when nothing changed. Phase 2 may add
                # If-None-Match handling for true 304 responses; for
                # now agents handle the diff client-side.
                content_hash: ::Digest::SHA256.hexdigest(overrides.to_json)
              })
            when "k3s_server"
              # Phase O4 — K3s server bootstrap config. Currently carries
              # cni_plugin (flannel | ovn_kubernetes) so k3sd knows
              # whether to pass --flannel-backend=none --disable-network-policy
              # at server install time. Future K3s knobs (cluster-cidr,
              # service-cidr, etc.) belong in the same bootstrap_config
              # envelope.
              bootstrap_config = k3s_server_bootstrap_config(current_instance)
              render_success(data: {
                runtime: runtime,
                bootstrap_config: bootstrap_config,
                content_hash: ::Digest::SHA256.hexdigest(bootstrap_config.to_json)
              })
            else
              # k3s_agent + kubeadm runtime config delivery is a
              # follow-up; return an empty payload so the agent doesn't
              # error out when probing newer endpoints from older
              # runtimes.
              render_success(data: {
                runtime: runtime,
                daemon_overrides: {},
                content_hash: ::Digest::SHA256.hexdigest("{}")
              })
            end
          end

          # POST /api/v1/system/node_api/runtime/handshake
          def handshake
            runtime = params[:runtime].to_s
            phase = params[:phase].to_s

            unless RUNTIME_MODULES.key?(runtime)
              return render_error("unsupported runtime: #{runtime}", :unprocessable_entity)
            end
            unless ALLOWED_PHASES[runtime].include?(phase)
              return render_error(
                "phase '#{phase}' not valid for runtime '#{runtime}' " \
                "(allowed: #{ALLOWED_PHASES[runtime].join(', ')})",
                :unprocessable_entity
              )
            end
            unless module_assigned?(runtime)
              return render_error(
                "module '#{RUNTIME_MODULES[runtime]}' not enabled for this node — assign it before " \
                "the agent attempts a runtime handshake",
                :forbidden
              )
            end

            case phase
            when "wants_cert"   then handle_wants_cert(runtime)
            when "bootstrap"    then handle_bootstrap(runtime)
            when "join_request" then handle_join_request(runtime)
            when "ready"        then handle_ready(runtime)
            when "stopped"      then handle_stopped(runtime)
            end
          end

          private

          # Phase O4 — derive the k3s_server bootstrap_config payload.
          # Looks up the cluster the host belongs to (via
          # Devops::KubernetesNode) and pulls cni_plugin from there.
          # Falls back to "flannel" (the K3s default, safe for any
          # unenrolled host) when the host has no cluster yet.
          #
          # K3s overlay (2026-05-19) — when the cluster carries a
          # pod_cidr (set at bootstrap when the SDWAN network has
          # pod_subnet_prefix + cni_plugin is flannel), also emit
          # flannel_iface + flannel_backend=host-gw + cluster_cidr so
          # the agent passes --flannel-iface + --flannel-backend +
          # --cluster-cidr at k3s install time. Zero-value strings
          # (empty) mean "k3s defaults" — the agent's InstallArgs is
          # zero-value safe.
          def k3s_server_bootstrap_config(instance)
            cluster = ::Devops::KubernetesNode
                        .where(node_instance_id: instance.id)
                        .joins(:kubernetes_cluster)
                        .first
                        &.kubernetes_cluster
            cni_plugin = cluster&.cni_plugin || "flannel"

            payload = { cni_plugin: cni_plugin, flannel_iface: "", flannel_backend: "", cluster_cidr: "" }

            return payload unless cni_plugin == "flannel"
            return payload if cluster.blank?

            pod_cidr = cluster.metadata.is_a?(Hash) ? cluster.metadata["pod_cidr"] : nil
            return payload if pod_cidr.blank?

            peer = ::Sdwan::Peer.where(node_instance_id: instance.id).first
            return payload unless peer&.network

            payload.merge(
              flannel_iface: "wg-sdwan-#{peer.network.network_handle}",
              flannel_backend: "host-gw",
              cluster_cidr: pod_cidr
            )
          end

          # Defense-in-depth: even if a malicious agent had a valid mTLS
          # cert (one that's been rotated out, say) this guard prevents it
          # from quietly spinning up a managed DockerHost row by claiming
          # to want a cert. The agent has to produce credentials AND the
          # operator has to have assigned the module to that node.
          def module_assigned?(runtime)
            module_name = RUNTIME_MODULES[runtime]
            current_instance.node
                            .node_modules
                            .where(name: module_name)
                            .exists?
          end

          def handle_wants_cert(runtime)
            csr_pem = params[:csr_pem].to_s
            if csr_pem.blank?
              return render_error("csr_pem required for phase=wants_cert", :unprocessable_entity)
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
            render_error(e.message, :unprocessable_entity)
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
                :unprocessable_entity
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
                :unprocessable_entity
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
            render_error(e.message, :unprocessable_entity)
          end

          # phase=join_request (k3s_agent only) — agent asks for the
          # cluster's api_endpoint + agent_token so it can run
          # `k3s agent --server <api> --token <token>`.
          #
          # Multi-cluster awareness (Phase 2.5): the agent may include
          # target_cluster_id to disambiguate when the account has
          # more than one cluster. Without it, behavior falls back to
          # auto-selecting the most recent active cluster (single-
          # cluster v1 contract).
          def handle_join_request(_runtime)
            payload = ::System::KubernetesClusterProvisionerService.join_request!(
              node_instance: current_instance,
              target_cluster_id: params[:target_cluster_id].presence
            )
            render_success(data: payload)
          rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e
            render_error(e.message, :unprocessable_entity)
          end

          # Generic K3s ready handler — applies to both server (HA
          # additional control-plane joining) and agent (worker
          # joining).
          def handle_k3s_ready
            role = params[:role].to_s.presence ||
                   (params[:runtime] == "k3s_server" ? "server" : "agent")

            # First time we see this NodeInstance ready, register the
            # join (if not already). Idempotent.
            ::System::KubernetesClusterProvisionerService.register_node_join!(
              node_instance: current_instance,
              role: role,
              k8s_version: params[:version].to_s.presence || params[:k8s_version].to_s.presence
            )
            node = ::System::KubernetesClusterProvisionerService.mark_node_ready!(
              node_instance: current_instance,
              k8s_version: params[:version].to_s.presence || params[:k8s_version].to_s.presence
            )

            render_success(data: {
              node_id: node.id,
              cluster_id: node.kubernetes_cluster_id,
              node_status: node.status,
              role: node.role
            })
          rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e
            render_error(e.message, :unprocessable_entity)
          end

          def handle_k3s_stopped
            node = ::System::KubernetesClusterProvisionerService.mark_node_stopped!(
              node_instance: current_instance
            )
            render_success(data: { acknowledged: true, node_id: node&.id })
          end
        end
      end
    end
  end
end
