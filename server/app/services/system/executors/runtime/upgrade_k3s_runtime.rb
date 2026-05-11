# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class UpgradeK3sRuntime < ::System::Executors::Base
        protected

        def perform
          cluster = ::Devops::KubernetesCluster.find(params[:cluster_id])
          target = params[:target_version]
          # Stub — full upgrade orchestration lives in dedicated service.
          { cluster_id: cluster.id, current_version: cluster.try(:version), target_version: target }
        end

        def summarize = "Upgrade K3s runtime to #{params[:target_version]}"
        def impact    = "Rolling restart of control plane + nodes; brief workload disruption possible"
      end
    end
  end
end
