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

        # IMP-8e4674f4d62d: anchored to the operation's account (was a bare
        # `find_by(id:)`), with the id on the no-name arm for the same reason
        # DeletePool carries it — that arm now also covers a row this account
        # does not own.
        def summarize
          cluster = scoped_label_record(::Devops::KubernetesCluster, params[:cluster_id])
          cluster ? "Decommission K3s cluster '#{cluster.name}'" : "Decommission K3s cluster #{params[:cluster_id]}"
        end

        def impact = "Cascade-deletes node rows, tears down workloads, revokes kubeconfig"
      end
    end
  end
end
