# frozen_string_literal: true

require "rails_helper"

# Trust-boundary coverage for the access-grant controller (previously zero
# request-spec coverage). An access grant is a VPN-access credential: every
# action requires sdwan.user_devices.manage, grants are scoped to the
# account-scoped network (cross-account / cross-network IDOR -> 404), and the
# revoke action (which cuts VPN access immediately) is approval-gated behind
# that permission.
RSpec.describe "Api::V1::System::Sdwan::AccessGrants", type: :request do
  let(:account)  { create(:account) }
  let(:manager)  { user_with_permissions("system.sdwan.user_devices.manage", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }
  let(:network)  { create(:sdwan_network, account: account) }

  describe "GET /api/v1/system/sdwan/networks/:network_id/access_grants" do
    it "forbids callers without sdwan.user_devices.manage" do
      get "/api/v1/system/sdwan/networks/#{network.id}/access_grants", headers: auth_headers_for(stranger)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a network in another account (IDOR guard)" do
      foreign_net = create(:sdwan_network) # different account

      get "/api/v1/system/sdwan/networks/#{foreign_net.id}/access_grants", headers: auth_headers_for(manager)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/system/sdwan/networks/:network_id/access_grants/:id" do
    it "404s for a grant that belongs to a different network (cross-network IDOR)" do
      other_net = create(:sdwan_network, account: account)
      grant     = create(:sdwan_access_grant, account: account, network: other_net)

      # Fetched under `network`, not its own `other_net` -> not found.
      get "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          headers: auth_headers_for(manager)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/sdwan/networks/:network_id/access_grants/:id/revoke" do
    it "requires sdwan.user_devices.manage (the approval-gated revoke is behind the permission)" do
      grant = create(:sdwan_access_grant, account: account, network: network)

      post "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}/revoke",
           headers: auth_headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
