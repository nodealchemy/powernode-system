# frozen_string_literal: true

require "rails_helper"

# Real-execution coverage for the three trust-boundary executors dispatched by
# the approval-gated revoke/accept actions on the federation-peer and
# access-grant controllers. Previously entirely uncovered. Each extends
# System::Executors::Base and is invoked as `.execute(params, deferred_operation:)`
# returning `{ success:, data: }`. The executors are intentionally unscoped —
# account ownership is enforced upstream by the controllers' set_* guards —
# so these specs pin the actual state mutation each one performs.
RSpec.describe "Sdwan::Executors trust-boundary executors", type: :model do
  let(:account) { create(:account) }

  describe Sdwan::Executors::RevokeFederationPeer do
    it "revokes the federation peer and reports it" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      result = described_class.execute({ federation_peer_id: peer.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result.dig(:data, :revoked)).to be true
      expect(peer.reload.status).to eq("revoked")
    end
  end

  describe Sdwan::Executors::AcceptFederationPeer do
    it "accepts a proposed federation peer" do
      peer = create(:system_federation_peer, account: account, status: "proposed")

      result = described_class.execute({ federation_peer_id: peer.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result.dig(:data, :federation_peer_id)).to eq(peer.id)
      expect(peer.reload.status).to eq("accepted")
    end
  end

  describe Sdwan::Executors::RevokeAccessGrant do
    it "revokes the access grant and reports it" do
      grant = create(:sdwan_access_grant, account: account, status: "active")

      result = described_class.execute({ grant_id: grant.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result.dig(:data, :revoked)).to be true
      expect(grant.reload.status).to eq("revoked")
    end

    # grant.revoke! cascades to every device, so a device-scoped verb reaching
    # this executor would cut the user's whole VPN access. Device verbs use
    # Sdwan::Executors::RevokeUserDevice; a deferred operation gated before that
    # split still names THIS class in its stored executor_class, so the refusal
    # has to live here rather than only in the controller wiring.
    it "refuses device-scoped params instead of cascading to every device" do
      grant  = create(:sdwan_access_grant, account: account, status: "active")
      device = create(:sdwan_user_device, access_grant: grant)

      expect {
        described_class.execute({ grant_id: grant.id, device_id: device.id }, deferred_operation: nil)
      }.to raise_error(ArgumentError, /RevokeUserDevice/)

      expect(grant.reload.status).to eq("active")
      expect(device.reload.revoked?).to be(false)
    end
  end
end
