# frozen_string_literal: true

module System
  module Autonomy
    # Shared kill-switch guard for every autonomy reconcile tick.
    #
    # The emergency kill-switch (Ai::Autonomy::KillSwitchService#emergency_halt!)
    # suspends ALL agentic activity for an account. Every reconciler that can
    # actuate — dispatch tasks, reap instances, remediate CVEs — MUST consult it
    # and no-op while engaged, so an operator's emergency stop is AUTHORITATIVE
    # across the whole autonomy surface, not just the AI execution jobs that
    # already carry the worker-side AiSuspensionCheckConcern.
    #
    # Mix into a reconcile service that exposes `#account` and early-return from
    # its tick entrypoint before any sensing/deciding/actuating runs:
    #
    #   def tick!
    #     return halted_tick_result if kill_switch_engaged?
    #     ...
    #   end
    #
    # New reconcilers inherit the behaviour simply by including the module and
    # adding the one guard line.
    module KillSwitchGuard
      # True when the account's AI activity is under emergency halt. Reads the
      # canonical suspension state through the core KillSwitchService so the
      # definition of "halted" stays single-sourced — a reconciler inherits any
      # future expansion of that definition for free.
      def kill_switch_engaged?
        ::Ai::Autonomy::KillSwitchService.new(account: account).halted?
      end

      # Uniform no-op summary returned by a tick that declined to run because the
      # kill-switch is engaged. `ok: false` marks it as "did not reconcile" (same
      # shape as the not-seeded-agent bail), and `halted: true` lets callers and
      # dashboards distinguish an emergency stop from an ordinary empty tick.
      def halted_tick_result
        {
          ok: false,
          halted: true,
          reason: "emergency kill-switch engaged for account #{account.id} — reconcile skipped"
        }
      end
    end
  end
end
