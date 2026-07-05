# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class ProvisionDockerHost < ::System::Executors::Base
        protected

        def perform
          # Delegates to existing System::DockerDaemonProvisionerService.
          # The service takes node_instance:/docker_host:/account: — it has
          # no instance_id:/options: kwargs, so this used to raise
          # ArgumentError on every call. provision! also returns the created
          # Devops::DockerHost record, not a result hash to #dig.
          instance = ::System::NodeInstance.find(params[:instance_id])
          host = ::System::DockerDaemonProvisionerService.new(
            node_instance: instance,
            account: account
          ).provision!
          { instance_id: instance.id, host_id: host.id, status: host.status }
        end

        def summarize = "Provision Docker daemon on instance #{params[:instance_id]}"
        def impact    = "Brings up dockerd, mints TLS certs, registers the host"
      end
    end
  end
end
