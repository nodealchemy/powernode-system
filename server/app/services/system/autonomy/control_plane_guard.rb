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
      def standby_tick_result
        {
          ok: false,
          standby: true,
          reason: "dual-plane mode is armed and this control plane is not the active one — reconcile skipped"
        }
      end
    end
  end
end
