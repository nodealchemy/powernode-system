# frozen_string_literal: true

module System
  module Autonomy
    # Dual-plane standby fence for every autonomy reconcile tick.
    #
    # When the control_plane_role_coordinator SiteSetting arms RCP dual-plane
    # mode, exactly one plane may actuate; the other must do nothing. The gate
    # itself is ControlPlaneRole.active? — inert (true) while unarmed so
    # single-plane deployments are unaffected, and fail-toward-standby once
    # armed. A gate nothing consults fences nothing, so every reconciler that
    # can actuate MUST consult it, immediately after the kill-switch check
    # (the emergency halt outranks the fence as the reported reason):
    #
    #   def tick!
    #     return halted_tick_result if kill_switch_engaged?
    #     return standby_tick_result unless control_plane_active?
    #     ...
    #   end
    module ControlPlaneGuard
      def control_plane_active?
        ::System::Autonomy::ControlPlaneRole.active?
      end

      # Uniform no-op summary returned by a tick declined on the standby plane.
      # `ok: false` marks it as "did not reconcile" (same shape as the
      # kill-switch bail); `standby: true` lets callers and dashboards
      # distinguish a fenced plane from an emergency stop or an empty tick.
      #
      # The reason distinguishes a genuine fence from a gate ERROR
      # (IMP-211d8e0fb9e7): when the gate raised — possibly in the armed? read
      # itself — armed-ness is unknown, and claiming "dual-plane mode is armed"
      # on an unarmed plane would send an operator hunting a fence that does
      # not exist. Callers may pass the status they already read; called bare,
      # this takes a fresh one (the extra read only happens on the declined
      # path).
      def standby_tick_result(status: nil)
        status ||= ::System::Autonomy::ControlPlaneRole.status
        reason =
          if status == :gate_error
            "control-plane gate error — role could not be determined; standing down (fail-closed). " \
              "Check the ControlPlaneRole log lines for the underlying failure"
          else
            "dual-plane mode is armed and this control plane is not the active one — reconcile skipped"
          end

        { ok: false, standby: true, gate_status: status, reason: reason }
      end
    end
  end
end
