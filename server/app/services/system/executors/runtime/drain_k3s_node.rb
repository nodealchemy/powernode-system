# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class DrainK3sNode < ::System::Executors::Base
        # Raised until a real kubectl-drain backend exists. See the
        # class-level note below — no driver is wired up yet.
        class NotYetImplementedError < StandardError; end

        protected

        def perform
          # This unconditionally reported `drain_scheduled: true` with no
          # backing implementation at all — every caller (including a
          # subsequent upgrade step relying on drain-before-upgrade) saw a
          # false success. Most realistic real path: enqueue a System::Task
          # with command=ssh_command running `kubectl drain` on a server
          # node in the cluster. That delegation isn't wired up yet, so
          # refuse to claim success rather than silently no-op.
          node = ::Devops::KubernetesNode.find(params[:node_id])
          raise NotYetImplementedError,
                "K3s node drain is not implemented for node #{node.id} (#{node.name}) " \
                "— drain manually via kubectl until a driver lands"
        end

        def summarize = "Drain K3s node #{params[:node_id]}"
        def impact    = "Not implemented — raises rather than faking a scheduled drain"
      end
    end
  end
end
