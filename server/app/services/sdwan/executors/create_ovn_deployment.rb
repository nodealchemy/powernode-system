# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_deployment_create` (IMP-97c7b4123d8f).
    class CreateOvnDeployment < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_deployment_create"

      protected

      def perform
        deployment = ::Sdwan::OvnDeployment.create!(
          account: account,
          nb_db_endpoint: params[:nb_db_endpoint],
          sb_db_endpoint: params[:sb_db_endpoint],
          northd_host: params[:northd_host],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        { deployment_id: deployment.id }
      end

      def summarize = "Create the OVN control-plane deployment"
      def impact    = "Registers the account's OVN northbound/southbound endpoints"
    end
  end
end
