# frozen_string_literal: true

require "rails_helper"

# IMP-99967525e870 — the worker_api node_instances #maintenance action was
# dead-on-arrival: it called the (no-arg) InstanceMaintenanceService with a
# positional arg and an unknown #perform_maintenance method, then treated the
# return as a Hash. Every call 500'd. These specs pin the real
# InstanceMaintenanceService.run_maintenance(instance:) -> Runtime::Result
# contract and this controller's success/error response shape.
RSpec.describe "POST /api/v1/system/worker_api/node_instances/:id/maintenance", type: :request do
  let(:account)  { create(:account) }
  let(:worker)   { create(:worker, status: "active") }
  let(:node)     { create(:system_node, account: account, worker: worker) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:headers)  { worker_mtls_headers(worker) }

  before do
    # Satisfy authorize_worker_permission!("system.node_instances.manage")
    # without wrestling role_permission seeding (same posture as cloud_sync_spec).
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.node_instances.manage").and_return(true)
  end

  def post_maintenance
    post "/api/v1/system/worker_api/node_instances/#{instance.id}/maintenance", headers: headers
  end

  context "when maintenance succeeds" do
    before do
      allow(System::InstanceMaintenanceService).to receive(:run_maintenance)
        .with(instance: anything)
        .and_return(System::Runtime::Result.ok(data: {
          results: { "health_check" => { success: true } },
          tasks_run: 6, tasks_succeeded: 6, tasks_failed: 0
        }))
    end

    it "returns 200 with the serialized instance and the maintenance result" do
      post_maintenance

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true

      mr = body.dig("data", "maintenance_result")
      expect(mr["success"]).to be true
      expect(mr["tasks_run"]).to eq(6)
      expect(mr["tasks_succeeded"]).to eq(6)
      expect(mr["tasks_failed"]).to eq(0)
      expect(mr["results"]).to eq("health_check" => { "success" => true })

      serialized = body.dig("data", "instance")
      expect(serialized["id"]).to eq(instance.id)
      expect(serialized["status"]).to eq("running")
    end
  end

  context "when maintenance fails" do
    before do
      allow(System::InstanceMaintenanceService).to receive(:run_maintenance)
        .with(instance: anything)
        .and_return(System::Runtime::Result.err(error: "Instance is not running"))
    end

    it "does not 200 and renders the service error message" do
      post_maintenance

      expect(response).not_to have_http_status(:ok)
      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
      expect(body["error"]).to eq("Instance is not running")
    end
  end
end
