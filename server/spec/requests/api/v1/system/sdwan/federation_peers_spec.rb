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

    # The mirror image of acceptance: revocation WITHDRAWS trust, and both
    # endpoints dedicated to it (#destroy, #revoke) gate on
    # sdwan.federation_peer_revoke. "revoked" is a legal V1_TRANSITIONS target
    # from EVERY non-terminal state, so PATCH was a third, ungated route to the
    # same state change — and being inline it never reached
    # FederationPeer#revoke!, so no revocation_reason could be recorded either
    # (IMP-ca3440a11a9a).
    context "when the status transition is to revoked (trust-withdrawing)" do
      let(:accepted) { create(:system_federation_peer, account: account, status: "accepted") }

      # The reason is not a peer column, so it can arrive either beside the
      # peer body (mirroring POST /revoke) or inside it (the natural shape for
      # a client that wraps everything). Both are threaded.
      def patch_raw(peer, body, as:)
        patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
              params: body.to_json,
              headers: auth_headers_for(as).merge("Content-Type" => "application/json")
      end

      it "defers the revocation through the approval gate instead of writing it inline" do
        patch_peer(accepted, { status: "revoked" }, as: manager)

        expect(response).to have_http_status(:accepted)
        expect(accepted.reload.status).to eq("accepted"),
                                          "revocation was written inline, bypassing the approval gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.action_category).to eq("sdwan.federation_peer_revoke")
        expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeFederationPeer")
        expect(deferred.params["federation_peer_id"]).to eq(accepted.id)
      end

      it "revokes the peer when the deferred op is approved" do
        patch_peer(accepted, { status: "revoked" }, as: manager)
        approve_latest_deferred!

        expect(accepted.reload.status).to eq("revoked"), "approved revocation left the peer accepted"
      end

      it "records a reason sent beside the peer body" do
        patch_raw(accepted, { federation_peer: { status: "revoked" }, reason: "peer CA rotated out of band" }, as: manager)
        approve_latest_deferred!

        expect(accepted.reload.metadata["revocation_reason"]).to eq("peer CA rotated out of band")
      end

      it "records a reason sent inside the peer body" do
        patch_raw(accepted, { federation_peer: { status: "revoked", reason: "contract ended" } }, as: manager)
        approve_latest_deferred!

        expect(accepted.reload.metadata["revocation_reason"]).to eq("contract ended")
      end

      it "revokes without a reason when the operator supplies none" do
        patch_peer(accepted, { status: "revoked" }, as: manager)
        approve_latest_deferred!

        expect(accepted.reload.status).to eq("revoked")
        expect(accepted.metadata["revocation_reason"]).to be_nil
      end

      # Unlike acceptance, ride-along fields do NOT travel with the deferral:
      # revoked is terminal and RevokeFederationPeer applies no attributes. They
      # are ignored rather than 422'd, because a form-shaped client resends
      # every permitted field on every PATCH and refusing that would break a
      # legitimate revocation. What must never happen is the edit landing
      # inline, ahead of the approval.
      it "ignores ride-along field edits instead of applying them ahead of the approval" do
        patch_peer(accepted, { status: "revoked", remote_prefix_advertisement: "fd00:beef::/48" }, as: manager)

        expect(accepted.reload.remote_prefix_advertisement).to be_blank,
                                                               "ride-along field was written before approval"

        approve_latest_deferred!

        expect(accepted.reload.status).to eq("revoked")
        expect(accepted.remote_prefix_advertisement).to be_blank
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

      # Enrollment and activation TRACK an existing link rather than forming or
      # cutting one, so gating revocation must not sweep them in.
      it "enrolls and activates inline without an approval gate" do
        tracked = create(:system_federation_peer, account: account, status: "accepted")

        expect {
          patch_peer(tracked, { status: "enrolled" }, as: manager)
          expect(response).to have_http_status(:ok)
          patch_peer(tracked, { status: "active" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:ok)
        expect(tracked.reload.status).to eq("active")
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
    def revoke_peer(peer, as:, **body)
      post "/api/v1/system/sdwan/federation_peers/#{peer.id}/revoke",
           params: body.to_json,
           headers: auth_headers_for(as).merge("Content-Type" => "application/json")
    end

    it "requires sdwan.federation.manage (the approval-gated revoke is behind the manage permission)" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      post "/api/v1/system/sdwan/federation_peers/#{peer.id}/revoke", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:forbidden)
    end

    # Withdrawing cross-instance trust is the audit event where the cause
    # matters most, and the operator supplies it here. The controller parks it
    # in the deferred params, but nothing between the request and the record
    # writes it — only the executor does, and it runs after the approval. So
    # the assertion that proves the whole chain is the one taken post-approval;
    # asserting the deferred params alone certifies the half that already
    # worked (IMP-8ce2d82065b9).
    it "records the operator's reason on the peer once the revocation is approved" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      revoke_peer(peer, as: manager, reason: "remote signing key compromised")

      expect(response).to have_http_status(:accepted)
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.action_category).to eq("sdwan.federation_peer_revoke")
      expect(deferred.params["reason"]).to eq("remote signing key compromised")

      approve_latest_deferred!

      expect(peer.reload.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to eq("remote signing key compromised"),
                                                       "the reason was dropped between the gate and the peer"
    end

    it "surfaces the recorded reason when the revoked peer is read back" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      revoke_peer(peer, as: manager, reason: "remote signing key compromised")
      approve_latest_deferred!

      get "/api/v1/system/sdwan/federation_peers/#{peer.id}", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      expect(json_response_data.dig("federation_peer", "metadata", "revocation_reason"))
        .to eq("remote signing key compromised")
    end

    # #show projects the full metadata blob, #index does not — and the list is
    # the federation view an operator actually opens. A reason readable only by
    # fetching each peer individually is not surfaced.
    it "surfaces the recorded reason in the peer list, not only on show" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      revoke_peer(peer, as: manager, reason: "remote signing key compromised")
      approve_latest_deferred!

      get "/api/v1/system/sdwan/federation_peers", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      listed = json_response_data["federation_peers"].find { |p| p["id"] == peer.id }
      expect(listed["revocation_reason"]).to eq("remote signing key compromised")
    end

    # A revocation with no stated cause stays legal — the param is optional on
    # both the REST and the MCP surface.
    it "revokes without a reason when the operator supplies none" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      revoke_peer(peer, as: manager)
      approve_latest_deferred!

      expect(peer.reload.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to be_nil
    end
  end
end
