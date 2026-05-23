# frozen_string_literal: true

require "rails_helper"

# Focused on the new ownership + chown lifecycle behavior added by the
# storage-assignment owner refactor. Complements the existing
# storage_assignment_spec.rb (which covers status, encryption, mount).
RSpec.describe ::System::StorageAssignment, "owner + chown lifecycle", type: :model do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, account: account) }
  let(:storage)  { create(:file_storage, :node_mountable, account: account) }

  before do
    ::System::ModuleUserDeclaration.delete_all
    ::System::ServiceUserGroupMembership.delete_all
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
  end

  # Helper: build a valid StorageAssignment with a service_user owner.
  def build_assignment(owner_kind: "service_user", username: "postgres", **overrides)
    user = nil
    if owner_kind == "service_user"
      user = ::System::Identity::UserAllocator.allocate!(username: username)
    end
    ::System::StorageAssignment.new({
      account:           account,
      node_instance:     instance,
      file_storage_id:   storage.id,
      mount_path:        "/var/lib/#{username}",
      status:            "pending",
      encryption_mode:   "none",
      enabled:           true,
      owner_kind:        owner_kind,
      service_user_id:   user&.id,
      chown_state:       "complete"
    }.merge(overrides))
  end

  describe "#anonuid" do
    it "returns the service_user's UID for owner_kind=service_user" do
      a = build_assignment(username: "postgres")
      a.save!
      expect(a.anonuid).to eq(70_110)  # ReservedIdentities slot for postgres
    end

    it "returns 1000 for owner_kind=operator" do
      a = build_assignment(owner_kind: "operator", mount_path: "/home/operator/work")
      a.save!
      expect(a.anonuid).to eq(1_000)
    end

    it "returns 65534 for owner_kind=nobody" do
      a = build_assignment(owner_kind: "nobody", mount_path: "/tmp/cache")
      a.save!
      expect(a.anonuid).to eq(65_534)
    end

    it "returns 0 for owner_kind=root" do
      a = build_assignment(owner_kind: "root", mount_path: "/etc/secrets")
      a.save!
      expect(a.anonuid).to eq(0)
    end
  end

  describe "#anongid" do
    it "returns the owner's primary group GID by default" do
      a = build_assignment(username: "redis")
      a.save!
      expect(a.anongid).to eq(70_140)  # primary group auto-allocated at same slot
    end

    it "returns shared_group.gid when shared_group_id is set" do
      group = ::System::Identity::GroupAllocator.allocate!(groupname: "ssl-cert")
      a = build_assignment(username: "postgres", shared_group_id: group.id)
      a.save!
      expect(a.anongid).to eq(group.gid)
      expect(a.anongid).not_to eq(70_110)  # not postgres's primary anymore
    end

    it "returns 1000 for owner_kind=operator with no shared_group" do
      a = build_assignment(owner_kind: "operator", mount_path: "/home/operator")
      a.save!
      expect(a.anongid).to eq(1_000)
    end
  end

  describe "validations" do
    it "rejects service_user_id absent when owner_kind=service_user" do
      a = build_assignment
      a.service_user_id = nil
      expect(a).not_to be_valid
      expect(a.errors[:service_user].join).to include("can't be blank").or include("blank")
    end

    it "rejects service_user_id present when owner_kind=operator" do
      user = ::System::Identity::UserAllocator.allocate!(username: "myapp")
      a = build_assignment(owner_kind: "operator",
                           mount_path: "/home/operator/x",
                           service_user_id: user.id)
      expect(a).not_to be_valid
      expect(a.errors[:service_user_id].join).to include("must be blank")
    end

    it "rejects unknown owner_kind" do
      a = build_assignment
      a.owner_kind = "alien"
      expect(a).not_to be_valid
      expect(a.errors[:owner_kind].join).to include("included")
    end
  end

  describe "chown lifecycle on owner change" do
    let!(:a) { build_assignment(username: "postgres").tap(&:save!) }

    it "captures previous UID/GID and transitions to pending when owner changes" do
      new_user = ::System::Identity::UserAllocator.allocate!(username: "mysql")
      # Stub the dispatch so we just inspect the model state transition.
      allow(::System::Storage::ChownDispatchService).to receive(:dispatch!)

      a.update!(service_user_id: new_user.id)

      expect(a.reload.chown_previous_uid).to eq(70_110)  # postgres's old UID
      expect(a.chown_previous_gid).to eq(70_110)
      expect(a.chown_state).to eq("pending")
      expect(::System::Storage::ChownDispatchService).to have_received(:dispatch!).with(a)
    end

    it "preserves chown_previous_uid through repeated dispatch attempts during in-flight runs" do
      # Manually set in-flight state (as if dispatch happened)
      a.update_columns(chown_state: "running", chown_previous_uid: 70_110, chown_previous_gid: 70_110)
      mariadb = ::System::Identity::UserAllocator.allocate!(username: "mariadb")

      # Owner-change attempts while in-flight are rejected by validation,
      # so the previous_* fields are preserved.
      a.service_user_id = mariadb.id
      expect(a.save).to be false
      expect(a.errors[:base].join).to include("cannot change owner while previous chown is in flight")
    end

    it "uses effective_export_uid (chown_previous_uid) during in-flight chown" do
      a.update_columns(chown_state: "running",
                       chown_previous_uid: 70_110,
                       chown_previous_gid: 70_110,
                       service_user_id: ::System::Identity::UserAllocator.allocate!(username: "mysql").id)
      expect(a.reload.effective_export_uid).to eq(70_110)  # OLD
      expect(a.anonuid).to eq(70_120)                       # NEW (DB-effective)
    end

    it "effective_export_uid returns anonuid when chown is complete" do
      expect(a.effective_export_uid).to eq(a.anonuid)
    end
  end

  describe "predicates" do
    it "service_user_owner? is true only for owner_kind=service_user" do
      expect(build_assignment.service_user_owner?).to be true
      expect(build_assignment(owner_kind: "operator", mount_path: "/home/operator").service_user_owner?).to be false
    end

    it "chown_in_flight? returns true for pending and running" do
      a = build_assignment
      a.save!
      a.update_columns(chown_state: "pending")
      expect(a.reload.chown_in_flight?).to be true
      a.update_columns(chown_state: "running")
      expect(a.reload.chown_in_flight?).to be true
      a.update_columns(chown_state: "complete")
      expect(a.reload.chown_in_flight?).to be false
      a.update_columns(chown_state: "failed")
      expect(a.reload.chown_in_flight?).to be false
    end
  end
end
