# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::ServiceOfferings", type: :request do
  let(:account) { create(:account) }
  let(:user) { user_with_permissions("system.service_offerings.read", "system.service_offerings.manage", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:base_path) { "/api/v1/system/federation/service_offerings" }

  describe "GET /service_offerings" do
    let!(:active_offering)     { create(:system_federation_service_offering, :active, account: account, slug: "gitea", name: "Hosted Git") }
    let!(:draft_offering)      { create(:system_federation_service_offering, account: account, slug: "draft-svc", name: "Draft") }
    let!(:other_account_offering) { create(:system_federation_service_offering, :active, account: create(:account), slug: "leak-test") }

    it "lists the operator's own offerings + scopes to current account" do
      get base_path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["data"]["offerings"].map { |o| o["slug"] }
      expect(slugs).to match_array([ "gitea", "draft-svc" ])
      expect(slugs).not_to include("leak-test")
    end

    it "filters by status when supplied" do
      get base_path, headers: headers, params: { status: "active" }
      slugs = JSON.parse(response.body)["data"]["offerings"].map { |o| o["slug"] }
      expect(slugs).to eq([ "gitea" ])
    end

    it "rejects requests without the read permission" do
      reader_only = create(:user, account: account)
      get base_path, headers: auth_headers_for(reader_only)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /service_offerings/:id" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: account, slug: "gitea") }

    it "returns the offering with full detail" do
      get "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["offering"]["slug"]).to eq("gitea")
      expect(body["data"]["offering"]).to have_key("description_markdown")
      expect(body["data"]["offering"]).to have_key("metadata")
    end

    it "404 for offering in a different account" do
      other_offering = create(:system_federation_service_offering, account: create(:account))
      get "#{base_path}/#{other_offering.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /service_offerings" do
    let(:create_payload) do
      {
        slug: "managed-pg",
        name: "Managed Postgres",
        protocol: "tcp",
        backend_host: "pg-backend.example.com",
        backend_port: 5432,
        default_grant_ttl_days: 30,
        default_grant_scopes: %w[read write]
      }
    end

    it "creates an offering in draft status" do
      post base_path, params: create_payload.to_json, headers: headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["data"]["offering"]["slug"]).to eq("managed-pg")
      expect(body["data"]["offering"]["status"]).to eq("draft")
    end

    it "422 on validation failure (invalid slug)" do
      post base_path, params: create_payload.merge(slug: "Bad Slug").to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects without manage permission" do
      reader_user = user_with_permissions("system.service_offerings.read", account: account)
      post base_path, params: create_payload.to_json, headers: auth_headers_for(reader_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /service_offerings/:id" do
    let!(:offering) { create(:system_federation_service_offering, account: account, slug: "gitea", name: "Original") }

    it "updates allowed fields" do
      patch "#{base_path}/#{offering.id}",
            params: { name: "Renamed Gitea", default_grant_ttl_days: 60 }.to_json,
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.name).to eq("Renamed Gitea")
      expect(offering.default_grant_ttl_days).to eq(60)
    end

    it "ignores slug changes (slug is the stable identifier)" do
      patch "#{base_path}/#{offering.id}",
            params: { slug: "new-slug" }.to_json,
            headers: headers
      expect(offering.reload.slug).to eq("gitea")
    end
  end

  describe "POST /:id/activate + /deprecate + /retire" do
    let!(:offering) { create(:system_federation_service_offering, account: account, slug: "gitea") }

    it "activate transitions draft → active" do
      post "#{base_path}/#{offering.id}/activate", headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.status).to eq("active")
    end

    it "deprecate transitions active → deprecated with reason" do
      offering.activate!
      post "#{base_path}/#{offering.id}/deprecate",
           params: { reason: "replaced by v2" }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      offering.reload
      expect(offering.status).to eq("deprecated")
      expect(offering.metadata["deprecation_reason"]).to include("v2")
    end

    it "retire is terminal" do
      offering.activate!
      post "#{base_path}/#{offering.id}/retire", headers: headers
      expect(response).to have_http_status(:ok)
      offering.reload
      expect(offering.status).to eq("retired")
      expect(offering.terminal?).to be true
    end

    it "422 when trying to activate a retired offering" do
      offering.update!(status: "retired", retired_at: 1.day.ago)
      post "#{base_path}/#{offering.id}/activate", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE /service_offerings/:id (= retire)" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

    it "retires the offering (soft delete)" do
      delete "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.status).to eq("retired")
    end

    it "409 when already retired" do
      offering.update!(status: "retired", retired_at: 1.day.ago)
      delete "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end
end
