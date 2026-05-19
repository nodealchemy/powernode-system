# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for package_repositories.
#
# Permission family is segmented: system.package_repositories.{view, create,
# update, delete, sync, manage_shared}. Visibility is account|shared — shared
# rows are platform-wide and require the manage_shared permission to mutate.
# Cross-account scoping uses PackageRepository.accessible_to(account).
RSpec.describe "Api::V1::System::PackageRepositories", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:view_user)   { user_with_permissions("system.package_repositories.view",   account: account) }
  let(:create_user) { user_with_permissions("system.package_repositories.create", account: account) }
  let(:update_user) { user_with_permissions("system.package_repositories.view", "system.package_repositories.update", account: account) }
  let(:delete_user) { user_with_permissions("system.package_repositories.delete", account: account) }
  let(:sync_user)   { user_with_permissions("system.package_repositories.sync",   account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:repo_owner) { user_with_permissions(account: account) }
  let!(:repo) do
    ::System::PackageRepository.create!(
      account: account,
      name: "spec-repo-#{SecureRandom.hex(3)}",
      kind: "apt",
      visibility: "account",
      base_url: "http://example.com/repo",
      enabled: true,
      priority: 50,
      created_by: repo_owner,
      apt_config: { "suite" => "stable", "components" => [ "main" ] }
    )
  end

  describe "GET /api/v1/system/package_repositories" do
    it "returns 401 without auth" do
      get "/api/v1/system/package_repositories"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without view perm" do
      get "/api/v1/system/package_repositories", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account (accessible_to scope)" do
      foreign_owner = user_with_permissions(account: other_account)
      foreign = ::System::PackageRepository.create!(
        account: other_account, name: "foreign-repo", kind: "apt",
        visibility: "account", base_url: "http://example.com/foreign",
        enabled: true, priority: 50,
        created_by: foreign_owner,
        apt_config: { "suite" => "stable", "components" => [ "main" ] }
      )
      get "/api/v1/system/package_repositories", headers: auth_headers_for(view_user)
      ids = json_response_data["package_repositories"].map { |r| r["id"] }
      expect(ids).to include(repo.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/package_repositories/:id" do
    it "returns the repo with detail" do
      get "/api/v1/system/package_repositories/#{repo.id}", headers: auth_headers_for(view_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["package_repository"]["id"]).to eq(repo.id)
      expect(json_response_data).to have_key("recent_packages_count")
    end
  end

  describe "POST /api/v1/system/package_repositories" do
    let(:create_params) do
      { package_repository: { name: "spec-pkg-repo-#{SecureRandom.hex(3)}", kind: "apt",
                              base_url: "http://example.com/new-repo", visibility: "account",
                              apt_config: { suite: "stable", components: [ "main" ] } } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/package_repositories", params: create_params.to_json,
                                                  headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates an account-scoped repository" do
      expect {
        post "/api/v1/system/package_repositories", params: create_params.to_json,
                                                    headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::PackageRepository.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end
  end

  describe "PATCH /api/v1/system/package_repositories/:id" do
    it "updates the repository" do
      patch "/api/v1/system/package_repositories/#{repo.id}",
            params: { package_repository: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(repo.reload.description).to eq("spec-updated")
    end
  end

  describe "DELETE /api/v1/system/package_repositories/:id" do
    it "deletes the repository" do
      delete "/api/v1/system/package_repositories/#{repo.id}", headers: auth_headers_for(delete_user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/package_repositories/:id/sync" do
    it "returns 403 without sync perm" do
      post "/api/v1/system/package_repositories/#{repo.id}/sync",
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to PackageRepositorySyncService" do
      result = OpenStruct.new(success?: true, upserted: 0, obsoleted: 0, package_count: 0, error: nil)
      allow(::System::PackageRepositorySyncService).to receive(:call).and_return(result)
      post "/api/v1/system/package_repositories/#{repo.id}/sync",
           headers: auth_headers_for(sync_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/system/package_repositories/:id/stale_links" do
    it "returns the stale-link list" do
      allow(::System::PackageRepositoryStaleLinkService).to receive(:find_stale).and_return(
        ::System::PackageModuleLink.none
      )
      get "/api/v1/system/package_repositories/#{repo.id}/stale_links",
          headers: auth_headers_for(view_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["stale_count"]).to eq(0)
    end
  end

  describe "POST /api/v1/system/package_repositories/:id/clean_stale_links" do
    it "delegates to PackageRepositoryStaleLinkService.clean!" do
      result = OpenStruct.new(destroyed: 0, kept: 0, dry_run: true)
      allow(::System::PackageRepositoryStaleLinkService).to receive(:clean!).and_return(result)
      post "/api/v1/system/package_repositories/#{repo.id}/clean_stale_links",
           params: { dry_run: true }.to_json,
           headers: auth_headers_for(delete_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end
end
