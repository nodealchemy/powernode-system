# frozen_string_literal: true

# IMP-d4fc286b7ccf — record WHO approved a fulfillment request.
#
# System::FulfillmentRequest's model doc calls the composed → approved
# transition "the single audited decision", and the migration that created the
# table says every run is "auditable". Neither was true: `approved_at` recorded
# WHEN the frozen plan was released to execute, but nothing anywhere recorded
# WHICH operator released it — and the fulfillment subsystem writes no AuditLog
# and emitted no FleetEvent, so the approver was unrecoverable after the fact.
# For the one human gate in a flow that provisions billable cloud instances,
# that is the single most important fact to keep.
#
# Plain uuid (not t.references) mirroring the existing requested_by_user_id on
# this table: the row is a durable accounting record that must survive the user
# being deleted, so no FK. Nullable — rows approved before this migration, and
# the autonomous `approved: true` executor path (which has no operator), both
# legitimately have no approver.
class AddApprovedByToSystemFulfillmentRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :system_fulfillment_requests, :approved_by_user_id, :uuid
    add_index :system_fulfillment_requests, :approved_by_user_id
  end
end
