# frozen_string_literal: true

require "rails_helper"

# IMP-ab73cc2fca65 — the READ half of the WireGuard byte-counter lane.
#
# Persisting two columns is not a metric. The node_api heartbeat now writes
# rx_bytes / tx_bytes / counters_sampled_at, and this file pins that the two
# surfaces which actually publish a peer BOTH emit them, and both preserve the
# NOT MEASURED vs MEASURED-ZERO distinction on the way out:
#
#   REST  GET /api/v1/system/sdwan/networks/:network_id/peers[/:id]
#         (Api::V1::System::Sdwan::PeersController#serialize_peer) — the route
#         the operator UI's sdwanApi.getPeers drives.
#   MCP   system_sdwan_list_peers / system_sdwan_get_peer
#         (Ai::Tools::SdwanTool#serialize_peer) — the agent-facing surface.
#
# Both are hand-maintained literal whitelists, so a column the heartbeat writes
# is invisible on either surface until it is named there. That is exactly how a
# measured signal ends up dark, and it is why the property under test is
# "the value reaches the caller", not "the model has a method".
#
# nil is asserted as nil DELIBERATELY. Coercing an unmeasured counter to 0
# would make every never-reported peer indistinguishable from an idle one, and
# an idle WireGuard tunnel genuinely reports 0.
RSpec.describe "SDWAN peer observed-traffic surfaces", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.sdwan.peers.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:tool)    { ::Ai::Tools::SdwanTool.new(account: account, internal: true) }

  # NOT MEASURED — no heartbeat has ever carried a usable counter pair.
  let!(:unmeasured_peer) { create(:sdwan_peer, account: account, network: network) }

  # MEASURED, and idle: a real observation of zero traffic.
  let!(:idle_peer) do
    create(:sdwan_peer, account: account, network: network,
                        rx_bytes: 0, tx_bytes: 0, counters_sampled_at: 90.seconds.ago)
  end

  # MEASURED, carrying traffic.
  let!(:busy_peer) do
    create(:sdwan_peer, account: account, network: network,
                        rx_bytes: 12_884_901_888, tx_bytes: 4_096, counters_sampled_at: 30.seconds.ago)
  end

  # Fetch helpers are methods: each reads the surface fresh rather than pinning
  # one memoized response that a later example would silently reuse.
  def rest_list
    get "/api/v1/system/sdwan/networks/#{network.id}/peers",
        headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).dig("data", "peers").index_by { |p| p["id"] }
  end

  def rest_show(peer)
    get "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}",
        headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).dig("data", "peer")
  end

  def mcp_list
    result = tool.execute(params: { action: "system_sdwan_list_peers", network_id: network.id })
    expect(result[:success]).to be(true), "MCP list_peers failed: #{result[:error]}"
    result.dig(:data, :peers).index_by { |p| p[:id] }
  end

  def mcp_show(peer)
    result = tool.execute(params: { action: "system_sdwan_get_peer", peer_id: peer.id })
    expect(result[:success]).to be(true), "MCP get_peer failed: #{result[:error]}"
    result.dig(:data, :peer)
  end

  shared_examples "publishes observed traffic" do
    it "publishes nil — not 0 — for a peer that has never been sampled" do
      view = fetch(unmeasured_peer)

      expect(view).to include(key(:rx_bytes))
      expect(view[key(:rx_bytes)]).to be_nil
      expect(view[key(:tx_bytes)]).to be_nil
      expect(view[key(:counters_sampled_at)]).to be_nil
    end

    it "publishes an explicit 0 for a sampled idle peer, distinct from never-sampled" do
      view = fetch(idle_peer)

      expect(view[key(:rx_bytes)]).to eq(0)
      expect(view[key(:tx_bytes)]).to eq(0)
      expect(view[key(:counters_sampled_at)]).to be_present
    end

    it "publishes the raw cumulative counters for a peer carrying traffic" do
      view = fetch(busy_peer)

      expect(view[key(:rx_bytes)]).to eq(12_884_901_888)
      expect(view[key(:tx_bytes)]).to eq(4_096)
      expect(view[key(:counters_sampled_at)]).to be_present
    end
  end

  describe "REST list" do
    def key(name) = name.to_s
    def fetch(peer) = rest_list.fetch(peer.id)
    include_examples "publishes observed traffic"
  end

  describe "REST show" do
    def key(name) = name.to_s
    def fetch(peer) = rest_show(peer)
    include_examples "publishes observed traffic"
  end

  describe "MCP list_peers" do
    def key(name) = name
    def fetch(peer) = mcp_list.fetch(peer.id)
    include_examples "publishes observed traffic"
  end

  describe "MCP get_peer" do
    def key(name) = name
    def fetch(peer) = mcp_show(peer)
    include_examples "publishes observed traffic"
  end
end
