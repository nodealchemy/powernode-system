# frozen_string_literal: true

require "rails_helper"

# Account#destroy! with the system extension loaded: control-plane metadata goes
# with the account, a user who merely created a shared row does not block the
# teardown, and live fleet rows refuse it BEFORE any side effect.
RSpec.describe "System extension account teardown" do
  it "registers its environment-fleet teardown guard" do
    expect(Account.teardown_guards).to include(:system_environment_fleet)
  end

  it "removes system rows owned by the account and unlinks a shared row's creator" do
    account = create(:account)
    user = create(:user, account: account)
    log = create(:system_task_log, account: account) if FactoryBot.factories.registered?(:system_task_log)
    version = create(:system_node_module_version, created_by: user) if FactoryBot.factories.registered?(:system_node_module_version)
    skip "no system factories available" unless log || version

    expect { account.destroy! }.not_to raise_error

    expect(System::TaskLog.exists?(log.id)).to be false if log
    expect(System::NodeModuleVersion.find(version.id).created_by_id).to be_nil if version
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
    expect(User.reflect_on_association(:system_ops_held_node_instances).options[:dependent]).to eq(:nullify)
    expect { user.destroy! }.not_to raise_error
  end
end
