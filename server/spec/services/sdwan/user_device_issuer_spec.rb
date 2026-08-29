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

  # IMP-11cb34173d11 (increment 1 of 5): issuing a device and minting the
  # bootstrap token are SEPARABLE. bootstrap_token_for is the last act of
  # .issue! — the row, the Vault private half and the allocated address all
  # exist before it runs — so a caller that must not hand back a bootstrap URL
  # (a bootstrap URL is the sole auth for an anonymous endpoint that serves a
  # WireGuard PRIVATE key) can still issue a complete, usable device.
  #
  # DEFAULT IS UNCHANGED: minting stays on unless a caller explicitly opts out.
  describe ".issue! with mint_bootstrap_token:" do
    it "issues a COMPLETE device and no token when minting is off" do
      result = described_class.issue!(grant: grant, label: "no-token", mint_bootstrap_token: false)
      device = result[:device]

      expect(result[:bootstrap_token]).to be_nil
      expect(result[:expires_at]).to be_nil

      # The device must be FULLY created, not merely token-less. A change that
      # simply failed to create the device would satisfy the nil assertions
      # above, and that is the failure mode this guards: persisted row,
      # keypair, Vault private half, allocated overlay address.
      # Deliberately NOT `expect(device).to be_persisted`: on a red RSpec
      # renders device.inspect, and attributes_for_inspect is narrowed to [:id]
      # only in config/environments/production.rb — so in test the dump would
      # include encrypted_credentials, which here is a plain
      # Base64(JSON) of the X25519 PRIVATE key. exists? is the stronger
      # assertion anyway (it survives a rolled-back transaction that leaves the
      # in-memory object looking persisted) and it reduces to a boolean.
      expect(Sdwan::UserDevice.exists?(device.id)).to be(true)
      expect(device.label).to eq("no-token")
      expect(device.public_key).to match(/\A[A-Za-z0-9+\/]{43}=\z/)
      expect(device.assigned_address).to start_with(network.cidr_64.sub(%r{::/64\z}, ":"))
      expect(device.assigned_address).to end_with("/128")

      # The private half was written through store_in_vault. Asserted via the
      # STORAGE LOCATION, never the value: private key material must not be
      # able to reach an RSpec failure message or a diff.
      #
      # Deliberately NOT `private_key_b64` — and the reason is a core
      # memoization bug, NOT this account or Vault reachability.
      # VaultCredential#store_in_vault assigns `@vault_credentials = nil` to
      # "clear" the memo, but #vault_credentials guards on
      # `defined?(@vault_credentials)` — and the assignment DEFINES it. So the
      # memo answers nil forever on the very object .issue! returns, in every
      # environment and for every account, and `reload` does not clear an ivar.
      # (Vault itself is not involved: VaultCredentialProvider#vault_available?
      # is `return false if Rails.env.test?` unconditionally, so test always
      # takes the DB fallback.) The executor spec asserts the readback on a
      # re-FETCHED object, which is what dodges the memo.
      device.reload
      expect(device.credential_storage_location).not_to eq(:none)
    end

    it "mints exactly as today when the flag is absent (the DEFAULT)" do
      result = described_class.issue!(grant: grant, label: "default-mints")

      expect(result[:bootstrap_token]).to be_a(String)
      expect(described_class.verify_bootstrap_token!(result[:bootstrap_token])[:device_id])
        .to eq(result[:device].id)
      expect(result[:expires_at]).to be_present
    end

    it "mints when the flag is explicitly true" do
      result = described_class.issue!(grant: grant, label: "explicit-true", mint_bootstrap_token: true)

      expect(result[:bootstrap_token]).to be_a(String)
      expect(described_class.verify_bootstrap_token!(result[:bootstrap_token])[:device_id])
        .to eq(result[:device].id)
      expect(result[:expires_at]).to be_present
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
