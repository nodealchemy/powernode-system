# frozen_string_literal: true

require "rails_helper"

# Account#destroy! with the system extension loaded: control-plane metadata goes
# with the account, a user who merely created a shared row does not block the
# teardown, and live fleet rows refuse it BEFORE any side effect.
RSpec.describe "System extension account teardown" do
  it "registers its environment-fleet teardown guard" do
    expect(Account.teardown_guards).to include(:system_environment_fleet)
  end

  # These examples create their rows and assert on them: a missing factory is a LOUD
  # failure (FactoryBot::KeyError), never a skip, and each asserts the rows existed first.
  it "removes system rows owned by the account and unlinks a shared row's creator" do
    account = create(:account)
    user = create(:user, account: account)
    repo = create(:system_package_repository, account: account)
    version = create(:system_node_module_version, created_by: user)
    expect(System::PackageRepository.exists?(repo.id)).to be true
    expect(System::NodeModuleVersion.find(version.id).created_by_id).to eq(user.id)

    expect { account.destroy! }.not_to raise_error

    expect(System::PackageRepository.exists?(repo.id)).to be false
    expect(System::NodeModuleVersion.find(version.id).created_by_id).to be_nil
  end

  it "records a platform-scoped audit trail for the signing keys it destroys" do
    account = create(:account)
    create(:user, account: account)
    pub = Base64.strict_encode64(SecureRandom.random_bytes(32))
    peer_key = System::PeerCapabilitySigningKey.create!(account: account, handle: "acct-teardown-p", public_key_b64: pub)
    constellation_key = Sdwan::ConstellationSigningKey.create!(account: account, handle: "acct-teardown-c", public_key_b64: pub)
    expect(account.system_peer_capability_signing_keys.count).to eq(1)

    account.destroy!

    expect(System::PeerCapabilitySigningKey.exists?(peer_key.id)).to be false
    revoked = AuditLog.where(account_id: nil, action: "account.teardown_key_revoked")
    expect(revoked.pluck(:resource_type, :resource_id)).to include(
      [ "System::PeerCapabilitySigningKey", peer_key.id ], [ "Sdwan::ConstellationSigningKey", constellation_key.id ]
    )
    destroyed = AuditLog.where(account_id: nil, action: "account.destroyed").last
    expect(destroyed.metadata["revoked_records"].map { |e| e["model"] }).to include(
      "System::PeerCapabilitySigningKey", "Sdwan::ConstellationSigningKey"
    )
  end

  it "removes a disk image webhook owned by the account together with the account" do
    account = create(:account)
    create(:user, account: account)
    webhook = create(:system_disk_image_webhook, account: account)

    expect { account.destroy! }.not_to raise_error

    expect(System::DiskImageWebhook.exists?(webhook.id)).to be false
  end

  it "refuses to destroy an account whose environment still holds fleet rows, changing nothing" do
    account = create(:account)
    agent_user = create(:user, account: account)
    node = create(:system_node, account: account)

    expect(account.destroy).to be false
    expect(account.errors[:base]).not_to be_empty
    expect(Account.exists?(account.id)).to be true
    expect(User.exists?(agent_user.id)).to be true
    expect(System::Node.exists?(node.id)).to be true
  end

  it "refuses (changing nothing) while a shared package repository was created by one of its users" do
    account = create(:account)
    user = create(:user, account: account)
    repo = create(:system_package_repository, account: nil, created_by: user, visibility: "shared")

    expect(account.destroy).to be false
    expect(account.errors[:base].join).to match(/shared system package repositories .*created_by_id.*reassign/i)
    expect(User.exists?(user.id)).to be true

    repo.update_columns(created_by_id: create(:user, account: create(:account)).id)
    expect { account.destroy! }.not_to raise_error
    expect(System::PackageRepository.exists?(repo.id)).to be true
  end

  it "refuses while the account's package repositories still have module links" do
    account = create(:account)
    repo = create(:system_package_repository, account: account)
    allow(System::PackageModuleLink).to receive(:where).and_call_original
    allow(System::PackageModuleLink).to receive(:where).with(package_repository_id: anything)
                                                       .and_return(instance_double(ActiveRecord::Relation, exists?: true))

    expect(account.destroy).to be false
    expect(account.errors[:base]).to include("Cannot delete account with package repositories that still have module links")
    expect(System::PackageRepository.exists?(repo.id)).to be true
  end

  it "unlinks a node instance ops hold from a user instead of blocking the user's removal" do
    account = create(:account)
    user = create(:user, account: account)
    instance = create(:system_node_instance, account: account)
    instance.update_columns(ops_hold_by_id: user.id, ops_hold_at: Time.current)
    expect(System::NodeInstance.find(instance.id).ops_hold_by_id).to eq(user.id)
    expect(User.reflect_on_association(:system_ops_held_node_instances).options[:dependent]).to eq(:nullify)

    expect { user.destroy! }.not_to raise_error

    expect(System::NodeInstance.find(instance.id).ops_hold_by_id).to be_nil
  end

  it "registers its key-operation audit actions and its key sources with the core teardown" do
    expect(AuditActions.key_operation?(Sdwan::PeerKeyRotationService::AUDIT_ACTION)).to be true
    expect(AuditActions.key_operation?("system.internal_ca.revoke")).to be true
    expect(AccountTeardownAudit.key_sources.keys).to include(
      :system_peer_capability_signing_keys, :system_sdwan_constellation_signing_keys,
      :system_sdwan_membership_credentials, :system_provider_credentials
    )
  end
end
