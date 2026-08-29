# frozen_string_literal: true

require "rails_helper"

# IMP-27cc7dceb97b (site 5) — PeerGrantsController#serialize returned the FULL
# live federation bearer token under the key `bearer_token_preview`.
#
# Two separate problems, and only one of them is the name:
#
#   1. THE NAME LIED. `bearer_token_preview` is not a preview of anything.
#      System::FederationGrant#bearer_token returns "fgs.<grant_id>.<hmac>" in
#      full — the complete credential a federated peer presents.
#
#   2. THE VALUE WAS NOT A SHOWN-ONCE MINT. #bearer_token is DERIVED on every
#      call (HMAC-SHA256 of the server secret over "federation-grant:<id>"),
#      not stored at issuance and shown once. `serialize` is shared by #index,
#      #create and #revoke, so the credential was re-emitted on EVERY list
#      read — for active, expired, revoked AND archived grants alike.
#
#      #index requires only `system.peers.read` while issuing a grant requires
#      `system.peers.manage`. So a read-only operator could harvest the live
#      bearer token of every grant on every peer: the read permission yielded
#      the credential the manage permission issues. That is a privilege
#      inversion, not a disclosure-format quibble.
#
# THE FIX KEEPS THE REVEAL WHERE IT IS LEGITIMATE. A shown-once reveal in an
# HTTP response is an accepted pattern in this codebase (see
# Api::V1::System::DiskImageWebhooksController and CiWorkersController) — an
# HTTP response acquires neither of the MCP sinks (ai_messages
# .processing_metadata, the role:"tool" message forwarded to the model
# provider). So #create still returns the token at issuance, under the honest
# name `bearer_token`. #index and #revoke no longer carry it at all.
#
# Nothing is stranded: no frontend component renders this field (only the
# TypeScript type and two test fixtures name it), and an operator who lost a
# token revokes the grant and issues a new one — the same recovery shape
# Sdwan::Executors::ProposeFederationPeer's single-use acceptance token has.
#
# ORACLE NOTE: every absence assertion is paired with a positive one, so a
# change that simply returns nothing useful fails. No assertion can print a
# token in a failure message: absences are `include?(x) => be(false)` with
# literal messages, and the one positive that must inspect the revealed value
# compares SHA-256 digests rather than the value itself.
RSpec.describe "Api::V1::System::Platform::PeerGrants bearer-token exposure", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.peers.read", account: account) }
  let(:manager) { user_with_permissions("system.peers.read", "system.peers.manage", account: account) }
  let!(:peer) { create(:system_federation_peer, :active, account: account) }
  let(:base) { "/api/v1/system/platform/peers/#{peer.id}/grants" }

  describe "GET /grants (system.peers.read)" do
    let!(:active_grant) do
      create(:system_federation_grant, account: account, federation_peer: peer,
                                       remote_subject: "alice@b.example.org",
                                       resource_kind: "skill",
                                       permission_scopes: %w[read],
                                       issued_at: 1.day.ago,
                                       expires_at: 29.days.from_now)
    end
    let!(:revoked_grant) do
      # Distinct resource_kind: idx_fed_grants_kind_wide_unique is unique on
      # (federation_peer_id, remote_subject, resource_kind).
      g = create(:system_federation_grant, account: account, federation_peer: peer,
                                           remote_subject: "alice@b.example.org",
                                           resource_kind: "trading_strategy",
                                           permission_scopes: %w[read])
      g.revoke!(reason: "test")
      g
    end

    it "does not hand a read-only operator any grant's live bearer token" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      grants = json_response_data["grants"]

      # ABSENCE — neither under the old misleading key nor an honest one, and
      # not as a value smuggled under some other key either. The body scan is
      # the assertion that survives a rename.
      grants.each do |g|
        expect(g.key?("bearer_token_preview")).to be(false),
          "a listed grant carries a bearer token under the misleading 'preview' key"
        expect(g.key?("bearer_token")).to be(false),
          "a listed grant carries a bearer token"
      end
      [ active_grant, revoked_grant ].each do |grant|
        token = grant.bearer_token
        # Guard the oracle itself: if the server secret were unavailable,
        # #bearer_token is nil and a body scan for nil would be vacuous.
        expect(token).to be_present
        expect(response.body.include?(token)).to be(false),
          "the grants list response carries a live federation bearer token"
      end

      # POSITIVE — the list is still fully useful for its actual job.
      expect(grants.length).to eq(2)
      expect(grants.map { |g| g["lifecycle"] }.sort).to eq(%w[active revoked])
      expect(grants.map { |g| g["id"] }).to match_array([ active_grant.id, revoked_grant.id ])
      expect(grants.first).to include("remote_subject", "resource_kind", "permission_scopes",
                                      "issued_at", "expires_at", "unrestricted")
    end
  end

  describe "POST /grants (system.peers.manage) — the legitimate reveal" do
    it "returns the bearer token exactly at issuance, under an honest key" do
      post base,
           params: { resource_kind: "skill", remote_subject: "bob@b.example.org",
                     permission_scopes: %w[read] },
           headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:created)

      grant_json = json_response_data["grant"]
      created = ::System::FederationGrant.find(grant_json["id"])

      # POSITIVE — the reveal still happens. Removing it would strand the
      # operator: this is the only moment the credential is handed over.
      #
      # Compared as DIGESTS, not as values: `eq`/`start_with` would print the
      # actual token in an RSpec failure message. It is a test-env credential,
      # but an oracle for a disclosure defect should not be the thing that
      # prints one.
      revealed = grant_json["bearer_token"]
      expect(revealed).to be_present
      expect(::Digest::SHA256.hexdigest(revealed.to_s))
        .to eq(::Digest::SHA256.hexdigest(created.bearer_token.to_s))
      expect(revealed.to_s.start_with?("fgs.")).to be(true),
        "the issued bearer token does not carry the signed-envelope prefix"

      # ...and the misleading name is gone. A "preview" key holding a full
      # credential invites a reader to treat it as safe to log or display.
      expect(grant_json.key?("bearer_token_preview")).to be(false),
        "the issuance response still uses the misleading 'preview' key"
    end
  end

  describe "POST /grants/:id/revoke" do
    let!(:grant) do
      create(:system_federation_grant, account: account, federation_peer: peer,
                                       remote_subject: "carol@b.example.org",
                                       resource_kind: "skill")
    end

    it "does not re-emit the credential of the grant it just revoked" do
      post "#{base}/#{grant.id}/revoke", params: { reason: "operator" },
                                         headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:ok)

      data = json_response_data["grant"]
      expect(data.key?("bearer_token_preview")).to be(false),
        "the revoke response carries a bearer token under the misleading 'preview' key"
      expect(data.key?("bearer_token")).to be(false),
        "the revoke response carries a bearer token"
      token = grant.bearer_token
      expect(token).to be_present
      expect(response.body.include?(token)).to be(false),
        "the revoke response carries the revoked grant's bearer token"

      # POSITIVE — the revoke still reports the outcome the operator needs.
      expect(data["lifecycle"]).to eq("revoked")
      expect(data["revocation_reason"]).to eq("operator")
      expect(data["revoked_at"]).to be_present
    end
  end
end
