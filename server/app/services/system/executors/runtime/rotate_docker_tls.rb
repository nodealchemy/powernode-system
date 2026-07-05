# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class RotateDockerTls < ::System::Executors::Base
        # Raised until a real TLS-rotation backend exists for managed
        # Docker daemons. Per db/seeds/system_runtime_manager_agent.rb,
        # this action was intentionally dropped from the seeded policies
        # because no executor implementation exists — operators rotate via
        # system.cert_rotate or by re-running the daemon provisioner.
        class NotYetImplementedError < StandardError; end

        protected

        def perform
          # ::DockerHost is not a top-level constant (NameError) and
          # Devops::DockerHost has no #rotate_tls! method, so
          # `host.respond_to?(:rotate_tls!)` was always false — this
          # silently reported `rotated: true` without ever touching TLS
          # material. Refuse to fake success; a TLS-rotate gate this
          # confident is exactly where a false positive is dangerous.
          host = ::Devops::DockerHost.find(params[:host_id])
          raise NotYetImplementedError,
                "Docker daemon TLS rotation is not implemented for host #{host.id} " \
                "— rotate via system.cert_rotate, or re-provision the daemon " \
                "(system.runtime_docker_provision)"
        end

        def summarize = "Rotate Docker daemon TLS for host #{params[:host_id]}"
        def impact    = "Not implemented — raises rather than faking a completed rotation"
      end
    end
  end
end
