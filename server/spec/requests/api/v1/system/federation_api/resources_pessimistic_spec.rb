# frozen_string_literal: true

require "rails_helper"

# Covers P4.5.5 — pessimistic auth chain extensions on
# FederationApi::BaseController#authorize_grant!:
#   - X-Calling-Instance header must match grant.node_instance_ids
#     (when populated)
#   - X-Sdwan-Network header must match grant.sdwan_network_ids AND
#     correspond to an active FederationNetworkBridge
#   - request.remote_ip must fall in grant.source_cidrs (when populated)
#
# Back-compat verified separately: a grant with all three allowlists
# empty matches regardless of supplied headers (covered in
# resources_spec.rb).
RSpec.describe "Api::V1::System::FederationApi::Resources pessimistic checks",
                type: :request do
  let(:account) { create(:account) }
  let(:grantor) { create(:user, account: account) }
  let(:cert) do
    ::System::NodeCertificate.create!(
      account: account, subject_kind: "federation_peer",
      subject: "federation-peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: 1.day.ago, not_after: 180.days.from_now,
      pem_chain: "stub", issuer_subject: "Powernode Internal CA"
    )
  end
  let(:peer) do
    create(:system_federation_peer, :active,
           account: account, node_certificate: cert)
  end
  let(:network) { create(:sdwan_network, account: account) }
  let!(:active_bridge) do
    create(:system_federation_network_bridge, :active,
           account: account, federation_peer: peer, sdwan_network: network)
  end

  before do
    fake_registry = System::Federation::InventoryRegistry.new
    fake_registry.register_kind(
      System::Federation::InventoryRegistry::Kind.new(
        extension: "demo", kind: "skill", dependencies: [], duplicable: true,
        migratable: false, metadata: {}
      )
    )
    System::Federation::InventoryRegistry.install_test_double(fake_registry)
  end

  after { System::Federation::InventoryRegistry.install_test_double(nil) }

  let(:resource_uuid) { SecureRandom.uuid }
  let(:path)          { "/api/v1/system/federation_api/resources/skill/#{resource_uuid}" }

  let(:mtls_headers) { { "SSL_CLIENT_S_DN_CN" => cert.id } }

  let(:calling_instance_uuid) { SecureRandom.uuid }
  let(:full_headers) do
    mtls_headers.merge(
      "X-Calling-Instance" => calling_instance_uuid,
      "X-Sdwan-Network"    => network.id,
      "REMOTE_ADDR"        => "10.0.0.42"
    )
  end

  def make_grant(scopes: %w[read], **scope_attrs)
    create(:system_federation_grant,
           account: account, federation_peer: peer,
           grantor_user: grantor,
           remote_subject: "bob@b",
           resource_kind: "skill",
           resource_id: resource_uuid,
           permission_scopes: scopes,
           **scope_attrs)
  end

  describe "all-axes match → 200" do
    it "passes when every populated allowlist matches the calling context" do
      grant = make_grant(
        node_instance_ids: [ calling_instance_uuid ],
        sdwan_network_ids: [ network.id ],
        source_cidrs: %w[10.0.0.0/24]
      )

      get path, headers: full_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "instance mismatch → 403" do
    it "denies when X-Calling-Instance is not in the allowlist" do
      grant = make_grant(node_instance_ids: [ "different-instance-#{SecureRandom.uuid}" ])

      get path, headers: full_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("NodeInstance")
    end

    it "denies when X-Calling-Instance header is absent but allowlist is populated" do
      grant = make_grant(node_instance_ids: [ calling_instance_uuid ])

      get path, headers: mtls_headers
        .merge("Authorization" => "Bearer #{grant.bearer_token}",
               "X-Sdwan-Network" => network.id,
               "REMOTE_ADDR" => "10.0.0.42")
        # no X-Calling-Instance

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "network mismatch → 403" do
    it "denies when X-Sdwan-Network is not in the allowlist" do
      other_network = create(:sdwan_network, account: account)
      create(:system_federation_network_bridge, :active,
             account: account, federation_peer: peer, sdwan_network: other_network)

      grant = make_grant(sdwan_network_ids: [ other_network.id ])

      get path, headers: full_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("SDWAN network")
    end

    it "denies when the supplied network has no active bridge" do
      orphan_network = create(:sdwan_network, account: account)
      # No bridge for this network — request is forged
      grant = make_grant(sdwan_network_ids: [ orphan_network.id ])

      headers = full_headers
        .merge("Authorization" => "Bearer #{grant.bearer_token}",
               "X-Sdwan-Network" => orphan_network.id)

      get path, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("active FederationNetworkBridge")
    end

    it "denies when the bridge exists but is suspended" do
      active_bridge.suspend!(reason: "test")
      grant = make_grant(sdwan_network_ids: [ network.id ])

      get path, headers: full_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("active FederationNetworkBridge")
    end
  end

  describe "source CIDR mismatch → 403" do
    it "denies when remote IP is not in any CIDR" do
      grant = make_grant(source_cidrs: %w[192.168.1.0/24])

      headers = full_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      # REMOTE_ADDR is 10.0.0.42 from full_headers — outside 192.168.1.0/24

      get path, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("CIDR")
    end
  end

  describe "back-compat: empty allowlists stay permissive" do
    it "allows when grant has no scope restrictions even with no headers" do
      grant = make_grant
        # all allowlists empty — defaults from factory

      get path, headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
        # no X-Calling-Instance, no X-Sdwan-Network

      expect(response).to have_http_status(:ok)
    end
  end
end
