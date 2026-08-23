# frozen_string_literal: true

require "rails_helper"

# Read-parity coverage for the federation governance scan (IMP-65f479ad8484).
#
# The operator console used to re-implement TWO of the scanner's finding kinds
# client-side while MCP (system_sdwan_federation_scan) served the full
# Sdwan::FederationGovernance scan — so an operator saw "no findings" where an
# agent saw high-severity ones. This endpoint is the single server-side scanner
# behind both surfaces.
#
# Governance findings expose peer status, prefixes and remote instance URLs
# across the whole account, so the endpoint is gated on the same permission the
# sibling federation READ endpoints use (system.sdwan.federation.read) and is
# account-scoped exactly as the MCP arm scopes it.
RSpec.describe "Api::V1::System::Sdwan::FederationGovernance", type: :request do
  let(:account)  { create(:account) }
  let(:reader)   { user_with_permissions("system.sdwan.federation.read", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }

  let(:path) { "/api/v1/system/sdwan/federation_governance/scan" }

  describe "GET /api/v1/system/sdwan/federation_governance/scan" do
    it "forbids callers without the federation read permission" do
      get path, headers: auth_headers_for(stranger)
      expect(response).to have_http_status(:forbidden)
    end

    # Read from the MCP permission map rather than restated, so moving the MCP
    # arm to a different permission cannot silently leave this surface wider.
    it "gates on the SAME permission the MCP arm gates on" do
      mcp_permission =
        ::Ai::Tools::SdwanTool::ACTION_PERMISSIONS.fetch("system_sdwan_federation_scan")
      gated = user_with_permissions(mcp_permission, account: account)

      get path, headers: auth_headers_for(gated)

      expect(response).to have_http_status(:ok)
    end

    it "serves the SERVER scanner's findings, not the console's two-kind subset" do
      # prefix_overlap_with_install is one of the ~13 kinds the server scanner
      # emits and the client stub never could — it needs Sdwan::Configuration.
      # No factory exists for Sdwan::Configuration (specs build it inline).
      ::Sdwan::Configuration.where(account_id: account.id).delete_all
      ::Sdwan::Configuration.create!(account: account,
                                     instance_prefix_40: "fd00:dead:beef::/40",
                                     account_prefix_48: "fd00:dead:beef::/48")
      create(:system_federation_peer, account: account,
             remote_prefix_advertisement: "fd00:dead:beef::/48")

      get path, headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      kinds = json_response_data["findings"].map { |f| f["kind"] }
      expect(kinds).to include("prefix_overlap_with_install")
    end

    # Asserted against the MCP arm itself, not against a copy of its key list:
    # the defect this endpoint fixes was two surfaces drifting apart, so a spec
    # that hardcodes the shape could stay green through exactly that drift.
    it "returns byte-for-byte what the MCP arm returns, for the same account" do
      create(:system_federation_peer, account: account, expires_at: 2.days.ago)
      create(:system_federation_peer, account: account, status: "accepted", signed_at: nil)

      mcp = ::Ai::Tools::SdwanTool.new(account: account, internal: true)
                                  .execute(params: { action: "system_sdwan_federation_scan" })
      expect(mcp[:success]).to be(true), "MCP arm failed: #{mcp[:error]}"

      get path, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      rest = json_response_data
      # Round-trip the MCP payload through JSON so Symbol keys/values are
      # compared on the same footing as the rendered response.
      mcp_data = JSON.parse(mcp[:data].to_json)

      expect(rest.keys).to match_array(mcp_data.keys)
      expect(rest["findings"]).to eq(mcp_data["findings"])
      expect(rest["finding_count"]).to eq(mcp_data["finding_count"])
      expect(rest["severity_summary"]).to eq(mcp_data["severity_summary"])
    end

    # Pins the JSON projection of one finding: severity and the summary keys are
    # Ruby Symbols on the way out, and the console's TS union expects strings.
    it "projects a finding as the TS SdwanFederationFinding shape" do
      peer = create(:system_federation_peer, account: account, expires_at: 2.days.ago)

      get path, headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      data = json_response_data

      finding = data["findings"].find { |f| f["kind"] == "expired_trust_jwt" }
      expect(finding).to be_present
      expect(finding.keys).to match_array(%w[kind severity federation_peer_id message payload])
      expect(finding["severity"]).to eq("high")
      expect(finding["federation_peer_id"]).to eq(peer.id)
      expect(finding["message"]).to be_present
      expect(finding["payload"]).to be_a(Hash)
      expect(data["severity_summary"]).to eq({ "high" => 1 })
      expect(data["finding_count"]).to eq(1)
    end

    # federation_peer_id is `string | null` in the TS type because the scanner
    # really does emit nil for it — proven here from the producer rather than
    # from a hand-written client fixture.
    it "emits a null federation_peer_id for a finding with no peer" do
      # No factory for a chain — composed, as the P9.5 service spec does.
      hop_peers = 2.times.map do
        ::System::FederationPeer.create!(
          account: account,
          remote_instance_url: "https://hop-#{SecureRandom.hex(4)}.example.com",
          peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
          status: "active"
        )
      end
      chain = ::System::Migrations::ChainComposer.compose!(
        account: account,
        hop_peer_ids: [ nil, *hop_peers.map(&:id) ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      ).chain
      chain.update!(status: "failed", failed_at: 1.hour.ago,
                    error_message: "destination refused the handoff")

      get path, headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      finding = json_response_data["findings"].find { |f| f["kind"] == "migration_chain_failed" }
      expect(finding).to be_present, "expected a migration_chain_failed finding for chain #{chain.id}"
      expect(finding).to have_key("federation_peer_id")
      expect(finding["federation_peer_id"]).to be_nil
    end

    it "never surfaces another account's peers (tenancy)" do
      foreign = create(:system_federation_peer, expires_at: 2.days.ago) # different account
      mine    = create(:system_federation_peer, account: account, expires_at: 2.days.ago)

      get path, headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      peer_ids = json_response_data["findings"].map { |f| f["federation_peer_id"] }
      expect(peer_ids).to include(mine.id)
      expect(peer_ids).not_to include(foreign.id)
    end
  end
end
