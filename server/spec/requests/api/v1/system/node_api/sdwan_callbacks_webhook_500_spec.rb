# frozen_string_literal: true

require "rails_helper"

# webhook-500 regression for the node_api SDWAN agent callbacks. The agent POSTs
# to these on every heartbeat/tick and retries on failure, so a 500 from a
# malformed (#report) or concurrent (#report_bgp) payload becomes a retry storm.
RSpec.describe "Api::V1::System::NodeApi::Sdwan callbacks (webhook-500)", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, :running, node: node) }
  let(:network)       { create(:sdwan_network, account: account) }
  let!(:peer)         { create(:sdwan_peer, account: account, network: network, node_instance: instance) }

  let!(:cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}", not_before: 1.hour.ago,
      not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end
  let(:auth) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")),
      "Content-Type" => "application/json" }
  end

  describe "POST /api/v1/system/node_api/status/sdwan" do
    it "skips a non-object peers element instead of raising TypeError (no 500)" do
      post "/api/v1/system/node_api/status/sdwan",
           params: { peers: [ "not-an-object",
                              { peer_id: peer.id, last_handshake_at: Time.current.iso8601 } ] }.to_json,
           headers: auth

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "reported")).to eq(1)
    end
  end

  describe Sdwan::BgpSessionWriter do
    it "recovers from a concurrent insert (RecordNotUnique) instead of raising 500" do
      # Inside the network's own /64: IMP-2f34679b6b73 made the writer refuse
      # a neighbour address that cannot belong to the reporting network, and
      # the subject here is the RecordNotUnique recovery, not attribution.
      neighbor = "#{network.cidr_64.split('/').first}9"
      # The row a concurrent agent tick already inserted for (peer, neighbor).
      existing = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer.id, sdwan_network_id: network.id,
        neighbor_address: neighbor, state: "idle",
        uptime_seconds: 0, prefixes_received: 0, prefixes_sent: 0,
        last_observed_at: Time.current, last_state_change_at: Time.current
      )

      # Force the writer's initial find_by to MISS so it takes the create! path
      # and hits the (sdwan_peer_id, neighbor_address) unique index; the recovery
      # find_by then returns the winner row.
      allow(Sdwan::BgpSession).to receive(:find_by).and_call_original
      allow(Sdwan::BgpSession).to receive(:find_by)
        .with(sdwan_peer_id: peer.id, neighbor_address: neighbor)
        .and_return(nil, existing)

      writer = Sdwan::BgpSessionWriter.new(
        instance: instance,
        peer_by_network: { network.id => peer },
        networks_payload: [ { network_id: network.id,
                              sessions: [ { neighbor_address: neighbor, state: "established" } ] } ]
      )

      expect { writer.write! }.not_to raise_error
      expect(existing.reload.state).to eq("established")
    end
  end

  # IMP-2f34679b6b73 — the writer distinguishes a LEGACY agent (no `measured`
  # key at all) from one that explicitly disclaimed the measurement. Every
  # unit spec hands it plain symbol-keyed Hashes; the production caller hands
  # it ActionController::Parameters. Exercise the distinction through the real
  # controller, which is the only place the difference could break.
  describe "POST /api/v1/system/node_api/status/bgp" do
    def post_bgp(network_payload)
      post "/api/v1/system/node_api/status/bgp",
           params: { networks: [ network_payload ] }.to_json, headers: auth
    end

    def observation
      peer.reload.bgp_session_state["observation"]
    end

    it "records an explicit measured:false as not_measured, with the agent's reason" do
      post_bgp(network_id: network.id, measured: false,
               not_measured_reason: "vrf_scope_unconfirmed", sessions: [])

      expect(response).to have_http_status(:ok)
      expect(observation["status"]).to eq("not_measured")
      expect(observation["reason"]).to eq("vrf_scope_unconfirmed")
      expect(observation["agent_vrf_scoped"]).to be(true)
    end

    it "records an explicit measured:true with no sessions as a real zero" do
      post_bgp(network_id: network.id, measured: true, sessions: [])

      expect(response).to have_http_status(:ok)
      expect(observation["status"]).to eq("measured")
      expect(observation["sessions_accepted"]).to eq(0)
      expect(observation["agent_vrf_scoped"]).to be(true)
    end

    it "marks a report with no measured key at all as coming from an unscoped agent" do
      post_bgp(network_id: network.id, sessions: [])

      expect(response).to have_http_status(:ok)
      expect(observation["agent_vrf_scoped"]).to be(false)
    end
  end
end
