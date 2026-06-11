# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # AI/MCP workload substrate L0 — node-facing isolation config. The agent
        # pulls the isolation runtimes it should provision on its Docker daemon
        # (e.g. ["gvisor"] -> install runsc + register it) from its instance's
        # recorded isolation tier (NodeInstance.config["isolation"]). The dockerd
        # reconcile consumes these as RequestedRuntimes.
        #
        # GET /api/v1/system/node_api/isolation/runtimes
        #   Auth: instance (BaseController).
        #   Response: { runtimes: ["gvisor"], default_runtime: "runsc" }
        #   default_runtime (F2-01) is the OCI runtime the agent sets as the
        #   daemon.json default-runtime on this instance's own daemon — the
        #   fleet-path enforcement point for the recorded isolation tier.
        class IsolationController < BaseController
          def runtimes
            render_success(
              runtimes: ::System::IsolationTier.required_runtimes_for(current_instance),
              default_runtime: ::System::IsolationTier.default_runtime_for(current_instance)
            )
          end
        end
      end
    end
  end
end
