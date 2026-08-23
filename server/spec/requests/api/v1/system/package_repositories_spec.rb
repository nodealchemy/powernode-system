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

  # IMP-c90ba4ec46da — `sync` was gated on a FLAT
  # system.package_repositories.sync and explicitly admitted shared repos
  # (`account_id.nil? || == @account.id`). An unforced sync is a benign
  # idempotent refresh and is defensible unbranched — but `force: true` also
  # switches OFF PackageRepositorySyncService#guard_obsoletion!, the
  # fail-closed check that exists (per its own comment) so a broken or
  # partially-fetched upstream cannot "nuke tens of thousands of live rows".
  # A holder of the WEAKEST permission in the family could therefore point
  # force:true at a canonical SHARED repo that every tenant reads and
  # soft-delete an arbitrary fraction of it with the safety net off.
  #
  # The gate has to key on BOTH `shared?` AND `force`: a plain `shared?` branch
  # would block the routine refresh every tenant legitimately runs.
  #
  # The oracle is ABSENCE OF EFFECT and it counts OBSOLETED ROWS — a 403-only
  # assertion passes against code that 403s *after* obsoleting. The sync is
  # async (the controller enqueues; the worker runs it), so the enqueue is
  # RELAYED INLINE here and the spec drives the real service against an
  # upstream that yields zero packages — precisely the broken-mirror case the
  # guard defends against, and the case where force is most destructive.
  describe "POST /:id/sync with force (shared-repository authorization)" do
    let!(:shared_repo) { create(:system_package_repository, :shared, name: "canonical-upstream") }
    let!(:live_packages) do
      Array.new(3) { |i| create(:system_package, package_repository: shared_repo, name: "live-pkg-#{i}") }
    end

    # A `def`, never a `let`: a memoized count captures the PRE state and would
    # go green against unfixed code no matter what the request did.
    def obsoleted_count(repo = shared_repo)
      ::System::Package.where(package_repository_id: repo.id).where.not(obsoleted_at: nil).count
    end

    # The upstream index comes back EMPTY (a mirror mid-publish). Unforced,
    # guard_obsoletion! raises "upstream yielded zero packages" and nothing is
    # obsoleted; forced, the guard returns early and every live row is
    # soft-deleted. That asymmetry is what makes force the dangerous verb.
    def stub_empty_upstream!
      adapter = instance_double(::System::PackageAdapters::AptAdapter)
      allow(adapter).to receive(:fingerprint).and_return(nil)
      allow(adapter).to receive(:sync_metadata) # yields nothing
      allow(::System::PackageAdapters).to receive(:for).and_return(adapter)
    end

    # Run the enqueued sync INLINE so the oracle observes the OBSOLETION and
    # not merely the enqueue. Only the sync job is relayed — the service also
    # enqueues SystemPackageEmbeddingJob, which must stay a no-op here.
    def relay_sync_inline!
      allow(::System::WorkerJobEnqueuer).to receive(:enqueue) do |job_class:, args:, queue: nil, **_|
        if job_class == "SystemPackageRepositorySyncJob"
          repo_id, opts = args
          ::System::PackageRepositorySyncService.call(
            repository: ::System::PackageRepository.find(repo_id),
            force:      opts["force"]
          )
        end
      end
    end

    def force_sync(repo, as:)
      post "/api/v1/system/package_repositories/#{repo.id}/sync",
           params:  { force: true }.to_json,
           headers: auth_headers_for(as).merge("Content-Type" => "application/json")
    end

    it "obsoletes NOTHING when a caller holding only `sync` forces a shared repo" do
      stub_empty_upstream!
      relay_sync_inline!
      expect(obsoleted_count).to eq(0)

      force_sync(shared_repo, as: user_a)

      # Absence of effect is the oracle; the status is corroboration only.
      expect(obsoleted_count).to eq(0),
                                 "a force-sync obsoleted rows on a SHARED repo for a caller without manage_shared"
      expect(response).to have_http_status(:forbidden)
    end

    # NB: deliberately NO plain `sync` permission on this caller. Granting both
    # would leave `require_all_permissions(sync, manage_shared)` alive as a
    # mutant — the examples could not tell "forcing a shared repo needs
    # manage_shared" apart from "needs sync AND manage_shared".
    it "positive control: a manage_shared holder DOES force a shared repo, and force really bypasses the guard" do
      sharer = user_with_permissions("system.package_repositories.view",
                                     "system.package_repositories.manage_shared",
                                     account: account_a)
      stub_empty_upstream!
      relay_sync_inline!

      force_sync(shared_repo, as: sharer)

      expect(response).to have_http_status(:ok)
      # Proves the destructive path still fires on this same fixture — without
      # it the example above could pass because the write path is broken under
      # the stubs rather than because the gate held.
      expect(obsoleted_count).to eq(3)
    end

    it "still lets a plain `sync` holder run an UNFORCED sync on a shared repo" do
      expect(::System::WorkerJobEnqueuer).to receive(:enqueue).with(
        job_class: "SystemPackageRepositorySyncJob",
        args:      [ shared_repo.id, { "force" => false } ],
        queue:     "system"
      )

      post "/api/v1/system/package_repositories/#{shared_repo.id}/sync",
           headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:ok)
      expect(shared_repo.reload.sync_status).to eq("syncing")
    end

    # Decision: an account-scoped repo's OWNER may force. The blast radius is
    # their own catalog, `sync` on your own repo already carries authority over
    # it, and force is the documented recovery from a bad upstream — taking it
    # away would leave an owner unable to repair their own repo.
    it "still lets a plain `sync` holder force their OWN account-scoped repo" do
      own_repo = create(:system_package_repository, account: account_a)
      Array.new(2) { |i| create(:system_package, package_repository: own_repo, name: "own-pkg-#{i}") }
      stub_empty_upstream!
      relay_sync_inline!

      force_sync(own_repo, as: user_a)

      expect(response).to have_http_status(:ok)
      expect(obsoleted_count(own_repo)).to eq(2)
    end
  end
end
