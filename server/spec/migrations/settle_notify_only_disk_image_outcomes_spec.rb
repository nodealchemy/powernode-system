# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260820120000_settle_notify_only_disk_image_outcomes.rb"
)

# IMP-71f7ca1ff35b — the residue the code fix cannot reach.
#
# Adding system.disk_image_publication_investigate to
# RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES stops NEW outcomes
# being minted. It does nothing about the ones this LIVE lane already wrote,
# and both of their states keep the defect running:
#
#   pending     — #validate_due! scopes on `due` (pending past settle_until)
#                 with NO category filter, so each one is scored `ineffective`
#                 on the next tick, exactly as before.
#   ineffective — .ineffective_streak reads `status IN (effective, ineffective)`
#                 ordered by validated_at, so rows already written still count
#                 toward STUCK_STREAK_THRESHOLD. A fingerprint that reached the
#                 threshold before the fix keeps escalating after it.
#
# So the disposition is SWEEP, not leave: leaving them means the fix does not
# actually stop the false escalation it was written to stop.
#
# `inconclusive` rather than deletion: it is a declared STATUSES member, it is
# excluded from ineffective_streak's filter and from `due`, and it is the
# honest description of a row nothing could ever score. Deleting would destroy
# the evidence that this lane misbehaved.
RSpec.describe SettleNotifyOnlyDiskImageOutcomes do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }

  def outcome(status:, category: "system.disk_image_publication_investigate", fingerprint: "fp-1")
    System::Fleet::RemediationOutcome.create!(
      account: account, signal_kind: "system.disk_image_publication_failure_streak",
      fingerprint: fingerprint, action_category: category, status: status,
      acted_at: 2.days.ago, settle_until: 1.day.ago,
      validated_at: (status == "pending" ? nil : 1.day.ago)
    )
  end

  it "stops a leftover pending row from being scored on the next tick" do
    row = outcome(status: "pending")
    expect(System::Fleet::RemediationOutcome.due).to include(row)

    migration.up

    expect(row.reload.status).to eq("inconclusive")
    expect(System::Fleet::RemediationOutcome.due).not_to include(row)
  end

  it "removes leftover ineffective rows from the F3-11 streak" do
    3.times { |i| outcome(status: "ineffective", fingerprint: "fp-streak").update!(validated_at: i.hours.ago) }
    expect(System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: "fp-streak"))
      .to eq(3)

    migration.up

    expect(System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: "fp-streak"))
      .to eq(0), "historical rows kept feeding the escalation the code fix was meant to stop"
  end

  it "leaves another category's outcomes alone" do
    row = outcome(status: "ineffective", category: "system.module_drift", fingerprint: "fp-other")

    migration.up

    expect(row.reload.status).to eq("ineffective")
  end

  it "leaves an already-scored EFFECTIVE row alone — it is a real data point" do
    row = outcome(status: "effective", fingerprint: "fp-eff")

    migration.up

    expect(row.reload.status).to eq("effective")
  end

  it "is idempotent" do
    row = outcome(status: "pending")
    migration.up
    first = row.reload.updated_at

    migration.up

    expect(row.reload.updated_at).to eq(first)
  end
end
