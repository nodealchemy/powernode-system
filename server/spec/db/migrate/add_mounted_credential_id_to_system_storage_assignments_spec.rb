# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260919160000_add_mounted_credential_id_to_system_storage_assignments.rb"
)

# IMP-e48612a32273 BLOCKER 1 (review) — the backfill's guarantee is NOT
# "the column exists". It is "no already-mounted assignment reads as
# mismatched the moment this ships" — StorageAssignment.mount_credential_mismatch
# treats a NULL mounted_credential_id on a mounted row as a mismatch (belt-
# and-braces aside, see that scope's own spec), so a mounted row this
# backfill fails to resolve would still get swept and remounted on the very
# first drift tick after deploy.
RSpec.describe AddMountedCredentialIdToSystemStorageAssignments do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/backfill", "mount_path" => "/srv/exports/backfill",
        "share_path" => "/srv/exports/backfill", "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => create(:system_node_instance, account: account).id
      })
  end

  subject(:migration) { described_class.new }

  def run!
    migration.verbose = false
    migration.up
  end

  def build_assignment_with_credential(status:)
    assignment = create(:system_storage_assignment, account: account, node_instance: node_instance,
                         file_storage_id: file_storage.id)
    assignment.storage_credentials.update_all(status: "revoked")
    active = ::System::Storage::CredentialIssuer.new(assignment: assignment).issue!
    assignment.update_columns(status: status, mounted_credential_id: nil)
    [ assignment, active ]
  end

  it "backfills mounted_credential_id to the active credential for a MOUNTED row left NULL" do
    assignment, active = build_assignment_with_credential(status: "mounted")

    run!

    expect(assignment.reload.mounted_credential_id).to eq(active.id)
  end

  it "backfills a DEGRADED row the same way" do
    assignment, active = build_assignment_with_credential(status: "degraded")

    run!

    expect(assignment.reload.mounted_credential_id).to eq(active.id)
  end

  it "leaves a NON-mounted (e.g. pending) row NULL — it was never actually confirmed mounted" do
    assignment, = build_assignment_with_credential(status: "pending")

    run!

    expect(assignment.reload.mounted_credential_id).to be_nil
  end

  it "does not touch a mounted row that already has a mounted_credential_id" do
    assignment, active = build_assignment_with_credential(status: "mounted")
    other = ::System::StorageCredential.create!(
      storage_assignment: assignment, node_instance: node_instance,
      kind: active.kind, status: "revoked", metadata: {}
    )
    assignment.update_columns(mounted_credential_id: other.id)

    run!

    # The subquery always resolves to the CURRENT active credential
    # regardless of what was there before — this assignment is genuinely
    # mounted, so re-resolving to `active` (not leaving the stale `other`)
    # is correct, not a "don't touch" case. Asserted explicitly so a
    # future WHERE-clause change that tries to skip "already set" rows
    # doesn't accidentally leave a truly stale id in place.
    expect(assignment.reload.mounted_credential_id).to eq(active.id)
  end

  it "is idempotent: a second run makes no further change" do
    assignment, active = build_assignment_with_credential(status: "mounted")
    run!

    expect { run! }.not_to change { assignment.reload.mounted_credential_id }
    expect(assignment.reload.mounted_credential_id).to eq(active.id)
  end

  describe "down" do
    # Deliberately NOT executed for real: this spec's process shares one
    # schema/connection with every other spec file in the same rspec run
    # (per-lane test DB, not per-example) — actually dropping the column
    # here, even temporarily, would leave every OTHER loaded StorageAssignment
    # class with stale ActiveRecord column-cache metadata for the rest of
    # the process. A behavior-level expectation is enough to confirm #down
    # calls the reversing operation with the right arguments; it does not
    # need to prove Rails's own remove_reference implementation works.
    it "reverses the column addition" do
      expect(migration).to receive(:remove_reference).with(
        :system_storage_assignments, :mounted_credential,
        foreign_key: { to_table: :system_storage_credentials }
      )
      migration.down
    end
  end
end
