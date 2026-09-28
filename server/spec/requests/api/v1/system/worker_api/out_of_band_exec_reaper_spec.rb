# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — the worker-callable door onto
# System::OutOfBandExecReaperService, mirroring the identity reaper's
# controller shape exactly.
RSpec.describe "POST /api/v1/system/worker_api/out_of_band_exec/reap", type: :request do
  # Security review findings S7 / R2-4 / C2-1 — this door requires
  # system.node_instances.manage, already granted `system_worker: :all` in
  # engine.rb (team-lead accepted reusing this over a new permission). Uses
  # the REAL seeded system_worker role (`:system_worker` trait, same pattern
  # as worker_api/cloud_sync_spec.rb and every other worker_api
  # reconcile-tick spec) — not a synthetic test-only role, per the round-2
  # correctness review: a synthetic role can pass while the real production
  # role would 403, which is exactly the defect the two earlier permission
  # choices had.
  let(:worker) { create(:worker, :system_worker, status: "active") }

  it "returns 401 without a worker mTLS identity" do
    post "/api/v1/system/worker_api/out_of_band_exec/reap"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 403 when the worker lacks system.node_instances.manage" do
    unprivileged = create(:worker, status: "active")

    post "/api/v1/system/worker_api/out_of_band_exec/reap", headers: worker_mtls_headers(unprivileged)

    expect(response).to have_http_status(:forbidden)
  end

  it "runs the reaper service and reports its counts" do
    allow(::System::OutOfBandExecReaperService).to receive(:run!).and_return(
      ::System::OutOfBandExecReaperService::Result.new(ok?: true, failed_count: 2, ran_at: Time.current)
    )

    post "/api/v1/system/worker_api/out_of_band_exec/reap", headers: worker_mtls_headers(worker)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["data"]["ok"]).to be true
    expect(body["data"]["failed_count"]).to eq(2)
    expect(body["data"]["ran_at"]).to be_present
  end

  it "renders a 500 rather than raising when the service itself errors" do
    allow(::System::OutOfBandExecReaperService).to receive(:run!).and_raise(StandardError, "db unavailable")

    post "/api/v1/system/worker_api/out_of_band_exec/reap", headers: worker_mtls_headers(worker)

    expect(response).to have_http_status(:internal_server_error)
  end

  # Built through the REAL AASM lifecycle, not update_columns(executed_at:) —
  # a review finding caught that #start_execution never sets executed_at (see
  # out_of_band_exec_reaper_service_spec.rb's header), so a fixture faking a
  # non-nil executed_at would pass here while never proving the endpoint
  # reaps an operation shaped the way production actually leaves one.
  it "actually reaps a real stuck operation end to end, with executed_at NULL as it really is" do
    account = create(:account)
    op = ::Ai::DeferredOperation.create!(
      account: account, action_category: ::System::OutOfBandExecService::ACTION_CATEGORY,
      executor_class: "StubOobExecutor", params: {}
    )
    travel_to(10.minutes.ago) do
      op.approve!
      op.start_execution!
    end
    expect(op.reload.executed_at).to be_nil

    post "/api/v1/system/worker_api/out_of_band_exec/reap", headers: worker_mtls_headers(worker)

    expect(response).to have_http_status(:ok)
    expect(op.reload.status).to eq("failed")
    expect(op.error_message).to eq("executor lost")
  end
end
