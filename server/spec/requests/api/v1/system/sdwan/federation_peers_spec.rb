# frozen_string_literal: true

require "rails_helper"

# Trust-boundary coverage for the federation-peer controller (previously zero
# request-spec coverage). Federation peering is a cross-instance trust boundary:
# read endpoints gate on sdwan.federation.read, mutate endpoints on
# sdwan.federation.manage, peers are account-scoped (IDOR), and status writes
# are constrained to the V1_TRANSITIONS state machine (illegal flips -> 422).
RSpec.describe "Api::V1::System::Sdwan::FederationPeers", type: :request do
  let(:account)  { create(:account) }
  let(:reader)   { user_with_permissions("system.sdwan.federation.read", account: account) }
  let(:manager)  { user_with_permissions("system.sdwan.federation.read", "system.sdwan.federation.manage", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }

  def patch_peer(peer, attributes, as:)
    patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
          params: { federation_peer: attributes }.to_json,
          headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  # Executes the deferred operation the gate parked — the tail of the approval
  # path (Ai::ApprovalRequest ultimately calls execute_now!), not the whole of
  # it; the approval-chain hop itself is core-owned and untouched here.
  def approve_latest_deferred!
    Ai::DeferredOperation.order(created_at: :desc).first.tap(&:execute_now!)
  end

  describe "GET /api/v1/system/sdwan/federation_peers" do
    it "forbids callers without sdwan.federation.read" do
      get "/api/v1/system/sdwan/federation_peers", headers: auth_headers_for(stranger)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists only the caller's own account peers (IDOR scoping)" do
      mine  = create(:system_federation_peer, account: account)
      other = create(:system_federation_peer) # different account

      get "/api/v1/system/sdwan/federation_peers", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      ids = json_response_data["federation_peers"].map { |p| p["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end
  end

  describe "GET /api/v1/system/sdwan/federation_peers/:id" do
    it "404s for a peer in another account (IDOR guard)" do
      foreign = create(:system_federation_peer) # different account

      get "/api/v1/system/sdwan/federation_peers/#{foreign.id}", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/system/sdwan/federation_peers/:id" do
    let(:peer) { create(:system_federation_peer, account: account, status: "proposed") }

    it "forbids mutation with read-only permission (permission split)" do
      patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
            params: { federation_peer: { remote_instance_url: "https://x.example.com" } }.to_json,
            headers: auth_headers_for(reader).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects an illegal v1 status transition with 422" do
      # V1_TRANSITIONS["proposed"] = [accepted, revoked]; "active" is not allowed.
      patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
            params: { federation_peer: { status: "active" } }.to_json,
            headers: auth_headers_for(manager).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/not permitted in v1/i)
      expect(peer.reload.status).to eq("proposed")
    end

    # Acceptance is the only #update transition that EXTENDS trust: it completes
    # the handshake that starts mutual route advertisement with a remote
    # instance. Its inverse (revoke) is approval-gated on two endpoints, so
    # forming the link is gated to match. Every other transition stays inline.
    context "when the status transition is to accepted (trust-extending)" do
      it "defers the acceptance through the approval gate instead of writing it inline" do
        patch_peer(peer, { status: "accepted" }, as: manager)

        expect(response).to have_http_status(:accepted)
        expect(peer.reload.status).to eq("proposed"),
                                      "acceptance was written inline, bypassing the approval gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.action_category).to eq("sdwan.federation_peer_accept")
        expect(deferred.executor_class).to eq("Sdwan::Executors::AcceptFederationPeer")
        expect(deferred.params["federation_peer_id"]).to eq(peer.id)
      end

      # gate! never calls on_proceed on its :pending branch, and require_approval
      # IS the normal path here — so the acceptance has to be performed by the
      # executor, not by a controller lambda (IMP-322999495307).
      it "accepts the peer when the deferred op is approved" do
        patch_peer(peer, { status: "accepted" }, as: manager)
        approve_latest_deferred!

        expect(peer.reload.status).to eq("accepted"), "approved acceptance left the peer proposed"
        expect(peer.signed_at).to be_present
        expect(peer.metadata["accepted_by_user_id"]).to eq(manager.id)
      end

      # A PATCH may carry other permitted fields alongside the status flip; they
      # belong to the same operator intent, so they ride with the deferral
      # rather than being applied ahead of the approval.
      it "carries the ride-along fields of the same PATCH into the deferred acceptance" do
        patch_peer(peer, { status: "accepted", remote_prefix_advertisement: "fd00:beef::/48" }, as: manager)

        expect(peer.reload.remote_prefix_advertisement).to be_blank,
                                                           "ride-along field was written before approval"

        approve_latest_deferred!

        expect(peer.reload.status).to eq("accepted")
        expect(peer.remote_prefix_advertisement).to eq("fd00:beef::/48")
      end

      # The inline path wrote status: "accepted" straight through @peer.update,
      # which never reached FederationPeer#accept! and so never verified the
      # Phase 11b single-use acceptance token. The REST surface collects no
      # token, so a token-protected peer must not be acceptable through it —
      # and #create mints a token by default, so this is the common case.
      #
      # It must be refused UP FRONT: the executor also refuses, but on the
      # :pending path it runs from ApprovalRequest#notify_source_of_decision,
      # which rescues and only logs — the operator would approve, get 200, and
      # never learn the peer stayed proposed.
      it "refuses a token-protected peer up front rather than parking a doomed approval" do
        peer.generate_acceptance_token!

        expect {
          patch_peer(peer, { status: "accepted" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to match(/acceptance_token required/)
        expect(peer.reload.status).to eq("proposed")
        expect(peer.acceptance_token_digest).to be_present, "single-use token was consumed by a refused acceptance"
      end
    end

    context "when the status transition does not extend trust" do
      it "suspends inline without an approval gate" do
        accepted = create(:system_federation_peer, account: account, status: "accepted")

        expect {
          patch_peer(accepted, { status: "suspended" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:ok)
        expect(accepted.reload.status).to eq("suspended")
      end

      it "updates non-status fields inline without an approval gate" do
        expect {
          patch_peer(peer, { remote_instance_url: "https://elsewhere.example.com" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:ok)
        expect(peer.reload.remote_instance_url).to eq("https://elsewhere.example.com")
      end
    end
  end

  describe "POST /api/v1/system/sdwan/federation_peers/:id/revoke" do
    it "requires sdwan.federation.manage (the approval-gated revoke is behind the manage permission)" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      post "/api/v1/system/sdwan/federation_peers/#{peer.id}/revoke", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
