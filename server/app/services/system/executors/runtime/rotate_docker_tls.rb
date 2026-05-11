# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class RotateDockerTls < ::System::Executors::Base
        protected

        def perform
          host = ::DockerHost.find(params[:host_id])
          if host.respond_to?(:rotate_tls!)
            host.rotate_tls!
          end
          { host_id: params[:host_id], rotated: true }
        end

        def summarize = "Rotate Docker daemon TLS for host #{params[:host_id]}"
      end
    end
  end
end
