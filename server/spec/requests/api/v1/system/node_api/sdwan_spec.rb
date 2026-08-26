# frozen_string_literal: true

require "rails_helper"

# Coverage for the agent-facing node_api SDWAN controller:
#   GET  /api/v1/system/node_api/config/sdwan   (#show_config — pull desired state)
#   POST /api/v1/system/node_api/status/sdwan   (#report      — push tunnel state)
#   POST /api/v1/system/node_api/status/bgp     (#report_bgp  — push BGP sessions)
#
# Security-critical and previously untested: #show_config egresses the WireGuard
# PRIVATE key (include_private_key: true), scoped only by node_instance_id — so
# the cross-instance isolation property (instance A must never receive instance
# B's peers/keys) had no regression guard. This pins that isolation plus the
# per-instance scoping of both write paths. Auth mirrors the mTLS instance
# identity header used by config_authorized_keys_spec.
RSpec.describe "Api::V1::System::NodeApi::Sdwan", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  # Instance A — the authenticated caller — with its own peer + network.
  let(:node_a)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:network_a)  { create(:sdwan_network, account: account) }
  let!(:peer_a)    { create(:sdwan_peer, account: account, network: network_a, node_instance: instance_a) }

  # Instance B — a different instance in the same account — whose peer/network
  # must never be visible to A.
  let(:node_b)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:network_b)  { create(:sdwan_network, account: account) }
  let!(:peer_b)    { create(:sdwan_peer, account: account, network: network_b, node_instance: instance_b) }

  let!(:cert_a) do
    System::NodeCertificate.create!(
      node_instance: instance_a,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance_a.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:auth_headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance_a.id}")) }
  end

  def data
    JSON.parse(response.body)["data"]
  end

  describe "GET /api/v1/system/node_api/config/sdwan" do
    it "returns 401 without instance auth" do
      get "/api/v1/system/node_api/config/sdwan"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for an unknown instance subject" do
      get "/api/v1/system/node_api/config/sdwan",
          headers: { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{SecureRandom.uuid}")) }
      expect(response).to have_http_status(:unauthorized)
    end

    it "egresses only the authenticated instance's keys (cross-instance key isolation)" do
      # Both peers get real WireGuard keys; only A's may ever reach A.
      Sdwan::KeyDistributor.ensure_key_for!(peer_a)
      Sdwan::KeyDistributor.ensure_key_for!(peer_b)
      key_a = peer_a.reload.active_key
      key_b = peer_b.reload.active_key

      get "/api/v1/system/node_api/config/sdwan", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(data["instance_id"]).to eq(instance_a.id)

      network_ids = data["networks"].map { |n| n["network_id"] }
      expect(network_ids).to contain_exactly(network_a.id)
      expect(network_ids).not_to include(network_b.id)

      # The endpoint exists to hand the agent its OWN private key...
      view = data["networks"].first
      expect(view.dig("interface", "private_key")).to be_present
      expect(response.body).to include(key_a.public_key)

      # ...but instance B's key material + identifiers must NEVER appear.
      expect(response.body).not_to include(key_b.public_key)
      expect(response.body).not_to include(peer_b.id)
    end
  end

  describe "POST /api/v1/system/node_api/status/sdwan" do
    it "updates only the caller's own peers and ignores peers owned by another instance" do
      ts = 2.minutes.ago.change(usec: 0)

      post "/api/v1/system/node_api/status/sdwan",
           params: { peers: [
             { peer_id: peer_a.id, last_handshake_at: ts.iso8601 },
             { peer_id: peer_b.id, last_handshake_at: ts.iso8601 } # B's peer — must be ignored
           ] }.to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      expect(peer_a.reload.last_handshake_at).to be_within(1.second).of(ts)
      expect(peer_b.reload.last_handshake_at).to be_nil
    end
  end

  describe "POST /api/v1/system/node_api/status/bgp" do
    it "upserts BGP sessions for the caller's network and skips networks it does not own" do
      # Sdwan::BgpSessionWriter only accepts a session whose neighbor_address
      # falls inside the REPORTING network's own cidr_64 prefix (see
      # #attributable_to?); a fixed literal address only happened to satisfy
      # that when this was the first :sdwan_network built in the process
      # (factory sequence n=1 => cidr_64 "fd00:abcd:0001::/64"). With other
      # examples in this file also creating networks first, the sequence has
      # moved on and the literal falls outside the real prefix, so the writer
      # correctly (and silently) treats it as unattributable and skips the
      # write. Derive the address from each network's actual prefix instead.
      payload = { networks: [
        { network_id: network_a.id,
          sessions: [ { neighbor_address: "#{network_a.cidr_64.split('/').first}99", state: "established" } ] },
        { network_id: network_b.id,
          sessions: [ { neighbor_address: "#{network_b.cidr_64.split('/').first}99", state: "established" } ] } # not A's
      ] }

      expect {
        post "/api/v1/system/node_api/status/bgp",
             params: payload.to_json,
             headers: auth_headers.merge("Content-Type" => "application/json")
      }.to change { Sdwan::BgpSession.where(sdwan_peer_id: peer_a.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      # No session written against B's peer (A does not own network_b).
      expect(Sdwan::BgpSession.where(sdwan_peer_id: peer_b.id).count).to eq(0)
    end
  end
end
