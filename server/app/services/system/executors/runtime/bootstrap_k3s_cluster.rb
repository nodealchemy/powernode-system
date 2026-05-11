# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class BootstrapK3sCluster < ::System::Executors::Base
        protected

        def perform
          service = ::System::KubernetesClusterProvisionerService.new(
            account: account,
            attributes: params[:attributes].to_h.symbolize_keys
          )
          cluster = service.bootstrap!
          { cluster_id: cluster&.id, status: cluster&.status }
        end

        def summarize = "Bootstrap K3s cluster #{params.dig(:attributes, :name)}"
        def impact    = "Provisions a new K3s cluster control plane + first node"
      end
    end
  end
end
