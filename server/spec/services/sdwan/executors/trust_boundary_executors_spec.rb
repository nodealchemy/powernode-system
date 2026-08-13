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

    # Both callers that reach this executor collect a revocation reason — the
    # controller's #revoke passes it into the gate params, and the MCP tool
    # documents it as "recorded on the peer". FederationPeer#revoke! has always
    # accepted `reason:`; the executor calling it bare is the single point where
    # the operator's cause was lost (IMP-8ce2d82065b9).
    it "records the operator's reason on the peer" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      described_class.execute(
        { federation_peer_id: peer.id, reason: "remote signing key compromised" },
        deferred_operation: nil
      )

      expect(peer.reload.metadata["revocation_reason"]).to eq("remote signing key compromised")
    end

    it "revokes without a reason when none was supplied" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      result = described_class.execute({ federation_peer_id: peer.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(peer.reload.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to be_nil
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

    # FederationPeer#accept! returns false (it never raises) on a rejected
    # transition or a bad token. Dropping that return value reports success over
    # a peer that never left "proposed" — and a deferred operation runs hours
    # after the request that queued it, so the peer's status is exactly the
    # thing that may have moved in between.
    it "raises instead of reporting success when the peer can no longer transition" do
      peer = create(:system_federation_peer, account: account, status: "revoked")

      expect {
        described_class.execute({ federation_peer_id: peer.id }, deferred_operation: nil)
      }.to raise_error(ArgumentError, /cannot transition to accepted/)

      expect(peer.reload.status).to eq("revoked")
    end

    it "raises instead of reporting success when the single-use token is missing" do
      peer = create(:system_federation_peer, account: account, status: "proposed")
      peer.generate_acceptance_token!

      expect {
        described_class.execute({ federation_peer_id: peer.id }, deferred_operation: nil)
      }.to raise_error(ArgumentError, /acceptance_token required/)

      expect(peer.reload.status).to eq("proposed")
      expect(peer.acceptance_token_digest).to be_present, "single-use token consumed by a failed acceptance"
    end

    it "verifies and consumes a correct single-use token" do
      peer      = create(:system_federation_peer, account: account, status: "proposed")
      plaintext = peer.generate_acceptance_token!

      result = described_class.execute(
        { federation_peer_id: peer.id, acceptance_token: plaintext }, deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(peer.reload.status).to eq("accepted")
      expect(peer.acceptance_token_digest).to be_nil
    end

    # The controller's PATCH permits other mutable fields in the same request as
    # the status flip; they arrive under params[:attributes] and must land, but
    # must not overwrite the acceptance stamp accept! merges into metadata.
    it "applies the ride-along attributes of the originating PATCH without clobbering the audit stamp" do
      peer = create(:system_federation_peer, account: account, status: "proposed")

      described_class.execute(
        {
          federation_peer_id: peer.id,
          attributes: { "remote_prefix_advertisement" => "fd00:beef::/48", "metadata" => { "note" => "ops" } }
        },
        deferred_operation: nil
      )

      peer.reload
      expect(peer.status).to eq("accepted")
      expect(peer.remote_prefix_advertisement).to eq("fd00:beef::/48")
      expect(peer.metadata).to include("note" => "ops")
      expect(peer.metadata).to have_key("accepted_by_user_id")
    end

    # accept! can refuse AFTER the ride-along fields are written. If the two are
    # not one transaction, a rejected acceptance still commits the field edits —
    # an unapproved edit smuggled in on an acceptance that never happened.
    it "rolls the ride-along attributes back when the acceptance is refused" do
      peer = create(:system_federation_peer, account: account, status: "proposed",
                                             remote_prefix_advertisement: "fd00:1::/64")
      peer.generate_acceptance_token!

      expect {
        described_class.execute(
          {
            federation_peer_id: peer.id,
            attributes: { "remote_prefix_advertisement" => "fd00:beef::/48" }
          },
          deferred_operation: nil
        )
      }.to raise_error(ArgumentError, /acceptance_token required/)

      peer.reload
      expect(peer.status).to eq("proposed")
      expect(peer.remote_prefix_advertisement).to eq("fd00:1::/64"),
                                                  "a refused acceptance committed its ride-along edit"
    end

    # accept! stamps signed_at with the moment of acceptance, which is what the
    # column means — a value carried in the same PATCH cannot win.
    it "stamps signed_at from the acceptance, not from a ride-along value" do
      peer  = create(:system_federation_peer, account: account, status: "proposed")
      stale = 30.days.ago.change(usec: 0)

      described_class.execute(
        { federation_peer_id: peer.id, attributes: { "signed_at" => stale.iso8601 } },
        deferred_operation: nil
      )

      expect(peer.reload.signed_at).to be > 1.minute.ago
    end

    # requested_by is recorded by the gate from current_user; params are replayed
    # from a stored row and must not be able to name a different accepting operator.
    it "stamps the accepting operator from the deferred operation, not from params" do
      peer     = create(:system_federation_peer, account: account, status: "proposed")
      operator = create(:user, account: account)
      imposter = create(:user, account: account)
      deferred = Ai::DeferredOperation.create!(
        account: account,
        action_category: "sdwan.federation_peer_accept",
        executor_class: "Sdwan::Executors::AcceptFederationPeer",
        params: { federation_peer_id: peer.id },
        requested_by: operator
      )

      described_class.execute(
        { federation_peer_id: peer.id, accepted_by_user_id: imposter.id }, deferred_operation: deferred
      )

      expect(peer.reload.metadata["accepted_by_user_id"]).to eq(operator.id)
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
