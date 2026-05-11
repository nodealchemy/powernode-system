# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class ProvisionDockerHost < ::System::Executors::Base
        protected

        def perform
          # Delegates to existing System::DockerDaemonProvisionerService.
          service = ::System::DockerDaemonProvisionerService.new(
            account: account,
            instance_id: params[:instance_id],
            options: params[:options].to_h.symbolize_keys
          )
          result = service.provision!
          { instance_id: params[:instance_id], status: result&.dig(:status) || "queued" }
        end

        def summarize = "Provision Docker daemon on instance #{params[:instance_id]}"
        def impact    = "Brings up dockerd, mints TLS certs, registers the host"
      end
    end
  end
end
