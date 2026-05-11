# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class DecommissionK3sCluster < ::System::Executors::Base
        protected

        def perform
          cluster = ::Devops::KubernetesCluster.find(params[:cluster_id])
          name = cluster.name
          cluster.destroy!
          { cluster_id: params[:cluster_id], name: name, decommissioned: true }
        end

        def summarize
          c = ::Devops::KubernetesCluster.find_by(id: params[:cluster_id])
          c ? "Decommission K3s cluster '#{c.name}'" : "Decommission K3s cluster"
        end

        def impact = "Cascade-deletes node rows, tears down workloads, revokes kubeconfig"
      end
    end
  end
end
