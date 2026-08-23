# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_port_update` (IMP-97c7b4123d8f).
    class ActivateOvnLogicalSwitchPort < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_port_update"

      protected

      def perform
        port = resolve_scoped(::Sdwan::OvnLogicalSwitchPort, params[:port_id])
        raise ArgumentError, "cannot activate a #{port.state} logical switch port" unless port.mark_active!

        { port_id: port.id, state: port.reload.state }
      end

      def summarize = "Activate OVN logical switch port #{(scoped_label_record(::Sdwan::OvnLogicalSwitchPort, params[:port_id])&.name || params[:port_id])}"
      def impact    = "Puts the port into the compiled OVN plan"
    end
  end
end
