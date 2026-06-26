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
          # Per-phase handshake handlers (docker/k3s ready/stopped/bootstrap/
          # join + wants_cert) live in this concern; the controller keeps the
          # allow-list guards + phase dispatch. Behavior-preserving relocation.
          include ::System::RuntimeHandshakeHandlers

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
              return render_error("unsupported runtime: #{runtime}", :unprocessable_content)
            end
            unless module_assigned?(runtime)
              return render_error(
                "module '#{RUNTIME_MODULES[runtime]}' not enabled for this node — assign it before " \
                "the agent attempts a runtime config fetch",
                :forbidden
              )
            end

            render_success(
              data: ::System::NodeApi::RuntimeConfigBuilder.build(
                runtime: runtime, instance: current_instance
              )
            )
          end

          # POST /api/v1/system/node_api/runtime/handshake
          def handshake
            runtime = params[:runtime].to_s
            phase = params[:phase].to_s

            unless RUNTIME_MODULES.key?(runtime)
              return render_error("unsupported runtime: #{runtime}", :unprocessable_content)
            end
            unless ALLOWED_PHASES[runtime].include?(phase)
              return render_error(
                "phase '#{phase}' not valid for runtime '#{runtime}' " \
                "(allowed: #{ALLOWED_PHASES[runtime].join(', ')})",
                :unprocessable_content
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
        end
      end
    end
  end
end
