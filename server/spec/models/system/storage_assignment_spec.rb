# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::StorageAssignment, type: :model do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }

  subject(:assignment) do
    build(
      :system_storage_assignment,
      account: account,
      file_storage_id: file_storage.id,
      node_instance: node_instance
    )
  end

  describe "validations" do
    it "is valid with the default factory" do
      expect(assignment).to be_valid
    end

    it "requires a file_storage_id" do
      assignment.file_storage_id = nil
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id]).to be_present
    end

    it "requires the referenced FileManagement::Storage to exist" do
      assignment.file_storage_id = SecureRandom.uuid
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id].join).to include("must reference an existing")
    end

    it "rejects a storage that isn't node_mount_capable" do
      file_storage.update!(node_mount_capable: false)
      assignment.instance_variable_set(:@file_storage, nil)
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id].join).to include("node_mount_capable")
    end

    it "requires mount_path to be an absolute path" do
      assignment.mount_path = "relative/path"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:mount_path].join).to include("absolute")
    end

    it "validates encryption_mode inclusion" do
      assignment.encryption_mode = "bogus"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode]).to be_present
    end

    it "rejects luks encryption for object-storage providers" do
      object_storage = create(:file_storage, :s3, :node_mountable, account: account)
      assignment.file_storage_id = object_storage.id
      assignment.instance_variable_set(:@file_storage, nil)
      assignment.encryption_mode = "luks"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode].join).to include("requires block storage")
    end

    it "rejects client_side_aes encryption for NFS providers" do
      assignment.encryption_mode = "client_side_aes"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode].join).to include("object storage")
    end
  end

  # Every account-owned row an assignment names belongs to the assignment's own
  # account (the Sdwan::PeerEnroller#verify_account_alignment! rule). The ref
  # columns carry no FK tying them to the account, and fleet events about an
  # assignment copy its node_instance_id into the typed column the
  # per-component signals filter reads, so a foreign instance here would put
  # another tenant's id into this account's events. Each ref on both arms.
  describe "account alignment" do
    let(:other_account) { create(:account) }

    it "refuses a node_instance from another account, naming the field" do
      assignment.node_instance = create(:system_node_instance, account: other_account)

      expect(assignment).not_to be_valid
      expect(assignment.errors[:node_instance].join).to include("must belong to this account")
    end

    it "saves when the node_instance is the assignment's own account's" do
      expect(assignment.save).to be(true)
      expect(assignment.errors[:node_instance]).to be_empty
    end

    it "refuses an sdwan_network from another account, and accepts its own" do
      assignment.sdwan_network = create(:sdwan_network, account: other_account)
      expect(assignment).not_to be_valid
      expect(assignment.errors[:sdwan_network].join).to include("must belong to this account")

      assignment.sdwan_network = create(:sdwan_network, account: account)
      expect(assignment).to be_valid
    end

    it "refuses an sdwan_virtual_ip from another account, and accepts its own" do
      foreign_network = create(:sdwan_network, account: other_account)
      assignment.sdwan_virtual_ip = create(:sdwan_virtual_ip, network: foreign_network)
      expect(assignment).not_to be_valid
      expect(assignment.errors[:sdwan_virtual_ip].join).to include("must belong to this account")

      assignment.sdwan_virtual_ip = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: account))
      expect(assignment).to be_valid
    end

    it "refuses re-pointing a saved assignment at another account's node_instance" do
      assignment.save!
      assignment.node_instance = create(:system_node_instance, account: other_account)

      expect(assignment.save).to be(false)
      expect(assignment.errors[:node_instance]).to be_present
    end

    # file_storage is a hand-written lookup, not a belongs_to, so it is scoped
    # to the account at the lookup itself: another account's storage never
    # resolves, and the refusal is the ordinary "must reference an existing"
    # error — the SAME one a made-up id gets, so it reveals nothing.
    it "refuses another account's file storage with the error a nonexistent storage gets" do
      assignment.file_storage_id = create(:file_storage, :nfs, :node_mountable, account: other_account).id
      expect(assignment).not_to be_valid
      foreign_error = assignment.errors[:file_storage_id].dup

      assignment.file_storage_id = SecureRandom.uuid
      assignment.valid?
      expect(foreign_error).to eq(assignment.errors[:file_storage_id])
      expect(foreign_error.join).to include("must reference an existing")
    end

    it "re-resolves file_storage when file_storage_id changes, rather than serving a stale lookup" do
      expect(assignment).to be_valid # resolves (and caches) the account's own storage
      assignment.file_storage_id = create(:file_storage, :nfs, :node_mountable, account: other_account).id

      expect(assignment.file_storage).to be_nil
      expect(assignment).not_to be_valid
    end

    it "never resolves another account's file storage from a row written around validation" do
      assignment.save!
      foreign = create(:file_storage, :nfs, :node_mountable, account: other_account)
      assignment.update_column(:file_storage_id, foreign.id)

      expect(described_class.find(assignment.id).file_storage).to be_nil
    end

    it "still resolves its own account's file storage (the other arm)" do
      assignment.save!
      expect(described_class.find(assignment.id).file_storage).to eq(file_storage)
    end

    # The factory used to give the assignment and its node_instance two
    # different accounts; with the rule in place its default must align.
    # CREATE, not build: a built factory row has unsaved associations, so both
    # account ids are nil and "nil == nil" would pass whatever the factory did.
    # The account is given (the storage is this account's, and a storage never
    # resolves across accounts); node_instance is NOT, so the factory's own
    # default is what is under test.
    it "creates a valid, account-aligned assignment from the factory's default node_instance" do
      bare = create(:system_storage_assignment, account: account, file_storage_id: file_storage.id)
      expect(bare).to be_persisted
      expect(bare.account_id).to be_present
      expect(bare.node_instance.account_id).to eq(bare.account_id)
    end
  end

  describe "#anonuid (replaces legacy #derived_uid)" do
    # 2026-05-22 fleet-wide identity refactor (4a62bc6f) replaced the
    # hashed-per-node_instance_id derived_uid with owner_kind-dispatched
    # anonuid: service_user → ServiceUser#uid (70k-100k), operator →
    # 1000, nobody → 65534, root → 0. The factory defaults owner_kind to
    # "nobody" (see system_factories), so the live UID is the well-known
    # NFS root-squash sentinel.
    it "is deterministic for the same node_instance_id" do
      assignment.save!
      first = assignment.anonuid
      assignment.reload
      expect(assignment.anonuid).to eq(first)
    end

    it "lands in the BASELINE_UIDS sentinel set for non-service_user owners" do
      assignment.save!
      # owner_kind = "nobody" → BASELINE_UIDS["nobody"] = 65534 (NFS root-squash).
      expect(assignment.anonuid).to eq(65_534)
    end
  end

  describe "#effective_encryption_mode" do
    it "returns the literal value when not 'inherit'" do
      assignment.encryption_mode = "none"
      expect(assignment.effective_encryption_mode).to eq("none")
    end

    # Audit 2026-06-09 F6-02: NFS/SMB no longer default to fscrypt. Kernel
    # fscrypt can't encrypt a network mount client-side, so the old default was
    # a silent-plaintext no-op. The honest default is "none" until a real
    # network-storage mechanism (client-side gocryptfs / server-side at-rest)
    # ships; operators set fscrypt explicitly for block-backed local targets.
    it "resolves 'inherit' to none for NFS (client-side fscrypt is inapplicable)" do
      assignment.encryption_mode = "inherit"
      expect(assignment.effective_encryption_mode).to eq("none")
    end

    it "resolves 'inherit' to client_side_aes for S3" do
      object_storage = create(:file_storage, :s3, :node_mountable, account: account)
      assignment.file_storage_id = object_storage.id
      assignment.instance_variable_set(:@file_storage, nil)
      assignment.encryption_mode = "inherit"
      expect(assignment.effective_encryption_mode).to eq("client_side_aes")
    end
  end

  describe "scopes" do
    # update_columns bypasses the after_commit :trigger_reconcile hook so we
    # can set deterministic statuses for scope assertions without the
    # reconciler bumping them to "failed" mid-test.
    let!(:pending_assignment) do
      a = create(:system_storage_assignment, account: account, file_storage_id: file_storage.id,
        node_instance: create(:system_node_instance, account: account))
      a.update_columns(status: "pending")
      a
    end
    let!(:mounted_assignment) do
      a = create(:system_storage_assignment, account: account, file_storage_id: file_storage.id,
        node_instance: create(:system_node_instance, account: account))
      a.update_columns(status: "mounted")
      a
    end

    it ".pending_reconcile only returns enabled non-mounted rows" do
      expect(described_class.pending_reconcile).to include(pending_assignment)
      expect(described_class.pending_reconcile).not_to include(mounted_assignment)
    end

    it ".mounted returns only mounted rows" do
      expect(described_class.mounted).to include(mounted_assignment)
      expect(described_class.mounted).not_to include(pending_assignment)
    end
  end

  # IMP-e48612a32273 — the drift-detection half of the remount fix. A
  # rotation never touches an ASSIGNMENT field, so pending_reconcile alone
  # (deliberately excluding "mounted") never re-admits a row whose consumer
  # never actually remounted; this scope is the safety net that does.
  describe ".mount_credential_mismatch" do
    let(:mounted_node_instance) { create(:system_node_instance, account: account) }
    let(:backend_instance) { create(:system_node_instance, account: account) }
    let(:file_storage) do
      create(:file_storage, :nfs, :node_mountable, account: account,
        configuration: {
          "export_path" => "/srv/exports/test", "mount_path" => "/srv/exports/test",
          "share_path" => "/srv/exports/test", "server_address" => "127.0.0.1",
          "export_host_node_instance_id" => backend_instance.id
        })
    end
    let(:mounted) do
      a = create(:system_storage_assignment,
        account: account, file_storage_id: file_storage.id, node_instance: mounted_node_instance)
      a.update_columns(status: "mounted")
      a
    end
    let!(:unmounted_assignment) do
      create(:system_storage_assignment,
        account: account, file_storage_id: file_storage.id, node_instance: create(:system_node_instance, account: account))
    end

    # StorageAssignment#after_commit auto-issues its OWN credential — clear
    # it so each test's own explicit #issue! is the only live credential.
    def clear_auto_issued!
      mounted.storage_credentials.update_all(status: "revoked")
    end

    # IMP-e48612a32273 BLOCKER 1 (review) — FLIPPED from "matches": NULL
    # means "never confirmed" (the migration's backfill legitimately
    # skipped it, or this is a genuinely new assignment whose first mount
    # hasn't completed yet), not "mismatch". Treating NULL as a mismatch
    # would have every already-mounted share in the fleet with an
    # unbackfilled row match on the first drift tick after deploy and get
    # remounted all at once.
    it "excludes a mounted assignment whose mounted_credential_id is nil, even while active_credential exists" do
      clear_auto_issued!
      System::Storage::CredentialIssuer.new(assignment: mounted).issue!
      mounted.update_columns(mounted_credential_id: nil)

      expect(described_class.mount_credential_mismatch).not_to include(mounted)
    end

    it "matches a mounted assignment whose mounted_credential_id points at a DIFFERENT (stale) credential" do
      clear_auto_issued!
      active = System::Storage::CredentialIssuer.new(assignment: mounted).issue!
      stale = create(:system_storage_credential,
        storage_assignment: mounted, node_instance: mounted_node_instance, kind: active.kind, status: "revoked")
      mounted.update_columns(mounted_credential_id: stale.id)

      expect(described_class.mount_credential_mismatch).to include(mounted)
    end

    it "excludes a mounted assignment whose mounted_credential_id matches its active_credential" do
      clear_auto_issued!
      active = System::Storage::CredentialIssuer.new(assignment: mounted).issue!
      mounted.update_columns(mounted_credential_id: active.id)

      expect(described_class.mount_credential_mismatch).not_to include(mounted)
    end

    it "excludes a non-mounted assignment even with a stale mounted_credential_id" do
      clear_auto_issued!
      stale = System::Storage::CredentialIssuer.new(assignment: mounted).issue!
      unmounted_assignment.update_columns(mounted_credential_id: stale.id)

      expect(described_class.mount_credential_mismatch).not_to include(unmounted_assignment)
    end
  end
end
