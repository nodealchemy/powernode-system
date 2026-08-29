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

  # IMP-11cb34173d11 (increment 1 of 5). mint_bootstrap_token is a CONTROL
  # FLAG in the ProposeFederationPeer::CONTROL_FLAG_KEYS sense: it steers token
  # minting, it is not a column, and it never reaches a write payload or an
  # approval card. Default is MINT — no existing caller changes behaviour.
  describe "mint_bootstrap_token control flag" do
    it "issues a COMPLETE device and returns no token when the flag is false" do
      result = described_class.execute(
        { grant_id: grant.id, label: "agent-issued", mint_bootstrap_token: false },
        deferred_operation: nil
      )

      expect(result[:success]).to be(true)
      data = result[:data]
      expect(data[:bootstrap_token]).to be_nil
      expect(data[:expires_at]).to be_nil

      # Not merely token-less: the row a suppression bug would have skipped.
      device = grant.user_devices.reload.find(data[:device_id])
      expect(device.label).to eq("agent-issued")
      expect(device.public_key).to match(%r{\A[A-Za-z0-9+/]{43}=\z})
      expect(device.assigned_address).to be_present
      # Boolean, never the value — private key material stays out of failure
      # output. Readable here only because the device is RE-FETCHED above:
      # VaultCredential#store_in_vault poisons the @vault_credentials memo on
      # the object .issue! returns (it assigns nil to a `defined?`-guarded
      # ivar), so the same read on that object answers nil. See
      # user_device_issuer_spec.rb.
      expect(device.private_key_b64.nil?).to be(false)
      expect(data[:grant_id]).to eq(grant.id)
    end

    it "mints when the flag is absent (the DEFAULT — unchanged for every existing caller)" do
      data = described_class.execute(
        { grant_id: grant.id, label: "default-laptop" },
        deferred_operation: nil
      )[:data]

      expect(data[:expires_at]).to be_present
      expect(::Sdwan::UserDeviceIssuer.verify_bootstrap_token!(data[:bootstrap_token])[:device_id])
        .to eq(data[:device_id])
    end

    it "mints when the flag is explicitly true" do
      data = described_class.execute(
        { grant_id: grant.id, label: "explicit-true", mint_bootstrap_token: true },
        deferred_operation: nil
      )[:data]

      expect(data[:expires_at]).to be_present
      expect(::Sdwan::UserDeviceIssuer.verify_bootstrap_token!(data[:bootstrap_token])[:device_id])
        .to eq(data[:device_id])
    end

    # The card exclusion is asserted in BOTH directions. An absence-only
    # oracle is satisfied by `named_attribute_keys = []`, which would stop the
    # card naming ANY field — the exact defect IMP-35bc8eda71ad exists to
    # prevent — so an ordinary key rides along and must still be named.
    it "excludes the control flag from the card without silencing real fields" do
      preview = described_class.preview(
        { grant_id: grant.id, label: "carded",
          attributes: { label: "carded", mint_bootstrap_token: false } }
      )

      expect(preview[:impact].to_s).to include("label")
      expect(preview[:impact].to_s).not_to include("mint_bootstrap_token")
    end

    # The :attributes read in #control_flag is a SAFETY branch — a surface that
    # routes the flag there must not be silently ignored, because the surface
    # would believe it refused a token the executor then minted. Exercised
    # through #execute, not #preview: the card spec above passes whether or not
    # the branch does anything.
    it "honours the flag when it arrives under :attributes rather than flat" do
      data = described_class.execute(
        { grant_id: grant.id, label: "nested-flag",
          attributes: { mint_bootstrap_token: false } },
        deferred_operation: nil
      )[:data]

      expect(data[:bootstrap_token]).to be_nil
      expect(grant.user_devices.reload.find(data[:device_id]).assigned_address).to be_present
    end

    # A form or query param arrives as a STRING. `!= false` alone would mint
    # here — the surface believes it refused the bootstrap URL and one is
    # handed out anyway, which is the disclosure this flag exists to close.
    it "treats a string \"false\" as suppression, not as a truthy value" do
      data = described_class.execute(
        { grant_id: grant.id, label: "string-false", mint_bootstrap_token: "false" },
        deferred_operation: nil
      )[:data]

      expect(data[:bootstrap_token]).to be_nil
      expect(grant.user_devices.reload.find(data[:device_id]).assigned_address).to be_present
    end
  end

  it "refuses a grant outside the operation's account" do
    foreign = Struct.new(:account).new(create(:account))

    expect {
      described_class.execute({ grant_id: grant.id, label: "phone" }, deferred_operation: foreign)
    }.to raise_error(::Ai::DeferredOperation::CrossAccountError)

    expect(grant.user_devices.reload.count).to eq(0)
  end
end
