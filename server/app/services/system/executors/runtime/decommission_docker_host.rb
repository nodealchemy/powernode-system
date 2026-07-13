# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class DecommissionDockerHost < ::System::Executors::Base
        protected

        def perform
          # ::DockerHost is not a top-level constant — the model is
          # Devops::DockerHost — so this raised NameError on every call.
          # ::System::DockerHostDecommissionService also doesn't exist;
          # the real teardown (Vault purge + destroy, transactional) lives
          # on DockerDaemonProvisionerService#decommission!, gated to
          # managed hosts only. External (operator-registered) hosts have
          # no Vault-issued TLS material to purge, so they're destroyed
          # directly, same as before.
          host = ::Devops::DockerHost.find(params[:host_id])
          if host.managed?
            ::System::DockerDaemonProvisionerService.new(docker_host: host, account: account).decommission!
          else
            host.destroy!
          end
          { host_id: params[:host_id], decommissioned: true }
        end

        def summarize = "Decommission Docker host #{params[:host_id]}"
        def impact    = "Stops dockerd, revokes TLS certs, destroys the host record"
      end
    end
  end
end
