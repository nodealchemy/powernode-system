# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260930090000_add_rotating_since_to_system_storage_credentials.rb"
)

# IMP-a366d6fb6b80 - the backfill's guarantee is that a credential ALREADY
# rotating when this ships is neither retired by the first sweep (which a
# stamp of its old updated_at would do) nor left without a clock. Called
# against the already-migrated schema, so it also proves `up` is safe to run
# on a database whose schema.rb already carries the column.
RSpec.describe AddRotatingSinceToSystemStorageCredentials do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/rot-since", "mount_path" => "/srv/exports/rot-since",
        "share_path" => "/srv/exports/rot-since", "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => create(:system_node_instance, account: account).id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment, account: account, node_instance: node_instance, file_storage_id: file_storage.id)
  end

  subject(:migration) { described_class.new }

  def run!
    migration.verbose = false
    migration.up
  end

  def credential(status:, rotating_since: nil, updated_at: Time.current)
    ::System::StorageCredential.create!(
      storage_assignment: assignment, node_instance: node_instance,
      kind: "cifs_user_pass", status: status, metadata: {}
    ).tap { |row| row.update_columns(rotating_since: rotating_since, updated_at: updated_at) }
  end

  it "stamps an already-rotating row with the migration time, not its stale updated_at" do
    legacy = credential(status: "rotating", updated_at: 40.days.ago)

    run!

    expect(legacy.reload.rotating_since).to be_within(1.minute).of(Time.current)
  end

  it "leaves rows that are not rotating without a clock" do
    active = credential(status: "active")
    revoked = credential(status: "revoked")

    run!

    expect(active.reload.rotating_since).to be_nil
    expect(revoked.reload.rotating_since).to be_nil
  end

  it "does not overwrite a clock that is already set" do
    stamped = credential(status: "rotating", rotating_since: 5.hours.ago)

    run!

    expect(stamped.reload.rotating_since).to be_within(1.minute).of(5.hours.ago)
  end

  it "gives a backfilled row a full window: the first sweep after deploy leaves it, and it is retired once the window has run" do
    legacy = credential(status: "rotating", updated_at: 40.days.ago)
    run!

    cutoff = Time.current - ::System::Storage::RotatingCredentialSweeper.window
    expect(::System::StorageCredential.rotating_overdue(cutoff)).not_to include(legacy)

    travel_to(25.hours.from_now) do
      later_cutoff = Time.current - ::System::Storage::RotatingCredentialSweeper.window
      expect(::System::StorageCredential.rotating_overdue(later_cutoff)).to include(legacy)
    end
  end
end
