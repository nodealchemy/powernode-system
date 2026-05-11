# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Storage::CredentialIssuer do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:node_instance) do
    instance = create(:system_node_instance, account: account)
    # PeerEnroller stamps a /128 on save, which the issuer reads as peer_ip.
    Sdwan::PeerEnroller.call(network: network, node_instance: instance)
    instance
  end
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
      sdwan_network: network,
      mount_path: "/mnt/test")
  end

  subject(:issuer) { described_class.new(assignment: assignment) }

  describe "#issue!" do
    it "creates a StorageCredential with peer_ip_acl kind for NFS" do
      credential = issuer.issue!
      expect(credential).to be_a(System::StorageCredential)
      expect(credential.kind).to eq("peer_ip_acl")
      expect(credential.status).to eq("active")
    end

    it "records peer_ip in the credential metadata" do
      credential = issuer.issue!
      expect(credential.metadata["peer_ip"]).to be_present
    end

    it "dispatches a storage.exports.apply task to the backend peer" do
      # The assignment's after_commit reconciler may have already fired one
      # exports task during setup; we just assert that an explicit issue! call
      # produces at least one more.
      before_count = System::Task.where(command: "storage.exports.apply").count
      issuer.issue!
      expect(System::Task.where(command: "storage.exports.apply").count).to be > before_count
    end

    it "raises if the storage is missing" do
      assignment.update_columns(file_storage_id: SecureRandom.uuid)
      assignment.instance_variable_set(:@file_storage, nil)
      expect { issuer.issue! }.to raise_error(described_class::IssuanceError)
    end
  end

  describe "#revoke!" do
    it "marks the credential revoked" do
      credential = issuer.issue!
      issuer.revoke!(credential)
      expect(credential.reload.status).to eq("revoked")
    end
  end
end
