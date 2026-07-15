# frozen_string_literal: true

require "rails_helper"

# The worker_api sync endpoint must dispatch the (minutes-long) sync to a
# DETACHED PROCESS — never run it inline (would blow the worker's HTTP timeout,
# retry, and storm) and never as an in-worker Thread (the puma RSS recycler
# QUITs the worker mid-sync and the thread dies, stranding the repo "syncing").
RSpec.describe "POST /api/v1/system/worker_api/package_repositories/sync", type: :request do
  let(:account)  { create(:account) }
  let!(:worker)  { create(:worker, :system_worker, status: "active") }
  let(:headers)  { worker_mtls_headers(worker) }
  let!(:repo)    { create(:system_package_repository, account: account) }

  before do
    allow(Process).to receive(:spawn).and_return(4242)
    allow(Process).to receive(:detach)
  end

  it "spawns a detached process (rails runner) and never syncs inline" do
    expect(System::PackageRepositorySyncService).not_to receive(:call)

    post "/api/v1/system/worker_api/package_repositories/sync",
         params: { repository_id: repo.id, force: true }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Process).to have_received(:spawn) do |*args|
      opts = args.last.is_a?(Hash) ? args.last : {}
      cmd  = args.reject { |a| a.is_a?(Hash) }
      expect(cmd).to include("rails", "runner", repo.id)
      joined = cmd.join(" ")
      expect(joined).to include("PackageRepositoryBackgroundSync")
      expect(joined).to include("force: true")
      expect(opts[:pgroup]).to be(true)
    end
    expect(Process).to have_received(:detach).with(4242)
  end

  it "dispatches the daily tick (no repository_id) to a detached process too" do
    create(:system_package_repository, account: account, last_synced_at: 3.days.ago, enabled: true)

    post "/api/v1/system/worker_api/package_repositories/sync",
         params: { staleness_minutes: 60 }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Process).to have_received(:spawn)
  end
end
