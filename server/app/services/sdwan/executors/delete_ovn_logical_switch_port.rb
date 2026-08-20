# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_port_delete` (IMP-97c7b4123d8f).
    class DeleteOvnLogicalSwitchPort < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_port_delete"

      protected

      def perform
        port = resolve_scoped(::Sdwan::OvnLogicalSwitchPort, params[:port_id])
        name = port.name
        port.destroy!
        { deleted: true, port_id: params[:port_id], name: name }
      end

      def summarize = "Delete OVN logical switch port #{(scoped_label_record(::Sdwan::OvnLogicalSwitchPort, params[:port_id])&.name || params[:port_id])}"
      def impact    = "Detaches the port from the logical switch"
    end
  end
end
