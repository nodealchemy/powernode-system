# frozen_string_literal: true

# IMP-086a88d44424 — one-shot repair for deferred operations parked BEFORE the
# device verbs were split out of Sdwan::Executors::RevokeAccessGrant.
#
# Those rows name executor_class "Sdwan::Executors::RevokeAccessGrant" and carry
# device_id in params. Since d5f50058, RevokeAccessGrant#reject_device_scoped_params!
# raises ArgumentError on exactly that shape — correctly, because
# AccessGrant#revoke! cascades to EVERY device on the grant, so serving a
# device-scoped verb there would take out a user's entire access when they asked
# to kill one lost phone. Ai::DeferredOperation stores executor_class as a STRING
# and constantizes it at approval time, so the guard is the only thing standing
# between a pre-split row and that cascade.
#
# The guard is right. These rows are the problem: each is a GUARANTEED failure on
# approval, and the phone is never revoked.
#
# WHAT IS AND IS NOT BROKEN, checked against current code rather than inherited
# from the offer text: the failure is NOT silent. Ai::ApprovalRequest
# #notify_source_of_decision rescues the raise, but since IMP-5547989e2bbd that
# rescue calls declare_execution_failure!, stamping execution_status "failed" and
# recording an approval_execution event; Ai::DeferredOperation#execute_now! also
# marks its own row failed before re-raising. So an operator CAN see it. What is
# broken is that the revocation never happens and somebody has to notice and
# re-issue it — which is what this repairs.
#
# Data-only, no DDL, so live installs pick it up with the ordinary auto-apply.
# Extension-side by design: the Sdwan:: literals below must not appear in core.
class RewriteDeviceScopedGrantRevokeOperations < ActiveRecord::Migration[8.1]
  GRANT_EXECUTOR  = "Sdwan::Executors::RevokeAccessGrant"
  DEVICE_EXECUTOR = "Sdwan::Executors::RevokeUserDevice"
  DEVICE_CATEGORY = "system.sdwan_user_device_revoke"

  # Statuses from which the executor can still run: `pending` dispatches when the
  # approval lands, `approved` when execute_now! is next called. `executing` is
  # in Ai::DeferredOperation's non-terminal set too, but it has already resolved
  # its constant, so rewriting it changes nothing about the call in flight — it
  # is included so a stranded row (crashed mid-execute) is repaired rather than
  # left naming a class that refuses it.
  #
  # completed / failed / rejected / expired are history. Rewriting history would
  # make the audit trail claim an action that never ran.
  NON_TERMINAL = %w[pending approved executing].freeze

  # The unrepairable case. RevokeUserDevice#scoped_device anchors on the GRANT
  # (AccessGrant.find(grant_id).user_devices.find(device_id)) — it is what
  # re-validates the pairing and inherits the account. Without grant_id the
  # rewrite would swap ArgumentError for RecordNotFound: a different crash, not a
  # fix. Marked failed with a reason instead, which is the honest terminal state
  # for an operation that cannot be carried out.
  FAILURE_REASON = "IMP-086a88d44424: parked before the device-executor split with " \
                   "device_id but no grant_id — Sdwan::Executors::RevokeUserDevice cannot " \
                   "resolve the device without its grant. Re-issue the device revocation."

  def up
    say "repointed #{repair_repairable!} device-scoped revoke operation(s) at #{DEVICE_EXECUTOR}"
    say "failed #{fail_unrepairable!} device-scoped revoke operation(s) that carry no grant_id"
  end

  def down
    # Not reversible in any useful sense: the down direction would re-point live
    # operations at an executor that refuses them by design, restoring a
    # guaranteed failure. The rows this touches are identifiable by their
    # executor_class either way.
  end

  private

  # Idempotent by construction: the rewrite moves rows OUT of the
  # executor_class this matches on, so a second run selects nothing and no
  # updated_at is touched.
  def repair_repairable!
    affected(<<~SQL.squish)
      UPDATE ai_deferred_operations
         SET executor_class  = #{q(DEVICE_EXECUTOR)},
             action_category = #{q(DEVICE_CATEGORY)},
             updated_at      = NOW()
       WHERE #{device_scoped_predicate}
         AND NULLIF(params->>'grant_id', '') IS NOT NULL
    SQL
  end

  # Also idempotent: `failed` is not in NON_TERMINAL, so a re-run skips them.
  def fail_unrepairable!
    affected(<<~SQL.squish)
      UPDATE ai_deferred_operations
         SET status        = 'failed',
             error_message = #{q(FAILURE_REASON)},
             executed_at   = COALESCE(executed_at, NOW()),
             updated_at    = NOW()
       WHERE #{device_scoped_predicate}
         AND NULLIF(params->>'grant_id', '') IS NULL
    SQL
  end

  # NULLIF(..., '') so a device_id present-but-blank reads as absent, matching
  # the executor guard's own `params[:device_id].blank?` test.
  def device_scoped_predicate
    <<~SQL.squish
      executor_class = #{q(GRANT_EXECUTOR)}
        AND status IN (#{NON_TERMINAL.map { |s| q(s) }.join(', ')})
        AND NULLIF(params->>'device_id', '') IS NOT NULL
    SQL
  end

  def affected(sql)
    connection.execute(sql).cmd_tuples
  end

  def q(value)
    connection.quote(value)
  end
end
