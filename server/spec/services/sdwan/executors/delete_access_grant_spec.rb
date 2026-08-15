# frozen_string_literal: true

require "rails_helper"

# Sdwan::Executors::DeleteAccessGrant is the hard-delete counterpart to
# Sdwan::Executors::RevokeAccessGrant. Revoking flips status and soft-revokes
# devices, deliberately keeping every row for the 90-day audit window; deleting
# removes the grant, cascades through `dependent: :destroy` to every device, and
# takes each device's WireGuard key out of Vault with it. The two must stay
# distinct executors so an operator approving one never gets the other.
RSpec.describe Sdwan::Executors::DeleteAccessGrant, type: :model do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }

  let!(:device) { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

  it "destroys the grant and every device beneath it" do
    result = described_class.execute(
      { network_id: network.id, grant_id: grant.id },
      deferred_operation: nil
    )

    expect(result[:success]).to be(true)
    expect(result.dig(:data, :destroyed)).to be(true)
    expect(result.dig(:data, :devices_destroyed)).to eq(1)

    expect(Sdwan::AccessGrant.exists?(grant.id)).to be(false)
    expect(Sdwan::UserDevice.exists?(device.id)).to be(false)
  end

  it "leaves a grant on another network untouched" do
    other_grant = create(:sdwan_access_grant, account: account, network: create(:sdwan_network, account: account))

    described_class.execute({ network_id: network.id, grant_id: grant.id }, deferred_operation: nil)

    expect(Sdwan::AccessGrant.exists?(other_grant.id)).to be(true)
  end

  describe "scoping" do
    # A deferred operation runs long after the request that created it, so the
    # network/grant pairing recorded in params is re-validated against current
    # state rather than trusted.
    it "refuses a grant that belongs to a different network" do
      other_network = create(:sdwan_network, account: account)
      other_grant   = create(:sdwan_access_grant, account: account, network: other_network)

      expect {
        described_class.execute({ network_id: network.id, grant_id: other_grant.id }, deferred_operation: nil)
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(Sdwan::AccessGrant.exists?(other_grant.id)).to be(true)
    end
  end

  describe "preview" do
    # The approval card is the only place an operator sees the blast radius
    # before saying yes, so the cascade has to be named there.
    it "reports the device count in the impact line" do
      preview = described_class.preview({ network_id: network.id, grant_id: grant.id })

      expect(preview[:summary]).to include("Delete SDWAN access grant")
      expect(preview[:impact]).to include("1 device")
    end
  end
end
