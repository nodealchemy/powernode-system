# frozen_string_literal: true

require "rails_helper"

# IMP-02a42b90598b (D13): the reconcile tick is the pull-model carrier for the
# best-effort post-enrolment seed cleanup (the server runs no Sidekiq).
RSpec.describe "POST /api/v1/system/worker_api/fleet/reconcile (seed cleanup)", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, :system_worker, account: account) }
  let(:headers) { worker_mtls_headers(worker) }

  before do
    node = create(:system_node, account: account)
    create(:system_node_instance, node: node, name: "ni-#{SecureRandom.hex(3)}", variety: "cloud", status: "running")
    allow_any_instance_of(Worker).to receive(:has_permission?).with("system.fleet.reconcile").and_return(true)
  end

  it "sweeps pending seed cleanups for each ticked account and reports the count" do
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_return(2)

    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers

    expect(response).to have_http_status(:ok)
    expect(System::EnrollmentSeedCleanup).to have_received(:sweep!).with(account: account)
    expect(JSON.parse(response.body).dig("data", "results").first["seed_cleanup"]).to eq(2)
  end

  it "does not sweep (no provider writes) while the kill switch halts the account" do
    allow_any_instance_of(Ai::Autonomy::KillSwitchService).to receive(:halted?).and_return(true)
    expect(System::EnrollmentSeedCleanup).not_to receive(:sweep!)

    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "keeps the tick healthy when the sweep itself blows up" do
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_raise(StandardError, "x")
    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers
    expect(response).to have_http_status(:ok)
  end
end
