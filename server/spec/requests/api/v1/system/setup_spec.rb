# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Setup", type: :request do
  let(:account) { create(:account) }
  let(:admin)   { user_with_permissions("system.admin", account: account) }
  let(:regular) { user_with_permissions("system.acme.read", account: account) }

  describe "POST /api/v1/system/setup/defaults" do
    it "persists the default region for a system admin" do
      post "/api/v1/system/setup/defaults",
           params: { default_region: "us-west-2" }, headers: auth_headers_for(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(AdminSetting.get("system.default_region")).to eq("us-west-2")
    end

    it "ignores a blank region (optional step)" do
      post "/api/v1/system/setup/defaults",
           params: {}, headers: auth_headers_for(admin), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "forbids a user without system.admin" do
      post "/api/v1/system/setup/defaults",
           params: { default_region: "us-west-2" }, headers: auth_headers_for(regular), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
