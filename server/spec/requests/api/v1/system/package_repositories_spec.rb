# frozen_string_literal: true

require "rails_helper"

RSpec.describe "/api/v1/system/package_repositories", type: :request do
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }
  let(:user_a) do
    u = user_with_permissions(
      "system.package_repositories.view",
      "system.package_repositories.create",
      "system.package_repositories.update",
      "system.package_repositories.delete",
      "system.package_repositories.sync",
      account: account_a
    )
    u
  end
  let(:admin_a) do
    user_with_permissions(
      "system.package_repositories.view",
      "system.package_repositories.create",
      "system.package_repositories.update",
      "system.package_repositories.delete",
      "system.package_repositories.sync",
      "system.package_repositories.manage_shared",
      account: account_a
    )
  end
  let(:user_b) do
    user_with_permissions(
      "system.package_repositories.view",
      "system.package_repositories.create",
      account: account_b
    )
  end

  describe "GET /api/v1/system/package_repositories" do
    let!(:account_repo) { create(:system_package_repository, account: account_a, name: "account-only") }
    let!(:other_account_repo) { create(:system_package_repository, account: account_b, name: "other-account") }
    let!(:shared_repo) { create(:system_package_repository, :shared, name: "shared-archive") }

    it "returns account-scoped repos + shared repos, never other accounts' repos" do
      get "/api/v1/system/package_repositories", headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:ok)
      # json_response_data returns string-keyed hash, not symbol-keyed.
      names = json_response_data["package_repositories"].map { |r| r["name"] }
      expect(names).to include("account-only", "shared-archive")
      expect(names).not_to include("other-account")
    end
  end

  describe "POST /api/v1/system/package_repositories" do
    let(:create_params) do
      {
        package_repository: {
          name: "test-apt",
          kind: "apt",
          base_url: "https://archive.example.com/ubuntu",
          architectures: ["amd64"],
          apt_config: { suite: "noble", components: ["main"] }
        }
      }
    end

    it "creates an account-scoped repo for any operator with .create" do
      post "/api/v1/system/package_repositories", params: create_params.to_json,
                                                   headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:ok).or have_http_status(:created)
      repo = System::PackageRepository.find(json_response_data["package_repository"]["id"])
      expect(repo.account_id).to eq(account_a.id)
      expect(repo.visibility).to eq("account")
    end

    it "refuses to create a shared repo without manage_shared permission" do
      params = create_params.deep_dup
      params[:package_repository][:visibility] = "shared"

      post "/api/v1/system/package_repositories", params: params.to_json,
                                                   headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a shared repo (account_id NULL) when the operator has manage_shared" do
      params = create_params.deep_dup
      params[:package_repository][:visibility] = "shared"
      params[:package_repository][:name] = "shared-test"

      post "/api/v1/system/package_repositories", params: params.to_json,
                                                   headers: auth_headers_for(admin_a)
      expect(response).to have_http_status(:ok).or have_http_status(:created)
      repo = System::PackageRepository.find(json_response_data["package_repository"]["id"])
      expect(repo.account_id).to be_nil
      expect(repo.visibility).to eq("shared")
    end
  end

  describe "PUT /api/v1/system/package_repositories/:id (cross-account)" do
    let!(:other_account_repo) { create(:system_package_repository, account: account_b) }

    it "returns 404 for repos in another account (not 403 — they're invisible)" do
      put "/api/v1/system/package_repositories/#{other_account_repo.id}",
          params: { package_repository: { description: "should not work" } }.to_json,
          headers: auth_headers_for(user_a)
      # The accessible_to scope filters them out → set_repository raises NotFound
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE shared repo" do
    let!(:shared_repo) { create(:system_package_repository, :shared) }

    it "refuses delete for an operator without manage_shared" do
      delete "/api/v1/system/package_repositories/#{shared_repo.id}",
             headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:forbidden)
    end

    it "allows delete for an operator with manage_shared" do
      delete "/api/v1/system/package_repositories/#{shared_repo.id}",
             headers: auth_headers_for(admin_a)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /:id/sync" do
    let!(:repo) { create(:system_package_repository, account: account_a) }

    it "invokes PackageRepositorySyncService and returns the result" do
      expect(System::PackageRepositorySyncService).to receive(:call).with(repository: anything).and_return(
        System::PackageRepositorySyncService::Result.new(
          success: true, package_count: 5, upserted: 5, obsoleted: 0, error: nil
        )
      )
      post "/api/v1/system/package_repositories/#{repo.id}/sync",
           headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["ok"]).to be(true)
      expect(json_response_data["upserted"]).to eq(5)
    end
  end
end
