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

  def due_instance(acct, requested_at: Time.current)
    inst = create(:system_node_instance, node: create(:system_node, account: acct),
                  name: "ni-#{SecureRandom.hex(3)}", variety: "cloud", status: "running")
    inst.merge_config!("seed_cleanup" => { "state" => "pending", "requested_at" => requested_at.utc.iso8601 })
    inst
  end

  before do
    due_instance(account)
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
    due_instance(create(:account))
    allow(System::EnrollmentSeedCleanup).to receive(:monotonic_now).and_return(0.0, 1.0, 99.0, 99.0, 99.0)
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_return(0)

    post path, headers: headers
    expect(System::EnrollmentSeedCleanup).to have_received(:sweep!).once
  end

  it "visits accounts by their oldest due row first, and skips accounts with nothing due" do
    late = create(:account)
    due_instance(late, requested_at: 2.hours.ago)
    idle = create(:account)
    create(:system_node_instance, node: create(:system_node, account: idle), name: "ni-#{SecureRandom.hex(3)}",
           variety: "cloud", status: "running")
    order = []
    allow(System::EnrollmentSeedCleanup).to receive(:sweep!) { |account:, **| order << account.id; 0 }

    post path, headers: headers

    expect(order).to eq([ late.id, account.id ])
  end

  context "with an account-scoped (non-system) worker" do
    let(:scoped_worker) { create(:worker, account: account) }
    let(:scoped_headers) { worker_mtls_headers(scoped_worker) }

    it "sweeps only its own account and answers 200 (not a 500 from an Array scope)" do
      other = create(:account)
      due_instance(other)
      allow(System::EnrollmentSeedCleanup).to receive(:sweep!).and_return(1)

      post path, headers: scoped_headers

      expect(response).to have_http_status(:ok)
      expect(System::EnrollmentSeedCleanup).to have_received(:sweep!).with(hash_including(account: account)).once
      expect(System::EnrollmentSeedCleanup).not_to have_received(:sweep!).with(hash_including(account: other))
    end
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
