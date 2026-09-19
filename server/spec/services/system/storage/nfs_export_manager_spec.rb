# frozen_string_literal: true

require "rails_helper"

# IMP-ba7956c5b38d — #grant!/#revoke! used to dispatch a storage.exports.apply
# task carrying ONLY the one credential/peer they were called with
# (TaskPayloadBuilder#build_exports_apply_payload, now removed). The agent's
# ApplyExports (agent/internal/storage/exports.go) OVERWRITES the whole
# per-storage exports file with whatever entries a task carries, so a grant
# left every OTHER client unexported, and a revoke left ONLY the revoked
# peer exported. Every test below uses a storage with 2+ clients so a
# single-entry regression would be caught, not hidden by a 1-client fixture.
RSpec.describe System::Storage::NfsExportManager do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/test",
        "mount_path" => "/srv/exports/test",
        "share_path" => "/srv/exports/test",
        "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => backend_instance.id
      })
  end

  def exports_tasks
    ::System::Task.where(command: "storage.exports.apply").order(:created_at)
  end

  def enrolled_assignment(mount_path:)
    instance = create(:system_node_instance, account: account)
    ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
    assignment = create(:system_storage_assignment,
      account: account, file_storage_id: file_storage.id, node_instance: instance,
      sdwan_network: network, mount_path: mount_path)
    # StorageAssignment#after_commit auto-issues its OWN credential (via
    # AssignmentReconciliationService#ensure_credential!) the moment the
    # row is created — revoke it immediately (bulk, no callbacks needed)
    # so each test's own explicit #issue! call below is the ONLY live
    # credential for this assignment. Same fixture gotcha
    # credential_issuer_spec.rb's own SMB tests already document and work
    # around for the identical reason.
    assignment.storage_credentials.update_all(status: "revoked")
    assignment
  end

  def issue(assignment)
    ::System::Storage::CredentialIssuer.new(assignment: assignment).issue!
  end

  def peer_ips_of(task)
    task.options["entries"].map { |e| e["peer_ip"] }
  end

  describe "#grant!" do
    it "includes every OTHER already-exported client's peer, not just the newly granted one" do
      assignment_a = enrolled_assignment(mount_path: "/mnt/a")
      credential_a = issue(assignment_a)

      assignment_b = enrolled_assignment(mount_path: "/mnt/b")
      before_ids = exports_tasks.pluck(:id)
      credential_b = issue(assignment_b)

      task = exports_tasks.where.not(id: before_ids).last
      expect(peer_ips_of(task)).to contain_exactly(
        credential_a.metadata["peer_ip"], credential_b.metadata["peer_ip"]
      )
    end

    it "does nothing for a non-NFS storage" do
      smb_storage = create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-test", "server_address" => "192.168.1.200",
          "share_name" => "storage", "export_host_node_instance_id" => backend_instance.id
        })
      assignment = create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: create(:system_node_instance, account: account))
      manager = described_class.new(assignment: assignment)

      before_count = exports_tasks.count
      manager.grant!(credential: instance_double(System::StorageCredential))
      expect(exports_tasks.count).to eq(before_count)
    end
  end

  describe "#revoke!" do
    # #revoke! only rebuilds correctly once the given credential's own
    # status is no longer "issued"/"active" (StorageAssignment#active_credential's
    # filter) — its ONLY real caller, CredentialIssuer#revoke!, updates that
    # status BEFORE calling here (see that method's own ordering comment).
    # Calling #revoke! directly without that precondition is not how this
    # is ever actually used in production — these specs go through
    # CredentialIssuer#revoke!, the real path, exactly like #grant!'s specs
    # above go through CredentialIssuer#issue!. The ordering itself is
    # covered separately in credential_issuer_spec.rb.
    def revoke(credential)
      ::System::Storage::CredentialIssuer.new(assignment: credential.storage_assignment).revoke!(credential)
    end

    it "removes only the revoked peer, keeping every other client exported" do
      assignment_a = enrolled_assignment(mount_path: "/mnt/a")
      credential_a = issue(assignment_a)
      assignment_b = enrolled_assignment(mount_path: "/mnt/b")
      credential_b = issue(assignment_b)

      before_ids = exports_tasks.pluck(:id)
      revoke(credential_a)

      task = exports_tasks.where.not(id: before_ids).last
      peer_ips = peer_ips_of(task)
      expect(peer_ips).not_to include(credential_a.metadata["peer_ip"])
      expect(peer_ips).to include(credential_b.metadata["peer_ip"])
    end

    it "uses action revoke on the dispatched task" do
      assignment_a = enrolled_assignment(mount_path: "/mnt/a")
      credential_a = issue(assignment_a)
      assignment_b = enrolled_assignment(mount_path: "/mnt/b")
      issue(assignment_b)

      before_ids = exports_tasks.pluck(:id)
      revoke(credential_a)

      task = exports_tasks.where.not(id: before_ids).last
      expect(task.options["action"]).to eq("revoke")
    end

    # IMP-ba7956c5b38d — the agent only removes the exports file (instead of
    # writing an empty one) when action == "revoke" AND entries is empty
    # (agent/internal/storage/exports.go). #reconcile! must produce exactly
    # that shape when the LAST client is revoked.
    it "revoking the only/last client produces an empty rebuild (entries: []) with action revoke" do
      assignment_a = enrolled_assignment(mount_path: "/mnt/only")
      credential_a = issue(assignment_a)

      before_ids = exports_tasks.pluck(:id)
      revoke(credential_a)

      task = exports_tasks.where.not(id: before_ids).last
      expect(task.options["entries"]).to eq([])
      expect(task.options["action"]).to eq("revoke")
    end

    it "does nothing for a non-NFS storage" do
      smb_storage = create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-test2", "server_address" => "192.168.1.201",
          "share_name" => "storage2", "export_host_node_instance_id" => backend_instance.id
        })
      assignment = create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: create(:system_node_instance, account: account))
      manager = described_class.new(assignment: assignment)

      before_count = exports_tasks.count
      manager.revoke!(credential: instance_double(System::StorageCredential))
      expect(exports_tasks.count).to eq(before_count)
    end
  end

  describe ".reconcile! (class method / drift-recovery path, unchanged)" do
    it "rebuilds from every live, enabled assignment's active credential" do
      assignment_a = enrolled_assignment(mount_path: "/mnt/a")
      credential_a = issue(assignment_a)
      assignment_b = enrolled_assignment(mount_path: "/mnt/b")
      credential_b = issue(assignment_b)

      before_ids = exports_tasks.pluck(:id)
      described_class.reconcile!(storage: file_storage)

      task = exports_tasks.where.not(id: before_ids).last
      expect(peer_ips_of(task)).to contain_exactly(
        credential_a.metadata["peer_ip"], credential_b.metadata["peer_ip"]
      )
      expect(task.options["action"]).to eq("revoke")
    end

    # IMP-ba7956c5b38d review round — a single partially-provisioned row
    # (peer enrollment failed after the credential row was created, or any
    # other path that leaves peer_ip blank) must not fail the WHOLE
    # storage's rebuild: the agent's ApplyExports validation rejects a
    # nil/non-address peer_ip outright, so one bad row would previously have
    # cut off every OTHER client on this storage too.
    it "skips an enabled assignment whose active credential has no peer_ip, logging at WARN, and still exports the other client" do
      # Stubbed to mirror metadata so this test can control "no peer_ip"
      # purely through the metadata column, without touching real Vault.
      allow_any_instance_of(System::StorageCredential)
        .to receive(:vault_credentials) { |instance| instance.metadata.slice("peer_ip") }

      assignment_a = enrolled_assignment(mount_path: "/mnt/good")
      credential_a = issue(assignment_a)

      assignment_b = enrolled_assignment(mount_path: "/mnt/peerless")
      credential_b = issue(assignment_b)
      credential_b.update_columns(metadata: credential_b.metadata.merge("peer_ip" => nil))

      warnings = []
      allow(Rails.logger).to receive(:warn) { |msg| warnings << msg }

      before_ids = exports_tasks.pluck(:id)
      described_class.reconcile!(storage: file_storage)

      task = exports_tasks.where.not(id: before_ids).last
      expect(peer_ips_of(task)).to contain_exactly(credential_a.metadata["peer_ip"])
      expect(warnings.any? { |w| w.include?(assignment_b.id) && w.include?(credential_b.id) }).to be true
    end
  end
end
