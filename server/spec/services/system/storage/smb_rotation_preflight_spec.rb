# frozen_string_literal: true

require "rails_helper"

# IMP-04ce3762270f — read-only preflight for the SMB credential rotation that
# remediates IMP-ab6e4075a007. Two preconditions, neither reported anywhere
# else: every SMB backend's agent can resolve the CredentialRef payload a
# rotation dispatches, and no SMB backend serves more than one account.
RSpec.describe System::Storage::SmbRotationPreflight do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  def backend(version:, heartbeat: 30.seconds.ago, owner: account)
    create(:system_node_instance, account: owner).tap do |instance|
      instance.update_columns(agent_version: version, last_heartbeat_at: heartbeat)
    end
  end

  def smb_storage(instance_id:, owner: account, **attrs)
    create(:file_storage, :smb, :node_mountable, account: owner,
      configuration: {
        "mount_path" => "/mnt/test",
        "server_address" => "192.0.2.10",
        "share_name" => "storage",
        "username" => "configured-user",
        "export_host_node_instance_id" => instance_id
      }.compact, **attrs)
  end

  def gateway_storage(instance_id:, owner: account)
    create(:file_storage, :gateway_proxy, account: owner, provider_type: "smb",
      configuration: {
        "mount_path" => "/mnt/gateway",
        "gateway_node_instance_id" => instance_id,
        "upstream_source_host" => "192.0.2.20",
        "upstream_export_path" => "/srv/data",
        "re_export_path" => "/var/lib/powernode/storage/test",
        "re_share_name" => "reshare"
      })
  end

  def row_for(report, instance)
    report.nodes.find { |row| row.instance_id == instance.id }
  end

  subject(:report) { described_class.call }

  describe "agent version check" do
    it "passes an agent stamped with a build date after the CredentialRef commit, and says the basis is the build date" do
      instance = backend(version: "2026-09-25-0123456789ab")
      smb_storage(instance_id: instance.id)

      row = row_for(report, instance)
      expect(row.agent_check.status).to eq("pass")
      expect(row.agent_check.basis).to eq("build_date")
      expect(report.verdict).to eq("safe_to_rotate")
      expect(report.safe_to_rotate?).to be(true)
    end

    it "passes an agent built on the commit's own day only when it is that exact commit" do
      exact = backend(version: "2026-09-19-c9eb9e725c07")
      smb_storage(instance_id: exact.id)

      row = row_for(report, exact)
      expect(row.agent_check.status).to eq("pass")
      expect(row.agent_check.basis).to eq("exact_commit")
    end

    it "reads UNKNOWN for a same-day build of any other commit" do
      same_day = backend(version: "2026-09-19-0123456789ab")
      smb_storage(instance_id: same_day.id)

      row = row_for(report, same_day)
      expect(row.agent_check.status).to eq("unknown")
      expect(row.agent_check.reason).to eq("built_same_day_as_credential_ref_commit")
      expect(report.verdict).to eq("unknown")
      expect(report.safe_to_rotate?).to be(false)
    end

    it "fails an agent built after payload validation but before the CredentialRef commit" do
      instance = backend(version: "2026-09-10-0123456789ab")
      smb_storage(instance_id: instance.id)

      row = row_for(report, instance)
      expect(row.agent_check.status).to eq("fail")
      expect(row.agent_check.reason).to eq("predates_credential_ref")
      expect(report.verdict).to eq("not_safe")
    end

    it "fails an agent built before payload validation with the more serious reason" do
      instance = backend(version: "2026-08-25-0123456789ab")
      smb_storage(instance_id: instance.id)

      expect(row_for(report, instance).agent_check.reason).to eq("predates_payload_validation")
      expect(report.verdict).to eq("not_safe")
    end

    it "fails a build of the validation commit itself whatever date it was built on" do
      instance = backend(version: "2026-09-28-c0edfa8277a4")
      smb_storage(instance_id: instance.id)

      row = row_for(report, instance)
      expect(row.agent_check.status).to eq("fail")
      expect(row.agent_check.reason).to eq("predates_credential_ref")
    end

    [ "dev", "unknown", "", nil, "2026-09-25-unknown", "v1.2.3", "2026-13-45-0123456789ab" ].each do |version|
      it "reads UNKNOWN, never pass, for the unorderable version #{version.inspect}" do
        instance = backend(version: version)
        smb_storage(instance_id: instance.id)

        row = row_for(report, instance)
        expect(row.agent_check.status).to eq("unknown")
        expect(row.agent_check.reason).to eq("agent_version_not_orderable")
        expect(report.verdict).to eq("unknown")
      end
    end

    it "reads UNKNOWN for a build date in the future" do
      instance = backend(version: "#{(Date.current + 30).iso8601}-0123456789ab")
      smb_storage(instance_id: instance.id)

      expect(row_for(report, instance).agent_check.reason).to eq("build_date_in_future")
    end

    it "reads UNKNOWN when the heartbeat that reported a passing version is stale" do
      instance = backend(version: "2026-09-25-0123456789ab", heartbeat: 20.minutes.ago)
      smb_storage(instance_id: instance.id)

      row = row_for(report, instance)
      expect(row.agent_check.status).to eq("unknown")
      expect(row.agent_check.reason).to eq("stale_heartbeat")
      expect(report.verdict).to eq("unknown")
    end

    it "reads UNKNOWN when the instance has never heartbeated" do
      instance = backend(version: "2026-09-25-0123456789ab", heartbeat: nil)
      smb_storage(instance_id: instance.id)

      expect(row_for(report, instance).agent_check.reason).to eq("stale_heartbeat")
    end
  end

  describe "cross-account check" do
    it "fails a backend serving SMB storages of more than one account" do
      instance = backend(version: "2026-09-25-0123456789ab")
      smb_storage(instance_id: instance.id)
      smb_storage(instance_id: instance.id, owner: other_account)

      row = row_for(report, instance)
      expect(row.account_check.status).to eq("fail")
      expect(row.account_check.reason).to eq("serves_multiple_accounts")
      expect(row.accounts.map { |a| a[:id] }).to contain_exactly(account.id, other_account.id)
      expect(row.agent_check.status).to eq("pass")
      expect(report.verdict).to eq("not_safe")
    end

    it "fails a backend owned by a different account than the one storage it serves" do
      instance = backend(version: "2026-09-25-0123456789ab")
      smb_storage(instance_id: instance.id, owner: other_account)

      row = row_for(report, instance)
      expect(row.account_check.status).to eq("fail")
      expect(row.account_check.reason).to eq("instance_account_differs_from_storage_account")
    end

    it "passes a backend serving several storages of its own account, and lists them once" do
      instance = backend(version: "2026-09-25-0123456789ab")
      first = smb_storage(instance_id: instance.id)
      second = smb_storage(instance_id: instance.id)

      expect(report.nodes.size).to eq(1)
      row = row_for(report, instance)
      expect(row.account_check.status).to eq("pass")
      expect(row.storages.map { |s| s[:id] }).to contain_exactly(first.id, second.id)
    end

    it "treats a gateway_proxy storage's gateway as the backend, with the gateway role" do
      gateway = backend(version: "2026-09-25-0123456789ab")
      gateway_storage(instance_id: gateway.id)

      row = row_for(report, gateway)
      expect(row.roles).to eq([ "gateway" ])
      expect(row.status).to eq("pass")
    end

    it "ignores storages that are not SMB" do
      instance = backend(version: "dev")
      create(:file_storage, :gateway_proxy, account: account,
        configuration: {
          "mount_path" => "/mnt/gateway",
          "gateway_node_instance_id" => instance.id,
          "upstream_source_host" => "192.0.2.20",
          "upstream_export_path" => "/srv/data",
          "re_export_path" => "/var/lib/powernode/storage/test"
        })

      expect(report.nodes).to be_empty
      expect(report.verdict).to eq("no_smb_backends")
    end
  end

  describe "storages whose backend cannot be resolved" do
    it "fails a storage naming an instance that does not exist" do
      storage = smb_storage(instance_id: SecureRandom.uuid)

      expect(report.nodes).to be_empty
      expect(report.unresolved_storages.map { |s| s[:id] }).to eq([ storage.id ])
      expect(report.unresolved_storages.first).to include(status: "fail", reason: "backend_instance_not_found")
      expect(report.verdict).to eq("not_safe")
    end

    it "reads UNKNOWN for an SMB storage with no backend instance configured" do
      storage = smb_storage(instance_id: nil)

      expect(report.unresolved_storages.first).to include(
        id: storage.id, status: "unknown", reason: "no_backend_instance_configured"
      )
      expect(report.verdict).to eq("unknown")
    end
  end

  describe "overall verdict" do
    it "reports an empty fleet as no_smb_backends, which is not safe_to_rotate" do
      expect(report.nodes).to be_empty
      expect(report.verdict).to eq("no_smb_backends")
      expect(report.safe_to_rotate?).to be(false)
    end

    it "is not_safe when one node fails even though another is unknown and a third passes" do
      smb_storage(instance_id: backend(version: "2026-09-25-0123456789ab").id)
      smb_storage(instance_id: backend(version: "dev").id)
      smb_storage(instance_id: backend(version: "2026-08-25-0123456789ab").id)

      expect(report.verdict).to eq("not_safe")
      expect(report.summary).to include(nodes: 3, pass: 1, unknown: 1, fail: 1)
    end

    it "is safe_to_rotate only when every node passes both checks and nothing is unresolved" do
      smb_storage(instance_id: backend(version: "2026-09-25-0123456789ab").id)
      smb_storage(instance_id: backend(version: "2026-09-19-c9eb9e725c07").id)

      expect(report.verdict).to eq("safe_to_rotate")
      expect(report.summary).to include(nodes: 2, pass: 2, unknown: 0, fail: 0, unresolved_storages: 0)
    end
  end

  describe "output hygiene" do
    it "carries names and ids only — no storage configuration, credential, or secret reference" do
      instance = backend(version: "2026-09-25-0123456789ab")
      storage = smb_storage(instance_id: instance.id)
      assignment = create(:system_storage_assignment, account: account, file_storage_id: storage.id,
        node_instance: create(:system_node_instance, account: account), mount_path: "/mnt/test")
      credential = create(:system_storage_credential, storage_assignment: assignment,
        node_instance: assignment.node_instance, kind: "cifs_user_pass", status: "active")

      serialized = report.as_json.to_json

      expect(serialized).to include(storage.id, instance.id)
      expect(serialized).not_to include("configured-user")
      expect(serialized).not_to include(credential.id)
      expect(serialized).not_to match(/vault|password|secret|credential_id/i)
    end
  end

  describe "read-only guarantee" do
    def writes_during
      writes = []
      subscriber = lambda do |*, payload|
        sql = payload[:sql].to_s
        writes << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE)\b/i)
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      writes
    end

    before do
      smb_storage(instance_id: backend(version: "2026-09-25-0123456789ab").id)
      smb_storage(instance_id: backend(version: "2026-08-25-0123456789ab").id, owner: other_account)
      smb_storage(instance_id: SecureRandom.uuid)
    end

    it "issues no write statement" do
      expect(writes_during { described_class.call }).to eq([])
    end

    it "the write detector does fire on a real write" do
      expect(writes_during { create(:account) }).not_to be_empty
    end

    it "creates no task and changes no storage, instance, or credential row" do
      snapshot = lambda do
        {
          tasks: ::System::Task.count,
          credentials: ::System::StorageCredential.count,
          storages: ::FileManagement::Storage.order(:id).pluck(:id, :updated_at),
          instances: ::System::NodeInstance.order(:id).pluck(:id, :updated_at)
        }
      end

      expect { described_class.call }.not_to(change { snapshot.call })
    end

    it "never reaches the rotation or dispatch path" do
      expect(::System::Storage::SmbUserManager).not_to receive(:new)
      expect(::System::Storage::CredentialIssuer).not_to receive(:new)

      described_class.call
    end
  end

  describe "query shape" do
    it "does not issue more queries as backends and storages are added" do
      count_queries = lambda do
        n = 0
        counter = lambda do |*, payload|
          n += 1 unless payload[:name].to_s == "SCHEMA" || payload[:sql].to_s.match?(/\A\s*(SAVEPOINT|RELEASE|BEGIN|COMMIT)/i)
        end
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.call }
        n
      end

      smb_storage(instance_id: backend(version: "2026-09-25-0123456789ab").id)
      baseline = count_queries.call

      3.times { smb_storage(instance_id: backend(version: "2026-09-25-0123456789ab").id, owner: create(:account)) }

      expect(count_queries.call).to eq(baseline)
    end
  end
end
