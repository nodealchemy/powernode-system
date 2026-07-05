# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Storage::AssignmentReconciliationService do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/test",
        "mount_path" => "/srv/exports/test",
        "share_path" => "/srv/exports/test",
        "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => create(:system_node_instance, account: account).id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment,
      account: account,
      file_storage_id: file_storage.id,
      node_instance: node_instance,
      mount_path: "/mnt/test")
  end

  describe "backoff escalation on repeated failures" do
    before do
      # Force every reconcile attempt to fail past the peer step so the
      # attempt/backoff bookkeeping in error_message can be observed in
      # isolation from the happy path.
      allow(System::Storage::CredentialIssuer).to receive(:new).and_raise(StandardError, "boom")
    end

    it "grows the backoff delay on the second failure instead of pinning it at BACKOFF_BASE" do
      assignment # materialize — the after_commit trigger fires the first (failing) reconcile
      assignment.reload
      expect(assignment.error_message).to match(/attempt:1 backoff_until:/)

      # Expire the stored backoff so a second trigger actually re-attempts the
      # work rather than short-circuiting on in_backoff?.
      assignment.update_columns(
        error_message: assignment.error_message.sub(/backoff_until:\S+/, "backoff_until:#{1.second.ago.iso8601}")
      )

      described_class.reconcile_assignment!(assignment)
      assignment.reload

      expect(assignment.error_message).to match(/attempt:2 backoff_until:/)
      second_delay = Time.parse(assignment.error_message[/backoff_until:(\S+)/, 1]) - Time.current
      expect(second_delay).to be > 45.seconds # BACKOFF_BASE * 2**1 = 60s — not pinned at 30s again
    end
  end

  describe "storage.mount dispatch dedupe" do
    it "does not spawn a second storage.mount task while one is already pending" do
      assignment # materialize — the after_commit trigger dispatches the first storage.mount task
      expect(System::Task.where(operable: node_instance, command: "storage.mount").count).to eq(1)

      described_class.reconcile_assignment!(assignment)

      expect(System::Task.where(operable: node_instance, command: "storage.mount").count).to eq(1)
    end
  end
end
