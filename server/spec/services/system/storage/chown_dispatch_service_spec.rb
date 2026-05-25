# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::System::Storage::ChownDispatchService, type: :service do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, account: account) }

  before do
    ::System::ModuleUserDeclaration.delete_all
    ::System::ServiceUserGroupMembership.delete_all
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
    ::System::Task.where(account: account).delete_all
  end

  # Build a StorageAssignment seeded with a known service_user and
  # pre-populated chown_previous_* values, simulating the post-callback
  # state right after an owner change (just before dispatch fires).
  def make_assignment(storage:, mount_path: "/var/lib/postgresql", username: "postgres")
    user = ::System::Identity::UserAllocator.allocate!(username: username)
    a = ::System::StorageAssignment.create!(
      account:           account,
      node_instance:     instance,
      file_storage_id:   storage.id,
      mount_path:        mount_path,
      status:            "pending",
      encryption_mode:   "none",
      enabled:           true,
      owner_kind:        "service_user",
      service_user_id:   user.id,
      chown_state:       "complete"
    )
    a.update_columns(chown_state: "pending", chown_previous_uid: 100, chown_previous_gid: 100)
    a
  end

  describe ".dispatch!" do
    context "for object storage providers" do
      [ %i[s3 s3], %i[gcs gcs], %i[azure azure] ].each do |(trait, ptype)|
        it "marks chown_state=complete immediately for provider_type=#{ptype}" do
          storage = create(:file_storage, :node_mountable, trait, account: account)
          a = make_assignment(storage: storage, mount_path: "/data/#{ptype}")
          described_class.dispatch!(a)
          expect(a.reload.chown_state).to eq("complete")
          expect(a.chown_previous_uid).to be_nil
        end
      end
    end

    context "for local storage" do
      it "creates a System::Task targeting the consuming instance" do
        # `local` is a valid FileManagement::Storage provider_type AND
        # falls through to LOCAL_BLOCK_PROVIDERS in ChownDispatchService.
        storage = create(:file_storage, :node_mountable, account: account, provider_type: "local")
        a = make_assignment(storage: storage)
        described_class.dispatch!(a)
        task = ::System::Task.find_by(command: "storage.chown")
        expect(task).to be_present
        expect(task.operable).to eq(instance)
        expect(a.reload.chown_state).to eq("running")
        expect(a.chown_task_id).to eq(task.id)
      end
    end

    context "for NFS storage with no platform-managed provider node" do
      it "marks manual_required when configuration lacks export_host_node_instance_id" do
        # :nfs trait provides server_address/share_path; no
        # export_host_node_instance_id key, so external_provider? -> true.
        storage = create(:file_storage, :node_mountable, :nfs, account: account)
        a = make_assignment(storage: storage)
        described_class.dispatch!(a)
        expect(a.reload.chown_state).to eq("manual_required")
        expect(a.chown_last_error).to include("external/unmanaged provider")
      end
    end

    context "for NFS storage with a platform-managed provider node" do
      it "creates a System::Task targeting the provider (export host) instance" do
        provider_instance = create(:system_node_instance, account: account)
        storage = create(:file_storage, :node_mountable, :nfs, account: account)
        # Inject our export_host_node_instance_id into the existing
        # :nfs trait config (which already has mount_path + server_address).
        cfg = storage.configuration.merge("export_host_node_instance_id" => provider_instance.id)
        storage.update_columns(configuration: cfg)

        a = make_assignment(storage: storage)
        described_class.dispatch!(a)
        task = ::System::Task.find_by(command: "storage.chown")
        expect(task).to be_present
        expect(task.operable).to eq(provider_instance)
      end
    end

    context "idempotency" do
      it "is a no-op when chown_state is already running" do
        storage = create(:file_storage, :node_mountable, account: account, provider_type: "local")
        a = make_assignment(storage: storage)
        described_class.dispatch!(a)
        expect(::System::Task.where(command: "storage.chown").count).to eq(1)

        described_class.dispatch!(a)
        expect(::System::Task.where(command: "storage.chown").count).to eq(1)
      end
    end

    context "task payload" do
      it "includes mount_path, old/new UID and GID, and callback path" do
        storage = create(:file_storage, :node_mountable, account: account, provider_type: "local")
        a = make_assignment(storage: storage)
        described_class.dispatch!(a)
        task = ::System::Task.find_by(command: "storage.chown")
        payload = task.options
        expect(payload["storage_assignment_id"]).to eq(a.id)
        expect(payload["mount_path"]).to eq(a.mount_path)
        expect(payload["old_uid"]).to eq(100)
        expect(payload["new_uid"]).to eq(70_110)
        expect(payload["callback_path"]).to eq("/api/v1/system/worker_api/storage/chown_complete")
      end
    end
  end
end
