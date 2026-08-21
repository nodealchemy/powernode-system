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
          architectures: [ "amd64" ],
          apt_config: { suite: "noble", components: [ "main" ] }
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

    it "marks the repo syncing and enqueues the worker sync job (async)" do
      # Async: the request returns immediately after queueing; it must NOT run
      # the (minutes-long) sync inline, and never enqueues to Sidekiq directly.
      expect(System::PackageRepositorySyncService).not_to receive(:call)
      expect(System::WorkerJobEnqueuer).to receive(:enqueue).with(
        job_class: "SystemPackageRepositorySyncJob",
        args:      [ repo.id, { "force" => false } ],
        queue:     "system"
      )
      post "/api/v1/system/package_repositories/#{repo.id}/sync",
           headers: auth_headers_for(user_a)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["ok"]).to be(true)
      expect(json_response_data["status"]).to eq("syncing")
      expect(repo.reload.sync_status).to eq("syncing")
    end
  end

  # IMP-ce5d320d3e4e — authorize_repo_mutation! guards link_platform /
  # unlink_platform, and its cross-tenant arm refused with
  # `render_error("Forbidden", ...) and return`. That returns from the HELPER,
  # not from the action: the 403 rendered and link_platform ran straight on to
  # create the link. (The follow-up render_success raised DoubleRenderError,
  # which ApiResponse swallows with `unless performed?`, so the caller saw a
  # clean 403 over a committed cross-tenant link.)
  #
  # Reaching that arm needs the accessible_to scope to hand back a foreign
  # repo, which today it never does (visibility=account ⟺ account_id NOT NULL
  # is a DB CHECK, and the scope admits only own-account or shared rows). The
  # arm is defense in depth, so the scope is stubbed to simulate exactly the
  # leak it defends against — and the oracle is the ABSENCE of the link row,
  # not the 403, because the 403 was always correct.
  describe "POST /:id/link_platform (cross-tenant defense in depth)" do
    let!(:foreign_repo) { create(:system_package_repository, account: account_b) }
    # Same account as the repo: System::PackageRepositoryPlatform's
    # account_consistency validation rejects a cross-account link outright, so
    # a platform on some third account would make link.save fail on its own —
    # and the count oracle would pass for a reason that has nothing to do with
    # the halt.
    let!(:platform)     { create(:system_node_platform, account: account_b) }

    # Positive control. Without it the absence-of-effect example above could
    # go green because the write path is broken under the stub rather than
    # because the refusal halted — an oracle passing for the wrong reason is
    # exactly the failure mode this whole change is about.
    it "creates the link when the repo belongs to the caller's own account" do
      own_repo     = create(:system_package_repository, account: account_a)
      own_platform = create(:system_node_platform, account: account_a)

      expect {
        post "/api/v1/system/package_repositories/#{own_repo.id}/link_platform",
             params: { node_platform_id: own_platform.id }.to_json,
             headers: auth_headers_for(user_a).merge("Content-Type" => "application/json")
      }.to change { ::System::PackageRepositoryPlatform.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(json_response_data["linked"]).to be(true)
    end

    it "creates no platform link when the repo belongs to another account" do
      allow(::System::PackageRepository).to receive(:accessible_to)
        .and_return(::System::PackageRepository.where(id: foreign_repo.id))

      before_count = ::System::PackageRepositoryPlatform.count

      post "/api/v1/system/package_repositories/#{foreign_repo.id}/link_platform",
           params: { node_platform_id: platform.id }.to_json,
           headers: auth_headers_for(user_a).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:forbidden)
      expect(::System::PackageRepositoryPlatform.count).to eq(before_count),
                                                           "a cross-tenant platform link was created behind the 403"
      expect(foreign_repo.reload.package_repository_platforms.count).to eq(0)
    end
  end
end
