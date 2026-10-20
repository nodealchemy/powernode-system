# frozen_string_literal: true

require "rails_helper"

# IMP-02a42b90598b (D13) review H1/M2: the seed cleanup sweep has its OWN
# worker_api endpoint (own short job, post_no_retry), is fenced like every other
# actuating loop (kill switch AND control-plane role), and is no longer part of
# the per-minute reconcile request.
RSpec.describe "POST /api/v1/system/worker_api/seed_cleanup/sweep", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, :system_worker, account: account) }
  let(:headers) { worker_mtls_headers(worker) }
  let(:path) { "/api/v1/system/worker_api/seed_cleanup/sweep" }

  before do
    node = create(:system_node, account: account)
    create(:system_node_instance, node: node, name: "ni-#{SecureRandom.hex(3)}", variety: "cloud", status: "running")
    allow_any_instance_of(Worker).to receive(:has_permission?).with("system.fleet.reconcile").and_return(true)
    allow(System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(true)
  end

  it "sweeps each account with a small per-tick limit and a wall-clock budget, and reports the count" do
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_return(2)

    post path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(System::EnrollmentSeedCleanup).to have_received(:sweep!)
      .with(account: account, limit: 5, deadline: kind_of(Numeric))
    expect(JSON.parse(response.body).dig("data", "swept")).to eq(2)
  end

  it "makes no provider writes on the standby plane (even when the fleet agent is not seeded)" do
    allow(System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
    expect(System::EnrollmentSeedCleanup).not_to receive(:sweep!)

    post path, headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "does not sweep an account under the emergency kill switch" do
    allow_any_instance_of(Ai::Autonomy::KillSwitchService).to receive(:halted?).and_return(true)
    expect(System::EnrollmentSeedCleanup).not_to receive(:sweep!)

    post path, headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "stops starting accounts once the shared budget is spent" do
    other = create(:account)
    create(:system_node_instance, node: create(:system_node, account: other), name: "ni-#{SecureRandom.hex(3)}",
           variety: "cloud", status: "running")
    allow(System::EnrollmentSeedCleanup).to receive(:monotonic_now).and_return(0.0, 1.0, 99.0, 99.0, 99.0)
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_return(0)

    post path, headers: headers
    expect(System::EnrollmentSeedCleanup).to have_received(:sweep!).once
  end

  it "keeps answering 200 when a sweep blows up" do
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_raise(StandardError, "x")
    post path, headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "is no longer run inside the reconcile request" do
    expect(System::EnrollmentSeedCleanup).not_to receive(:sweep!)
    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers
    expect(JSON.parse(response.body).dig("data", "results").to_a.first.to_h).not_to have_key("seed_cleanup")
  end
end
