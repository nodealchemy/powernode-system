# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block H2 — NetbootController request spec.
RSpec.describe "Api::V1::System::NetbootController", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:user) { user_with_permissions("system.instances.create", account: account) }

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
        expect(response.status).to be_in([401, 403])
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
