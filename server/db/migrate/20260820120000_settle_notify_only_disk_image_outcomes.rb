# frozen_string_literal: true

# IMP-71f7ca1ff35b — settle the residue a LIVE notify-only lane left behind.
#
# system.disk_image_publication_investigate proceeds without ever attempting a
# remediation: DiskImagePublicationFailureStreakSensor is registered and
# emitting, its DecisionEngine binding carries skill: nil, and the binding's own
# comment says why — "a broken CI pipeline needs operator investigation, not an
# automated retry". RemediationValidator nonetheless minted a pending
# RemediationOutcome for every proceed, nothing could ever clear it, and each
# settle window scored it `ineffective` until the F3-11 streak manufactured a
# false fleet.remediation_stuck HIGH escalation and forced require_approval on a
# lane that never acted.
#
# The code fix (adding the category to
# RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES) stops NEW mints and
# nothing else. The rows already written keep the defect running in both of
# their states:
#
#   pending     — #validate_due! scopes on `due` (pending past settle_until)
#                 with NO category filter, so each is scored ineffective on the
#                 next tick exactly as before;
#   ineffective — .ineffective_streak reads `status IN (effective, ineffective)`
#                 newest-first, so a fingerprint that already reached
#                 STUCK_STREAK_THRESHOLD keeps escalating after the fix.
#
# SWEEP, not leave — stated as the disposition this task asked for. Leaving them
# would mean the fix does not actually stop the escalation it exists to stop.
#
# `inconclusive` rather than DELETE: it is a declared STATUSES member, it is
# excluded from both `due` and ineffective_streak's filter, and it is the honest
# description of an outcome nothing could ever score. Deleting would destroy the
# evidence that this lane misbehaved, which is the only record of the defect's
# reach on a given install.
#
# NOT swept: rows already scored `effective`. One of those is a real data point
# — the condition genuinely cleared inside the window — and rewriting it would
# be falsifying the table the LEARN step reads.
#
# Data-only, no DDL. Idempotent: a swept row is no longer `pending` or
# `ineffective`, so a re-run matches nothing.
class SettleNotifyOnlyDiskImageOutcomes < ActiveRecord::Migration[8.1]
  ACTION_CATEGORY = "system.disk_image_publication_investigate"
  SWEPT_STATUSES  = %w[pending ineffective].freeze
  BATCH_SIZE      = 1_000

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks can drift out from under it.
  class OutcomeRow < ActiveRecord::Base
    self.table_name = "system_fleet_remediation_outcomes"
  end

  def up
    now = Time.current
    total = 0

    sweepable.in_batches(of: BATCH_SIZE) do |batch|
      total += batch.update_all(
        status: "inconclusive",
        validated_at: now,
        updated_at: now
      )
    end

    say "settled #{total} un-scoreable #{ACTION_CATEGORY} outcome(s) as inconclusive"
  end

  def down
    # Not reversible: the prior status was either a pending row that could never
    # be scored or an `ineffective` verdict that was never earned, and restoring
    # either re-opens the false escalation.
  end

  private

  def sweepable
    OutcomeRow.where(action_category: ACTION_CATEGORY, status: SWEPT_STATUSES)
  end
end
