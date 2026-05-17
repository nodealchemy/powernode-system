# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §G + §I + P7.3.
RSpec.describe "Api::V1::System::Platform::Deployments", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.platform.read", account: account) }
  let(:scaler)  { user_with_permissions("system.platform.read", "system.platform.scale", account: account) }
  let(:base)    { "/api/v1/system/platform/deployments" }

  describe "GET /deployments" do
    let!(:dep_a) { create(:system_platform_deployment, account: account, name: "api-tier", service_role: "api") }
    let!(:dep_b) { create(:system_platform_deployment, account: account, name: "worker-tier", service_role: "worker") }
    let!(:other) { create(:system_platform_deployment, account: create(:account)) }

    it "lists this account's deployments only with computed actual_replicas" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data
      expect(data["count"]).to eq(2)
      names = data["deployments"].map { |d| d["name"] }
      expect(names).to contain_exactly("api-tier", "worker-tier")
      expect(data["deployments"].first).to include("actual_replicas", "actual_by_status", "target_replicas")
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /deployments/:id" do
    let!(:dep) { create(:system_platform_deployment, account: account, name: "api-tier", target_replicas: 1) }

    it "updates target_replicas" do
      patch "#{base}/#{dep.id}", params: { target_replicas: 3 },
                                  headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response_data["deployment"]["target_replicas"]).to eq(3)
    end

    it "rejects negative target_replicas" do
      patch "#{base}/#{dep.id}", params: { target_replicas: -1 },
                                  headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects empty body" do
      patch "#{base}/#{dep.id}", params: {}, headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "forbids without scale permission" do
      patch "#{base}/#{dep.id}", params: { target_replicas: 2 },
                                  headers: auth_headers_for(reader), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
