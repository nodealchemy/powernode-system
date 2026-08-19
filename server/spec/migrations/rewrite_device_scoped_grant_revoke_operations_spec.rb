# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260819120000_rewrite_device_scoped_grant_revoke_operations.rb"
)

# IMP-086a88d44424 — one-shot repair for deferred operations parked BEFORE the
# device verbs were split out of Sdwan::Executors::RevokeAccessGrant.
#
# Those rows carry executor_class "Sdwan::Executors::RevokeAccessGrant" with
# device_id in params. RevokeAccessGrant#reject_device_scoped_params! (landed
# d5f50058) now raises ArgumentError on exactly that shape — correctly, since
# AccessGrant#revoke! cascades to EVERY device on the grant and would take out a
# user's whole access when they asked to kill one lost phone.
#
# The guard is right; the in-flight rows are the problem. Each one is now a
# GUARANTEED failure on approval: the operator approves, the executor raises,
# and the device stays live on the fabric.
#
# SCOPE NOTE, corrected against current code rather than taken from the offer:
# the offer says "nothing surfaces the failure". That is no longer true.
# ApprovalRequest#notify_source_of_decision rescues, but since IMP-5547989e2bbd
# its rescue calls declare_execution_failure!, which stamps
# execution_status: "failed" and records an approval_execution event; and
# DeferredOperation#execute_now! marks its own row failed before re-raising. So
# the failure IS visible on both rows. What remains broken — and what this
# migration fixes — is that the revocation never happens and the operator has to
# notice and re-issue it.
RSpec.describe RewriteDeviceScopedGrantRevokeOperations do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:grant)   { create(:sdwan_access_grant, account: account) }
  let(:device)  { create(:sdwan_user_device, access_grant: grant) }

  def parked(status:, params:, executor: "Sdwan::Executors::RevokeAccessGrant",
             category: "sdwan.access_grant_revoke")
    Ai::DeferredOperation.create!(
      account: account, action_category: category, executor_class: executor,
      status: status, params: params, description: "Revoke SDWAN access grant #{grant.id}"
    )
  end

  describe "rows that can still execute" do
    it "repoints a pending device-scoped revoke at the device executor" do
      op = parked(status: "pending", params: { "grant_id" => grant.id, "device_id" => device.id })

      migration.up

      expect(op.reload.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
      expect(op.action_category).to eq("system.sdwan_user_device_revoke")
      expect(op.status).to eq("pending"), "the repair must not decide the operation"
    end

    it "repoints an approved-but-unexecuted row too" do
      op = parked(status: "approved", params: { "grant_id" => grant.id, "device_id" => device.id })

      migration.up

      expect(op.reload.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
    end

    # The whole point: the rewritten row must actually run. A repair that swaps
    # the class but leaves params the new executor cannot satisfy has moved the
    # crash, not removed it.
    it "produces a row that revokes the ONE device and leaves the grant alone" do
      op = parked(status: "pending", params: { "grant_id" => grant.id, "device_id" => device.id })
      sibling = create(:sdwan_user_device, access_grant: grant)

      migration.up
      op.reload.execute_now!

      expect(device.reload).to be_revoked
      expect(sibling.reload).not_to be_revoked, "the grant-wide cascade still happened"
      expect(grant.reload.status).to eq("active"), "a device revoke took out the whole grant"
    end
  end

  describe "rows it must not touch" do
    it "leaves a legitimate grant-scoped revoke alone" do
      op = parked(status: "pending", params: { "grant_id" => grant.id, "reason" => "offboarded" })

      migration.up

      expect(op.reload.executor_class).to eq("Sdwan::Executors::RevokeAccessGrant")
      expect(op.action_category).to eq("sdwan.access_grant_revoke")
    end

    %w[completed failed rejected expired].each do |terminal|
      it "leaves a #{terminal} row alone — it is history, not pending work" do
        op = parked(status: terminal, params: { "grant_id" => grant.id, "device_id" => device.id })

        migration.up

        expect(op.reload.executor_class).to eq("Sdwan::Executors::RevokeAccessGrant")
        expect(op.status).to eq(terminal)
      end
    end
  end

  # A row with no grant_id cannot satisfy RevokeUserDevice#scoped_device, which
  # anchors on the grant. Rewriting it would swap ArgumentError for
  # RecordNotFound — a different crash, not a fix.
  describe "rows that cannot be repaired" do
    it "fails them with a reason instead of rewriting them into a second crash" do
      op = parked(status: "pending", params: { "device_id" => device.id })

      migration.up

      expect(op.reload.status).to eq("failed")
      expect(op.executor_class).to eq("Sdwan::Executors::RevokeAccessGrant"),
                                   "an unrepairable row must not be repointed"
      expect(op.error_message).to match(/grant_id/)
      expect(op.error_message).to match(/IMP-086a88d44424/)
    end
  end

  it "is idempotent — a second run changes nothing" do
    op = parked(status: "pending", params: { "grant_id" => grant.id, "device_id" => device.id })
    migration.up
    first = op.reload.updated_at

    migration.up

    expect(op.reload.updated_at).to eq(first)
    expect(op.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
  end
end
