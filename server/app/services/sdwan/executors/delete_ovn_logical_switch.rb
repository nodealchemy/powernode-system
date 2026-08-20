# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_delete` (IMP-97c7b4123d8f).
    class DeleteOvnLogicalSwitch < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_delete"

      protected

      def perform
        switch = resolve_scoped(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])
        name = switch.name
        switch.destroy!
        { deleted: true, logical_switch_id: params[:logical_switch_id], name: name }
      end

      def summarize = "Delete OVN logical switch #{(scoped_label_record(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])&.name || params[:logical_switch_id])}"
      def impact    = "Removes the switch and every port and ACL beneath it"
    end
  end
end
