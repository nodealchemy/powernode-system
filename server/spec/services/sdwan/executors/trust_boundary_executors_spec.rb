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
  end
end
