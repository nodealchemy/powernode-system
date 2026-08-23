# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_create` (IMP-97c7b4123d8f).
    class CreateOvnLogicalSwitch < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_create"

      protected

      def perform
        deployment = resolve_scoped(::Sdwan::OvnDeployment, params[:deployment_id])
        switch = deployment.logical_switches.create!(
          account: deployment.account,
          name: params[:name],
          cidr: params[:cidr],
          description: params[:description],
          settings: params[:settings].is_a?(Hash) ? params[:settings] : {}
        )
        { logical_switch_id: switch.id, name: switch.name }
      end

      def summarize = "Create OVN logical switch #{params[:name]}"
      def impact    = "Adds a logical switch the compiler emits into the OVN northbound DB"
    end
  end
end
