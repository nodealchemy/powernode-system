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
end
