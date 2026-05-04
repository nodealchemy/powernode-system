# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::UserDeviceIssuer, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:user) { ::User.where(account_id: account.id).first || create(:user, account: account) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let(:network) { Sdwan::Network.create!(account_id: account.id, name: "issuer-net-#{SecureRandom.hex(4)}") }
  let(:grant) do
    Sdwan::AccessGrant.create!(
      sdwan_network_id: network.id,
      user_id: user.id,
      account_id: account.id,
      status: "active",
      granted_at: Time.current
    )
  end

  describe ".issue!" do
    it "creates a UserDevice with public_key, allocates address, returns a bootstrap token" do
      result = described_class.issue!(grant: grant, label: "macbook")
      device = result[:device]

      expect(device).to be_persisted
      expect(device.label).to eq("macbook")
      expect(device.public_key).to match(/\A[A-Za-z0-9+\/]{43}=\z/)
      expect(device.assigned_address).to start_with(network.cidr_64.sub(%r{::/64\z}, ":"))
      expect(device.assigned_address).to end_with("/128")

      expect(result[:bootstrap_token]).to be_a(String)
      expect(result[:bootstrap_token]).not_to be_empty
      expect(result[:expires_at]).to be_present
    end

    it "raises GrantError when grant is not active" do
      grant.update!(status: "suspended")
      expect {
        described_class.issue!(grant: grant, label: "phone")
      }.to raise_error(described_class::GrantError, /not active/)
    end

    it "produces a different keypair on each call" do
      a = described_class.issue!(grant: grant, label: "device-a")
      b = described_class.issue!(grant: grant, label: "device-b")
      expect(a[:device].public_key).not_to eq(b[:device].public_key)
      expect(a[:device].assigned_address).not_to eq(b[:device].assigned_address)
    end
  end

  describe ".verify_bootstrap_token!" do
    let(:result) { described_class.issue!(grant: grant, label: "verify-test") }

    it "returns the device_id for a valid token" do
      payload = described_class.verify_bootstrap_token!(result[:bootstrap_token])
      expect(payload[:device_id]).to eq(result[:device].id)
    end

    it "raises BootstrapTokenError on a tampered token" do
      tampered = result[:bootstrap_token].sub(/.\z/, "X")
      expect {
        described_class.verify_bootstrap_token!(tampered)
      }.to raise_error(described_class::BootstrapTokenError, /invalid or expired/)
    end

    it "raises BootstrapTokenError on garbage input" do
      expect {
        described_class.verify_bootstrap_token!("not-a-token")
      }.to raise_error(described_class::BootstrapTokenError)
    end
  end
end
