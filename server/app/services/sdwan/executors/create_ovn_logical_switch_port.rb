# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_port_create` (IMP-97c7b4123d8f).
    class CreateOvnLogicalSwitchPort < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_port_create"

      protected

      def perform
        switch = resolve_scoped(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])
        host = params[:host_node_instance_id].presence &&
               resolve_scoped(::System::NodeInstance, params[:host_node_instance_id])

        port = switch.ports.new(
          account: switch.account,
          name: params[:name],
          kind: params[:kind].to_s,
          host_node_instance: host,
          addresses: Array(params[:addresses]).map(&:to_s),
          mac: params[:mac].presence
        )
        port.save!
        { port_id: port.id, name: port.name }
      end

      def summarize = "Create OVN logical switch port #{params[:name]}"
      def impact    = "Attaches a port the compiler emits into the OVN northbound DB"
    end
  end
end
