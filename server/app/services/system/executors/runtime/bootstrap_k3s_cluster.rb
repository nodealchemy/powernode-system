# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class BootstrapK3sCluster < ::System::Executors::Base
        protected

        def perform
          # The service takes node_instance:/kubeconfig:/server_token:/
          # agent_token:/k8s_version:/cni_plugin: — it has no account:/
          # attributes: kwargs, so this used to raise ArgumentError on every
          # call. instance_id identifies the bootstrap NodeInstance; the
          # rest of the payload rides under params[:attributes] like the
          # other create-style executors.
          instance = ::System::NodeInstance.find(params[:instance_id])
          cluster = ::System::KubernetesClusterProvisionerService.new(
            node_instance: instance,
            kubeconfig: attrs[:kubeconfig],
            server_token: attrs[:server_token],
            agent_token: attrs[:agent_token],
            k8s_version: attrs[:k8s_version],
            cni_plugin: attrs[:cni_plugin]
          ).bootstrap!
          { cluster_id: cluster.id, name: cluster.name, status: cluster.status }
        end

        def summarize = "Bootstrap K3s cluster on instance #{params[:instance_id]}"
        def impact    = "Provisions a new K3s cluster control plane + first node"
      end
    end
  end
end
