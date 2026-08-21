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

  # Same PATCH, but the caller controls the WHOLE body — needed for the two
  # fields that are not peer columns and may ride either beside the peer body
  # or inside it (the revocation reason, the acceptance token).
  def patch_raw(peer, body, as:)
    patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
          params: body.to_json,
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

      # IMP-a54dd584e500 — a form-shaped client resends the whole metadata blob
      # on every PATCH, including the accept. peer.update!(ride_along) used to
      # assign :metadata wholesale, so that resend silently wiped
      # degraded_reason/suspension_reason/prior audit keys the request never
      # named, moments before accept! merged its own stamp back on top of the
      # now-empty hash. The survival is the whole point of this spec — a
      # request that errored must not be able to pass it by accident, so the
      # response status is asserted at both PATCH and read time.
      it "preserves pre-existing metadata keys the accept PATCH does not name" do
        peer.update!(metadata: { "degraded_reason" => "flaky uplink",
                                  "suspension_reason" => "manual hold pending review" })

        patch_peer(peer, { status: "accepted", metadata: { "note" => "ops" } }, as: manager)
        expect(response).to have_http_status(:accepted)

        approve_latest_deferred!

        peer.reload
        expect(peer.status).to eq("accepted")
        expect(peer.metadata).to include(
          "degraded_reason" => "flaky uplink",
          "suspension_reason" => "manual hold pending review",
          "note" => "ops",
          "accepted_by_user_id" => manager.id
        )
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

      # IMP-8df377f7d255 — the REST accept surface could not COMPLETE the flow
      # it refuses above.
      #
      # gated_accept! called acceptance_token_error(nil) — hard-coded — and
      # peer_update_params never permitted acceptance_token, so there was no way
      # to supply one. Since ProposeFederationPeer mints a token by default,
      # every REST-proposed peer carries a digest and PATCH {status: "accepted"}
      # 422'd unconditionally: MCP was the only surface that could accept a
      # token-protected peer, and the 422's own text said so.
      #
      # The token is NOT a peer column, so it is read beside peer_update_params
      # the same way the revocation reason is — permitting it there would send
      # it into @peer.update on the ordinary edit path and into the executor's
      # ride-along attributes, both of which would raise on an unknown attribute.
      context "with a Phase 11b acceptance token" do
        let(:plaintext) { peer.generate_acceptance_token! }

        it "defers the acceptance when the correct token rides beside the peer body" do
          token = plaintext

          expect {
            patch_raw(peer, { federation_peer: { status: "accepted" }, acceptance_token: token }, as: manager)
          }.to change(Ai::DeferredOperation, :count).by(1)

          expect(response).to have_http_status(:accepted)
          expect(peer.reload.status).to eq("proposed"), "acceptance bypassed the approval gate"

          deferred = Ai::DeferredOperation.order(created_at: :desc).first
          expect(deferred.params["acceptance_token"]).to eq(token),
                                                         "the token was dropped between the controller and the executor"
          expect(deferred.params["attributes"]).not_to include("acceptance_token"),
                                                       "the token leaked into the ride-along attributes accept! writes"
        end

        it "accepts the token-protected peer once the deferred op is approved" do
          token = plaintext
          patch_raw(peer, { federation_peer: { status: "accepted" }, acceptance_token: token }, as: manager)
          approve_latest_deferred!

          expect(peer.reload.status).to eq("accepted"), "approved acceptance left the peer proposed"
          expect(peer.acceptance_token_digest).to be_nil, "the single-use token was not consumed"
          expect(peer.metadata["acceptance_token_used"]).to be(true)
        end

        it "reads the token from inside the peer body too" do
          token = plaintext

          patch_raw(peer, { federation_peer: { status: "accepted", acceptance_token: token } }, as: manager)

          expect(response).to have_http_status(:accepted)
        end

        it "refuses a wrong token up front, before the gate, without consuming it" do
          plaintext # mint

          expect {
            patch_raw(peer, { federation_peer: { status: "accepted" }, acceptance_token: "not-the-token" },
                      as: manager)
          }.not_to change(Ai::DeferredOperation, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to match(/does not match stored digest/)
          expect(peer.reload.acceptance_token_digest).to be_present
          expect(peer.status).to eq("proposed")
        end

        it "refuses an expired token up front" do
          plaintext
          peer.update!(acceptance_token_expires_at: 1.minute.ago)

          expect {
            patch_raw(peer, { federation_peer: { status: "accepted" }, acceptance_token: plaintext }, as: manager)
          }.not_to change(Ai::DeferredOperation, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to match(/expired/)
        end
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

    # IMP-9bf58a693634 — data_residency is the compliance tag
    # Federation::ResidencyEnforcer reads to decide whether a record may cross
    # a regulatory boundary to this peer. It was writable ONLY over MCP
    # (SdwanTool#set_data_residency, a bare update!) and absent from this
    # permit list entirely, so the operator surface could not set it at all.
    # Permitting it here gives operators the path; routing it through the gate
    # gives it the same treatment as its trust-boundary siblings.
    context "when the request changes data_residency (compliance tag)" do
      let(:peer) { create(:system_federation_peer, account: account, status: "proposed", data_residency: "us-east") }

      it "defers the residency change through the approval gate instead of writing it inline" do
        patch_peer(peer, { data_residency: "eu-west" }, as: manager)

        expect(response).to have_http_status(:accepted)
        expect(peer.reload.data_residency).to eq("us-east"),
                                              "the residency tag was written inline, bypassing the approval gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.action_category).to eq("sdwan.federation_peer_data_residency")
        expect(deferred.executor_class).to eq("Sdwan::Executors::SetFederationPeerDataResidency")
        expect(deferred.params["federation_peer_id"]).to eq(peer.id)
      end

      it "applies the tag when the deferred op is approved" do
        patch_peer(peer, { data_residency: "eu-west" }, as: manager)
        approve_latest_deferred!

        expect(peer.reload.data_residency).to eq("eu-west")
      end

      # Ride-along edits travel WITH the deferral rather than landing ahead of
      # it — the acceptance leg's rule, for the same reason: one operator
      # intent, and a half-applied PATCH is what that leg exists to avoid.
      it "carries same-request field edits into the approval rather than applying them first" do
        patch_peer(peer, { data_residency: "eu-west", remote_instance_url: "https://elsewhere.example.com" }, as: manager)

        expect(peer.reload.remote_instance_url).not_to eq("https://elsewhere.example.com"),
                                                       "a ride-along edit was applied ahead of the approval"

        approve_latest_deferred!

        expect(peer.reload.data_residency).to eq("eu-west")
        expect(peer.remote_instance_url).to eq("https://elsewhere.example.com")
      end

      # A form-shaped client resends every permitted field on every PATCH. An
      # unchanged residency tag must not park an approval for a no-op.
      it "stays inline when the residency tag is resent unchanged" do
        expect {
          patch_peer(peer, { data_residency: "us-east", remote_instance_url: "https://elsewhere.example.com" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:ok)
        expect(peer.reload.remote_instance_url).to eq("https://elsewhere.example.com")
      end

      # A residency change and a status transition are separately approved and
      # land in different executors, neither of which performs both writes.
      # Dispatching on either one alone would silently DROP the other behind a
      # 202 that reads as success — before this field was permitted, that same
      # PATCH suspended the peer inline, so accepting it and discarding half
      # would be a regression, not a new restriction.
      it "refuses a PATCH that changes residency AND transitions status, applying neither" do
        peer.update!(status: "accepted")

        expect {
          patch_peer(peer, { status: "suspended", data_residency: "eu-west" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(peer.reload.status).to eq("accepted"), "the status transition was applied despite the refusal"
        expect(peer.data_residency).to eq("us-east"), "the residency change was applied despite the refusal"
      end

      # The same rule covers the ACCEPT leg, which forwards every permitted
      # ride-along field into Sdwan::Executors::AcceptFederationPeer — an
      # executor that writes attributes but emits no residency audit event. A
      # residency change riding an acceptance would therefore be gated but
      # UNTRACEABLE on the peer's trail.
      it "refuses a residency change riding along on an acceptance" do
        proposed = create(:system_federation_peer, account: account, status: "proposed", data_residency: "us-east")

        expect {
          patch_peer(proposed, { status: "accepted", data_residency: "eu-west" }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(proposed.reload.data_residency).to eq("us-east")
        expect(proposed.status).to eq("proposed")
      end

      it "projects the stored tag so an operator can read what they are changing" do
        get "/api/v1/system/sdwan/federation_peers/#{peer.id}", headers: auth_headers_for(reader)

        expect(response).to have_http_status(:ok)
        expect(json_response_data["federation_peer"]["data_residency"]).to eq("us-east"),
                                                                          "the operator surface accepts data_residency on PATCH but never hands it back"
      end

      # Same oracle as IMP-785d60f5ec3e — a doomed value parks nothing.
      it "422s an over-long tag without parking an approval" do
        expect {
          patch_peer(peer, { data_residency: "e" * 65 }, as: manager)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(peer.reload.data_residency).to eq("us-east")
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
