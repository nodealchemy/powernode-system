# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2.5 (A2A) — node-facing advertisement of the
# account's capability-token signing public key(s). The agent pulls these to
# verify inbound peer capability tokens offline.
RSpec.describe "Api::V1::System::NodeApi::A2a#capability_keys", type: :request do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) } }

  def peer_for(inst, handle:, declared_skills: [], granted: [])
    System::NodeInstancePeer.create!(
      node_instance: inst, account: account, handle: "#{handle}-#{SecureRandom.hex(2)}",
      status: "active", enabled: true, trust_score: 0.5, daily_decision_budget: 10,
      declared_skills: declared_skills
    ).tap { |p| p.grant_peer_skills!(granted) if granted.any? }
  end

  describe "GET /api/v1/system/node_api/a2a/capability_keys" do
    it "advertises the account's active capability-signing public key(s)" do
      caller = create(:system_node_instance, account: account, status: "running")
      target = create(:system_node_instance, account: account, status: "running")
      peer_for(caller, handle: "c", granted: %w[embed-*])
      peer_for(target, handle: "t", declared_skills: [ { "name" => "embed-text" } ])
      System::PeerCapabilityTokenSigner.mint!(caller_instance: caller, target_instance: target, skill: "embed-text")

      get "/api/v1/system/node_api/a2a/capability_keys", headers: headers

      expect(response).to have_http_status(:ok)
      keys = JSON.parse(response.body).dig("data", "keys")
      expect(keys).to be_an(Array)
      expect(keys.first["public_key_b64"]).to be_present
      expect(keys.first["algorithm"]).to eq("ED25519")
    end

    it "401 without an instance cert" do
      get "/api/v1/system/node_api/a2a/capability_keys"
      expect(response).to have_http_status(:unauthorized)
    end

    # Audit F2-04 — the agent verifies tokens OFFLINE, so grant revocation /
    # peer-disable was silently ineffective: outstanding tokens stayed valid
    # until exp. The keys pull now carries the account's active revocations.
    context "revocation advertisement (F2-04)" do
      it "advertises revoked subs after a peer is disabled" do
        revoked = create(:system_node_instance, account: account, status: "running")
        peer = peer_for(revoked, handle: "rv", granted: %w[embed-*])

        peer.update!(enabled: false)

        get "/api/v1/system/node_api/a2a/capability_keys", headers: headers

        expect(response).to have_http_status(:ok)
        revocations = JSON.parse(response.body).dig("data", "revocations")
        expect(revocations).to be_a(Hash)
        expect(revocations["subs"]).to include(revoked.id)
      end

      it "advertises revoked subs after a peer's grants change" do
        regrant = create(:system_node_instance, account: account, status: "running")
        peer = peer_for(regrant, handle: "rg", granted: %w[embed-* summarize-*])

        peer.grant_peer_skills!(%w[embed-*]) # narrowed — outstanding tokens may exceed it

        get "/api/v1/system/node_api/a2a/capability_keys", headers: headers

        revocations = JSON.parse(response.body).dig("data", "revocations")
        expect(revocations["subs"]).to include(regrant.id)
      end

      it "does not advertise expired revocations" do
        revoked = create(:system_node_instance, account: account, status: "running")
        peer = peer_for(revoked, handle: "ex", granted: %w[embed-*])
        peer.update!(enabled: false)
        System::PeerCapabilityRevocation.where(account: account)
                                        .update_all(expires_at: 1.minute.ago)

        get "/api/v1/system/node_api/a2a/capability_keys", headers: headers

        revocations = JSON.parse(response.body).dig("data", "revocations")
        expect(revocations["subs"]).not_to include(revoked.id)
      end
    end
  end
end
