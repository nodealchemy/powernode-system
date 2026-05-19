# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for autonomy.
#
# Singular resource: GET /api/v1/system/autonomy + PATCH /api/v1/system/autonomy
# (no :id). Read gated by system.infra_tasks.read; update by
# system.infra_tasks.control. Logic lives in the AutonomyActions concern; the
# controller just gates permissions.
RSpec.describe "Api::V1::System::Autonomy", type: :request do
  let(:account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.infra_tasks.read",    account: account) }
  let(:manage_user) { user_with_permissions("system.infra_tasks.control", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  describe "GET /api/v1/system/autonomy" do
    it "returns 401 without auth" do
      get "/api/v1/system/autonomy"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/autonomy", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the 3-pivot payload (by_action/by_agent/by_domain)" do
      get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      data = json_response_data
      expect(data).to have_key("agents")
      expect(data).to have_key("chains")
      expect(data).to have_key("policies")
      expect(data["policies"]).to have_key("by_action")
      expect(data["policies"]).to have_key("by_agent")
      expect(data["policies"]).to have_key("by_domain")
    end
  end

  describe "PATCH /api/v1/system/autonomy" do
    it "returns 403 without control perm" do
      patch "/api/v1/system/autonomy",
            params: { updates: [] }.to_json,
            headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 400 when updates is missing" do
      patch "/api/v1/system/autonomy",
            params: {}.to_json,
            headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end
  end
end
