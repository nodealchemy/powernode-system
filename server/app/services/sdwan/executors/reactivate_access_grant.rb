# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.access_grant_reactivate` — restores VPN entitlement
    # to a user whose grant was revoked.
    #
    # IMP-343163bf37a4. There is no separate "reactivate" verb on either
    # operator surface: both call create, and because the grant is unique per
    # (network, user), `find_or_initialize_by` silently reuses the revoked row
    # and clears its revocation. So the same request is an additive grant for
    # one user and the exact inverse of an approval-gated revoke for another,
    # decided entirely by a row the caller never names.
    #
    # Splitting the CATEGORY rather than the code path is what makes that
    # visible to policy: the write is identical (this class exists to declare a
    # different ACTION_CATEGORY, and inherits every line of the write), while
    # `sdwan.access_grant_reactivate` is seeded require_approval to match
    # `sdwan.access_grant_revoke`. Keeping both under the create category would
    # not have gated the resurrection at all — Ai::AutonomyGate handles
    # notify_and_proceed exactly as auto_approve (autonomy_gate.rb:66-69):
    # execute_now! inline, no approval, and no notification either, since
    # Ai::DeferredOperation has no create hook. The audit row would have been
    # the only artifact.
    #
    # Which class a request gets is decided by the CURRENT state of the row it
    # would write, read at the gate site — never by the caller.
    class ReactivateAccessGrant < CreateAccessGrant
      ACTION_CATEGORY = "sdwan.access_grant_reactivate"

      protected

      def summarize
        return "Reinstate SDWAN access for #{grant_label}" if grant_label.present?

        "Reinstate SDWAN access on network #{network_label}"
      end

      def impact
        "Restores VPN entitlement that was revoked; previously revoked devices stay revoked " \
          "and must be re-issued"
      end
    end
  end
end
