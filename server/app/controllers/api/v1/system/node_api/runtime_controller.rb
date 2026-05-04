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
          # name that authorizes it. Adding K3s/kubeadm in Phase 2/3 only
          # touches this constant + the per-runtime branches below.
          RUNTIME_MODULES = {
            "docker" => "docker-engine"
          }.freeze

          PHASES = %w[wants_cert ready stopped].freeze

          # Server cert TTL for daemon-side mTLS. Matches the platform's
          # client cert TTL chosen by DockerDaemonProvisionerService — keeps
          # both halves on the same rotation cadence.
          DAEMON_CERT_TTL_SECONDS = 90 * 24 * 3600

          # POST /api/v1/system/node_api/runtime/handshake
          def handshake
            runtime = params[:runtime].to_s
            phase = params[:phase].to_s

            unless RUNTIME_MODULES.key?(runtime)
              return render_error("unsupported runtime: #{runtime}", :unprocessable_entity)
            end
            unless PHASES.include?(phase)
              return render_error("invalid phase: #{phase}", :unprocessable_entity)
            end
            unless module_assigned?(runtime)
              return render_error(
                "module '#{RUNTIME_MODULES[runtime]}' not enabled for this node — assign it before " \
                "the agent attempts a runtime handshake",
                :forbidden
              )
            end

            case phase
            when "wants_cert" then handle_wants_cert(runtime)
            when "ready"      then handle_ready(runtime)
            when "stopped"    then handle_stopped(runtime)
            end
          end

          private

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

            # `status:` is a render_success keyword arg (HTTP status code), so
            # the response payload has to live behind the explicit `data:`
            # key — otherwise Rails tries to set HTTP status to "connected".
            render_success(data: {
              host_id: host.id,
              host_status: host.reload.status,
              api_endpoint: host.api_endpoint
            })
          end

          def handle_stopped(_runtime)
            host = managed_docker_host_for_current_instance
            host&.update!(status: "disconnected")
            render_success(data: { acknowledged: true, host_id: host&.id })
          end

          def managed_docker_host_for_current_instance
            ::Devops::DockerHost.managed.find_by(node_instance_id: current_instance.id)
          end
        end
      end
    end
  end
end
