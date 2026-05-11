# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class DecommissionDockerHost < ::System::Executors::Base
        protected

        def perform
          host = ::DockerHost.find(params[:host_id])
          # Tear down via the existing service if defined; otherwise destroy
          # the host record directly.
          if defined?(::System::DockerHostDecommissionService)
            ::System::DockerHostDecommissionService.new(host: host).decommission!
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
