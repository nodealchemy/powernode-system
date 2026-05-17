# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Accept", type: :request do
  let(:account) { create(:account) }
  let(:peer) do
    create(:system_federation_peer, :platform,
           account: account,
           status: "proposed",
           remote_instance_url: "https://child.example.com")
  end
  let(:plaintext_token) { peer.generate_acceptance_token!(ttl_seconds: 1.hour.to_i) }
  let(:path) { "/api/v1/system/federation_api/accept" }

  let(:valid_payload) do
    {
      acceptance_token: plaintext_token,
      contract_version: 1,
      extension_slugs: [ "trading" ],
      capabilities: { "skill" => { "read" => true } },
      endpoints: [
        { url: "https://child.example.com:443", scope: "wan", priority: 1 }
      ]
    }
  end

  describe "POST /accept (happy path)" do
    before { plaintext_token }  # ensure token is generated

    it "transitions proposed → enrolled and returns peer details" do
      post path, params: valid_payload, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      data = body["data"] || body  # render_success may wrap or not

      expect(data["peer_id"]).to eq(peer.id)
      expect(data["status"]).to eq("enrolled")
      expect(data["peer_kind"]).to eq("platform")
      expect(data["contract_version_agreed"]).to eq(1)
      expect(data["accepted_at"]).to be_present
      expect(data["handshake_at"]).to be_present
    end

    it "persists capabilities, extension_slugs, endpoints on the peer" do
      post path, params: valid_payload, as: :json

      peer.reload
      expect(peer.capabilities).to eq("skill" => { "read" => true })
      expect(peer.extension_slugs).to eq([ "trading" ])
      expect(peer.endpoints.first["url"]).to eq("https://child.example.com:443")
      expect(peer.last_handshake_at).to be_within(2.seconds).of(Time.current)
    end

    it "clears the acceptance token (single-use semantics)" do
      post path, params: valid_payload, as: :json
      peer.reload
      expect(peer.acceptance_token_digest).to be_nil
      expect(peer.acceptance_token_expires_at).to be_nil
    end
  end

  describe "POST /accept (failure paths)" do
    before { plaintext_token }

    it "returns 422 when acceptance_token is blank" do
      post path, params: valid_payload.merge(acceptance_token: ""), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"] || JSON.parse(response.body)["errors"]).to be_present
    end

    it "returns 422 when contract_version is unsupported" do
      post path, params: valid_payload.merge(contract_version: 99), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("contract_version")
    end

    it "returns 401 when token doesn't match any peer" do
      post path, params: valid_payload.merge(acceptance_token: "wrong-token-#{SecureRandom.hex(16)}"), as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when the token is expired" do
      peer.update!(acceptance_token_expires_at: 1.hour.ago)
      post path, params: valid_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses to accept twice (token cleared after first use)" do
      post path, params: valid_payload, as: :json
      expect(response).to have_http_status(:ok)

      post path, params: valid_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # P6.3 — managed_child auto-grant cascade. When the parent accepts a
  # managed_child spawn handshake, the AcceptController must record an
  # operator-scope FederationGrant on the parent's side so the operator
  # can subsequently administer the child. Other spawn flows (symmetric
  # out_of_band, autonomous_peer, cluster_member) MUST NOT auto-issue.
  describe "POST /accept — managed_child auto-grant cascade" do
    context "when the peer is a managed_child spawn (parent-side row)" do
      let(:peer) do
        create(:system_federation_peer, :spawned_parent_managed,
               account: account,
               status: "proposed",
               remote_instance_url: "https://child.example.com")
      end

      before { plaintext_token }

      it "creates an operator-scope FederationGrant tied to the peer" do
        expect {
          post path, params: valid_payload, as: :json
        }.to change { ::System::FederationGrant.where(federation_peer: peer).count }.by(1)

        expect(response).to have_http_status(:ok)

        grant = ::System::FederationGrant.where(federation_peer: peer).last
        expect(grant.account_id).to eq(peer.account_id)
        expect(grant.grantor_user_id).to be_nil
        expect(grant.remote_subject).to eq("parent-operator@#{peer.id}")
        expect(grant.resource_kind).to eq("managed_child_operator")
        expect(grant.permission_scopes).to match_array(%w[read write admin])
        expect(grant.expires_at).to be > 364.days.from_now
        expect(grant.metadata["auto_issued_by"]).to eq("managed_child_accept_cascade")
        expect(grant.metadata["spawn_mode"]).to eq("managed_child")
        expect(grant.metadata["spawn_role"]).to eq("parent")
        # Pessimistic axes intentionally empty — operator can tighten later
        # via FederationManager findings.
        expect(grant.unrestricted?).to be true
      end

      it "is idempotent — when an active grant already exists, no duplicate" do
        # Simulate a prior cascade leaving a live grant in place.
        ::System::FederationGrant.create!(
          account: peer.account,
          federation_peer: peer,
          grantor_user: nil,
          remote_subject: "parent-operator@#{peer.id}",
          resource_kind: "managed_child_operator",
          permission_scopes: %w[read write admin],
          issued_at: Time.current,
          expires_at: 365.days.from_now,
          metadata: { "auto_issued_by" => "managed_child_accept_cascade" }
        )

        expect {
          post path, params: valid_payload, as: :json
        }.not_to change { ::System::FederationGrant.where(federation_peer: peer).count }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when the peer is a symmetric out_of_band peering" do
      let(:peer) do
        create(:system_federation_peer, :platform,
               account: account,
               status: "proposed",
               remote_instance_url: "https://peer.example.com")
      end

      before { plaintext_token }

      it "does NOT auto-issue any grant" do
        expect {
          post path, params: valid_payload, as: :json
        }.not_to change { ::System::FederationGrant.where(federation_peer: peer).count }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when the peer is a spawn but not managed_child (e.g. autonomous_peer)" do
      let(:peer) do
        create(:system_federation_peer, :platform,
               account: account,
               status: "proposed",
               spawn_role: "parent",
               spawn_mode: "autonomous_peer",
               remote_instance_url: "https://autonomous.example.com")
      end

      before { plaintext_token }

      it "does NOT auto-issue (autonomous peers are equals — no parental grant)" do
        expect {
          post path, params: valid_payload, as: :json
        }.not_to change { ::System::FederationGrant.where(federation_peer: peer).count }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
