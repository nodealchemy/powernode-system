# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for packages browse.
#
# Permission gates: system.packages.{view,search} for read paths,
# system.package_modules.create for materializing modules. Search is
# delegated to PackageSearchService; tests mock the service to avoid the
# pgvector path and focus on the controller boundary.
RSpec.describe "Api::V1::System::Packages", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:view_user)        { user_with_permissions("system.packages.view",            account: account) }
  let(:search_user)      { user_with_permissions("system.packages.search",          account: account) }
  let(:materialize_user) { user_with_permissions("system.package_modules.create",   account: account) }
  let(:no_perms)         { user_with_permissions(account: account) }

  describe "GET /api/v1/system/packages" do
    it "returns 401 without auth" do
      get "/api/v1/system/packages"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without search perm" do
      get "/api/v1/system/packages", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to PackageSearchService and returns 200" do
      service_result = OpenStruct.new(
        packages: [], total: 0, mode: "lexical",
        applied_filters: { page: 1, per_page: 25 }
      )
      allow(::System::PackageSearchService).to receive(:call).and_return(service_result)
      get "/api/v1/system/packages", headers: auth_headers_for(search_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["packages"]).to eq([])
    end
  end

  describe "GET /api/v1/system/packages/:id" do
    it "returns 403 without view perm" do
      get "/api/v1/system/packages/some-id", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 when the package's repo isn't accessible to the caller" do
      # Build a package against a foreign-account repository so the
      # accessible_to scope filters it out.
      foreign_owner = user_with_permissions(account: other_account)
      foreign_repo = ::System::PackageRepository.create!(
        account: other_account, name: "foreign-pkg-repo", kind: "apt",
        visibility: "account", base_url: "http://example.com/foreign-pkgs",
        enabled: true, priority: 50,
        created_by: foreign_owner,
        apt_config: { "suite" => "stable", "components" => [ "main" ] }
      )
      pkg = ::System::Package.create!(
        package_repository: foreign_repo, name: "spec-pkg",
        version: "1.0", architecture: "amd64"
      )
      get "/api/v1/system/packages/#{pkg.id}", headers: auth_headers_for(view_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/packages/discover" do
    it "returns 403 without view perm" do
      post "/api/v1/system/packages/discover", params: { intent: "web server" }.to_json,
                                               headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to DiscoverPackagesByIntentExecutor" do
      executor = instance_double(::System::Ai::Skills::DiscoverPackagesByIntentExecutor)
      allow(::System::Ai::Skills::DiscoverPackagesByIntentExecutor).to receive(:new).and_return(executor)
      allow(executor).to receive(:execute).and_return(success: true, data: { results: [] })
      post "/api/v1/system/packages/discover",
           params: { intent: "web server" }.to_json,
           headers: auth_headers_for(view_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/packages/suggest_architectures" do
    it "delegates to SuggestArchitecturesForFleetExecutor" do
      executor = instance_double(::System::Ai::Skills::SuggestArchitecturesForFleetExecutor)
      allow(::System::Ai::Skills::SuggestArchitecturesForFleetExecutor).to receive(:new).and_return(executor)
      allow(executor).to receive(:execute).and_return(success: true, data: { architectures: [] })
      post "/api/v1/system/packages/suggest_architectures",
           params: { repository_id: SecureRandom.uuid }.to_json,
           headers: auth_headers_for(view_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/packages/create_module" do
    it "returns 403 without package_modules.create perm" do
      post "/api/v1/system/packages/create_module",
           params: { repository_id: SecureRandom.uuid }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
