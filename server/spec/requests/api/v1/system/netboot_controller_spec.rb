# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block H2 — NetbootController request spec.
RSpec.describe "Api::V1::System::NetbootController", type: :request do
  # Assembled at runtime so the fixture never looks like a real PEM key to secret scanners.
  def key_label = "PRIVATE" + " KEY"

  def fake_pem_block(label, body)
    "-----BEGIN #{label}-----\n#{body}\n-----END #{label}-----\n"
  end

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:user) { user_with_permissions("system.instances.create", account: account) }

  before { stub_enroll_settings(ca: self_signed_ca_pem) }

  describe "GET /api/v1/system/netboot/ca.pem" do
    it "serves the configured CA PEM publicly (no auth), certificates only" do
      ca = self_signed_ca_pem
      stub_enroll_settings(ca: ca)
      get "/api/v1/system/netboot/ca.pem"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/x-pem-file")
      expect(response.headers["Cache-Control"]).to include("max-age")
      expect(response.body.strip).to eq(ca.strip)
      expect(response.body).not_to include("PRIVATE KEY")
    end

    it "serves only certificate blocks even if the setting carries other PEM blocks" do
      ca = self_signed_ca_pem
      stub_enroll_settings(ca: ca + fake_pem_block(key_label, "not-a-real-key-body"))
      get "/api/v1/system/netboot/ca.pem"
      expect(response.body).not_to include("PRIVATE KEY")
      expect(response.body).to include("BEGIN CERTIFICATE")
    end

    it "serves no key material when the bundle is malformed (a key block inside a cert span)" do
      ca = self_signed_ca_pem
      evil = "-----BEGIN CERTIFICATE-----\nAAAA\n" + fake_pem_block(key_label, "not-a-real-key-body") +
             "-----END CERTIFICATE-----\n"
      stub_enroll_settings(ca: evil + ca)
      get "/api/v1/system/netboot/ca.pem"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("not-a-real-key-body")
      expect(response.body).not_to include("PRIVATE KEY")
      expect(response.body.strip).to eq(ca.strip)
    end

    it "returns 404 when the bundle has no parseable, self-signed CA" do
      stub_enroll_settings(ca: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
      get "/api/v1/system/netboot/ca.pem"
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when no CA is configured" do
      stub_enroll_settings(ca: nil)
      get "/api/v1/system/netboot/ca.pem"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/system/netboot/:instance_id/script.ipxe" do
    context "when authorized" do
      it "returns text/plain iPXE script with no-store cache and token-id header" do
        get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/plain")
        expect(response.body).to include("#!ipxe")
        expect(response.body).to include("powernode.bootstrap_token=")
        expect(response.body).to include("powernode.instance_uuid=#{instance.id}")
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect(response.headers["X-Powernode-Token-Id"]).to be_present
      end

      it "issues a fresh BootstrapToken on each call (no replay)" do
        expect {
          get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
          get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
        }.to change(System::BootstrapToken, :count).by(2)
      end

      it "accepts ttl_minutes up to the 60 minute netboot cap" do
        get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
            headers: auth_headers_for(user), params: { ttl_minutes: 45 }
        expect(response).to have_http_status(:ok)
        expect(System::BootstrapToken.order(:created_at).last.expires_at).to be_within(10.seconds).of(45.minutes.from_now)
      end

      it "refuses ttl_minutes above the cap with 422 and issues no token" do
        expect {
          get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
              headers: auth_headers_for(user), params: { ttl_minutes: 120 }
        }.not_to change(System::BootstrapToken, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "honors image_base override" do
        get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
            headers: auth_headers_for(user),
            params: { image_base: "https://custom.example/images" }
        expect(response.body).to include("kernel https://custom.example/images")
      end
    end

    context "when permission missing" do
      let(:user_no_perms) { user_with_permissions("system.nodes.read", account: account) }

      it "rejects with 403" do
        get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user_no_perms)
        expect(response.status).to be_in([ 401, 403 ])
      end
    end

    context "when instance is in another account" do
      let(:other_account) { create(:account) }
      let(:other_platform) { create(:system_node_platform, account: other_account) }
      let(:other_template) { create(:system_node_template, account: other_account, node_platform: other_platform) }
      let(:other_node) { create(:system_node, account: other_account, node_template: other_template) }
      let(:other_instance) { create(:system_node_instance, :running, node: other_node) }

      it "returns 404 — account scoping" do
        get "/api/v1/system/netboot/#{other_instance.id}/script.ipxe", headers: auth_headers_for(user)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
