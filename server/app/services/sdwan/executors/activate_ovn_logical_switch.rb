# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_logical_switch_update` (IMP-97c7b4123d8f).
    #
    # OvnCompiler's `compilable` scope emits `active` switches only, so this
    # is the transition that puts the switch into the plan.
    class ActivateOvnLogicalSwitch < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_logical_switch_update"

      protected

      def perform
        switch = resolve_scoped(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])
        raise ArgumentError, "cannot activate a #{switch.state} logical switch" unless switch.mark_active!

        { logical_switch_id: switch.id, state: switch.reload.state }
      end

      def summarize = "Activate OVN logical switch #{(scoped_label_record(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])&.name || params[:logical_switch_id])}"
      def impact    = "Puts the switch into the compiled OVN plan"
    end
  end
end
