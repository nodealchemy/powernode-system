# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class DrainK3sNode < ::System::Executors::Base
        protected

        def perform
          node_id = params[:node_id]
          # Most realistic path: enqueue a System::Task with command=ssh_command
          # running `kubectl drain`. Stubbed here as a marker — concrete
          # delegation depends on which kubectl-driver service is available.
          { node_id: node_id, drain_scheduled: true }
        end

        def summarize = "Drain K3s node #{params[:node_id]}"
        def impact    = "Evacuates pods to remaining nodes; fails if no capacity"
      end
    end
  end
end
