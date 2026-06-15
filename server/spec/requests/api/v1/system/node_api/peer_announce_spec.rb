# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2.5 (A2A) — node-facing peer announcement. The agent
# POSTs its offered A2A skills + reachable addresses; the platform records them on
# the instance's NodeInstancePeer so discover_peers can surface it. Closes the
# discovery loop: the daemon offers skills, the platform learns them.
RSpec.describe "Api::V1::System::NodeApi::Peer#announce", type: :request do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")),
      "Content-Type" => "application/json" }
  end

  def announce(body, hdrs = headers)
    post "/api/v1/system/node_api/peer/announce", params: body.to_json, headers: hdrs
  end

  describe "POST /api/v1/system/node_api/peer/announce" do
    it "records the announced skills + addresses on the instance's peer" do
      announce(capabilities: { "os" => "linux", "inference" => true },
               skills: %w[ping inference.generate inference.models],
               addresses: [ "[fd00::2]:7777" ])

      expect(response).to have_http_status(:ok)
      peer = System::NodeInstancePeer.find_by(node_instance: instance)
      expect(peer).to be_present
      expect(peer.offered_skill_names).to include("inference.generate", "inference.models")
      expect(peer.addresses_array).to include("[fd00::2]:7777")
      expect(peer.status).to eq("active")
    end

    it "is idempotent — a second announce updates the same peer" do
      2.times { announce(capabilities: { "os" => "linux" }, skills: %w[ping], addresses: []) }
      expect(response).to have_http_status(:ok)
      expect(System::NodeInstancePeer.where(node_instance: instance).count).to eq(1)
    end

    it "401 without an instance cert" do
      announce({ skills: %w[ping] }, "Content-Type" => "application/json")
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
