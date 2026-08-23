# frozen_string_literal: true

require "rails_helper"

# Sdwan::Executors::CreateUserDevice is the executor behind both device-issue
# surfaces (UserDevicesController#create, SdwanTool#issue_user_device). Its
# load-bearing contract: the write MUST go through Sdwan::UserDeviceIssuer —
# keypair minted, private half in Vault, address allocated, one-shot bootstrap
# token returned — because a bare `user_devices.create!` produces a row that
# satisfies no validation and can never connect. (That bare create! was this
# executor's original, never-called body — IMP-051f3811ac60.)
RSpec.describe Sdwan::Executors::CreateUserDevice, type: :model do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }

  it "issues through UserDeviceIssuer: keypair, address, and a verifiable one-shot token" do
    result = described_class.execute(
      { grant_id: grant.id, label: "work-laptop" },
      deferred_operation: nil
    )

    expect(result[:success]).to be(true)
    data = result[:data]

    device = grant.user_devices.reload.find(data[:device_id])
    expect(device.label).to eq("work-laptop")
    expect(device.public_key).to match(%r{\A[A-Za-z0-9+/]{43}=\z})
    expect(device.assigned_address).to be_present

    expect(data[:grant_id]).to eq(grant.id)
    expect(data[:expires_at]).to be_present
    expect(::Sdwan::UserDeviceIssuer.verify_bootstrap_token!(data[:bootstrap_token])[:device_id])
      .to eq(device.id)
  end

  it "raises GrantError for a non-active grant (re-enforced at approval time, not just pre-gate)" do
    grant.update!(status: "suspended")

    expect {
      described_class.execute({ grant_id: grant.id, label: "phone" }, deferred_operation: nil)
    }.to raise_error(::Sdwan::UserDeviceIssuer::GrantError, /not active/)

    expect(grant.user_devices.reload.count).to eq(0)
  end

  it "refuses a grant outside the operation's account" do
    foreign = Struct.new(:account).new(create(:account))

    expect {
      described_class.execute({ grant_id: grant.id, label: "phone" }, deferred_operation: foreign)
    }.to raise_error(::Ai::DeferredOperation::CrossAccountError)

    expect(grant.user_devices.reload.count).to eq(0)
  end
end
