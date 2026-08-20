# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_deployment_delete` (IMP-97c7b4123d8f).
    #
    # The most destructive arm of the O6 family: OvnDeployment is the
    # per-account OVN control-plane row that every logical switch hangs from,
    # and REST offers no equivalent verb at all.
    class DeleteOvnDeployment < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_deployment_delete"

      protected

      def perform
        deployment = resolve_scoped(::Sdwan::OvnDeployment, params[:deployment_id])
        status = deployment.status
        deployment.destroy!
        { deleted: true, deployment_id: params[:deployment_id], status: status }
      end

      def summarize = "Delete the OVN control-plane deployment #{params[:deployment_id]}"
      def impact    = "Removes the account's OVN control plane; every logical switch beneath it is orphaned"
    end
  end
end
