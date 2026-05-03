# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P7.2 — verifies marketplace browse
# endpoints respect per-account scoping + permission gating.
RSpec.describe "GET /api/v1/system/marketplace", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.modules.read", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  before do
    @internal_module = create(:system_node_module, account: account, name: "internal-cache",
                              manifest_yaml: "trust_tier: internal\n")
    @verified_module = create(:system_node_module, account: account, name: "verified-nginx",
                              manifest_yaml: "trust_tier: verified-publisher\n")
    @community_module = create(:system_node_module, account: account, name: "community-tool",
                               manifest_yaml: "trust_tier: community\n")
    # Cross-tenant isolation guard
    @foreign_module = create(:system_node_module, account: other_account, name: "foreign-mystery",
                              manifest_yaml: "trust_tier: internal\n")
  end

  describe "GET index" do
    it "returns all modules in the operator's account" do
      get "/api/v1/system/marketplace", headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      names = body.dig("data", "modules").map { |m| m["name"] }
      expect(names).to include("internal-cache", "verified-nginx", "community-tool")
    end

    it "does NOT return modules from other accounts (cross-tenant isolation)" do
      get "/api/v1/system/marketplace", headers: headers
      names = JSON.parse(response.body).dig("data", "modules").map { |m| m["name"] }
      expect(names).not_to include("foreign-mystery")
    end

    it "filters by trust_tier" do
      get "/api/v1/system/marketplace?trust_tier=internal", headers: headers

      names = JSON.parse(response.body).dig("data", "modules").map { |m| m["name"] }
      expect(names).to include("internal-cache")
      expect(names).not_to include("verified-nginx", "community-tool")
    end

    it "filters by search substring on name" do
      get "/api/v1/system/marketplace?search=nginx", headers: headers

      names = JSON.parse(response.body).dig("data", "modules").map { |m| m["name"] }
      expect(names).to include("verified-nginx")
      expect(names).not_to include("internal-cache", "community-tool")
    end

    it "surfaces the trust tier on each card" do
      get "/api/v1/system/marketplace", headers: headers

      cards = JSON.parse(response.body).dig("data", "modules")
      internal = cards.find { |c| c["name"] == "internal-cache" }
      expect(internal["trust_tier"]).to eq("internal")
    end

    it "defaults trust_tier to 'community' when manifest doesn't declare one" do
      bare_module = create(:system_node_module, account: account, name: "bare-module",
                                                 manifest_yaml: nil)

      get "/api/v1/system/marketplace?search=bare", headers: headers
      card = JSON.parse(response.body).dig("data", "modules").find { |c| c["name"] == "bare-module" }
      expect(card["trust_tier"]).to eq("community")
    end

    it "rejects without system.modules.read permission" do
      no_perm = create(:user, account: account)
      no_perm_headers = auth_headers_for(no_perm).merge("Content-Type" => "application/json")

      get "/api/v1/system/marketplace", headers: no_perm_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET show" do
    it "returns full module detail + recent versions + dependencies" do
      version = create(:system_node_module_version, node_module: @internal_module, version_number: 1)

      get "/api/v1/system/marketplace/#{@internal_module.id}", headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body.dig("data", "module", "name")).to eq("internal-cache")
      expect(body.dig("data", "recent_versions").map { |v| v["id"] }).to include(version.id)
      expect(body.dig("data", "dependencies")).to be_an(Array)
    end

    it "404s for a foreign-account module (cross-tenant isolation)" do
      get "/api/v1/system/marketplace/#{@foreign_module.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
