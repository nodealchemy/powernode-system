# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::StorageCredential, type: :model do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }
  let(:assignment) do
    create(:system_storage_assignment,
      account: account, file_storage_id: file_storage.id, node_instance: node_instance)
  end

  subject(:credential) do
    described_class.new(
      storage_assignment: assignment,
      node_instance: node_instance,
      kind: "peer_ip_acl",
      status: "issued",
      metadata: { peer_ip: "fd00::1" }
    )
  end

  it "is valid with peer_ip_acl kind" do
    expect(credential).to be_valid
  end

  it "rejects unknown kinds" do
    credential.kind = "bogus"
    expect(credential).not_to be_valid
  end

  it "rejects kerberos kind (SDWAN-as-trust-anchor, no KDC in v1)" do
    credential.kind = "kerberos"
    expect(credential).not_to be_valid
  end

  it "delegates account_id to the storage_assignment" do
    expect(credential.account_id).to eq(assignment.account_id)
  end

  describe "#expired?" do
    it "is false when expires_at is nil (no expiry — peer_ip_acl)" do
      credential.expires_at = nil
      expect(credential.expired?).to be false
    end

    it "is true once expires_at has passed" do
      credential.expires_at = 1.minute.ago
      expect(credential.expired?).to be true
    end
  end

  describe "#needs_rotation?" do
    it "is true within the rotation window" do
      credential.expires_at = 12.hours.from_now
      expect(credential.needs_rotation?).to be true
    end

    it "is false outside the rotation window" do
      credential.expires_at = 5.days.from_now
      expect(credential.needs_rotation?).to be false
    end
  end

  describe ".active scope" do
    before { credential.save! }

    it "includes issued + active" do
      expect(described_class.active).to include(credential)
      credential.update!(status: "active")
      expect(described_class.active).to include(credential)
    end

    it "excludes revoked + expired" do
      credential.update!(status: "revoked")
      expect(described_class.active).not_to include(credential)
    end
  end

  describe "vault credential type" do
    it "uses the 'storage_node_access' namespace" do
      expect(described_class.vault_credential_type).to eq("storage_node_access")
    end
  end
end
