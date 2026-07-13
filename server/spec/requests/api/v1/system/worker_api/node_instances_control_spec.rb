# frozen_string_literal: true

require "rails_helper"

# IMP-d47e9801b9d7 — worker_api NodeInstancesController#start/#stop/#reboot/#sync
# were 100% broken: execute_instance_action did
# `::System::InstanceControlService.new(@instance).public_send(action)`, but
# the service has no custom `initialize` (so `.new(@instance)` raises
# ArgumentError before anything else runs) and exposes no public
# start/stop/reboot instance methods — only the class-level
# `self.execute(instance:, action:, operation_id:, force:)`. "sync" was never
# a valid InstanceControlService action at all (only start/stop/reboot/
# terminate) — it needs CloudSyncService, same as the internal API's
# #sync_cloud_state. These specs pin the real calling conventions and this
# controller's response shape.
RSpec.describe "POST /api/v1/system/worker_api/node_instances/:id/{start,stop,reboot,sync}", type: :request do
  let(:account) { create(:account) }
  let(:worker)  { create(:worker, status: "active") }
  let(:node)    { create(:system_node, account: account, worker: worker) }
  let(:headers) { worker_mtls_headers(worker) }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.node_instances.manage").and_return(true)
  end

  describe "start" do
    let(:instance) { create(:system_node_instance, :stopped, node: node) }

    it "calls InstanceControlService.execute with the platform calling convention" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: { status: "running" }))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/start", headers: headers

      expect(System::InstanceControlService).to have_received(:execute)
        .with(instance: instance, action: :start, operation_id: nil)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body.dig("data", "action")).to eq("start")
    end

    it "renders the service error and does not raise when the service reports failure" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.err(error: "Cannot start instance in running status"))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/start", headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
      expect(body["error"]).to eq("Cannot start instance in running status")
    end
  end

  describe "stop" do
    let(:instance) { create(:system_node_instance, :running, node: node) }

    it "calls InstanceControlService.execute with action: :stop" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: { status: "stopped" }))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/stop", headers: headers

      expect(System::InstanceControlService).to have_received(:execute)
        .with(instance: instance, action: :stop, operation_id: nil)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "reboot" do
    let(:instance) { create(:system_node_instance, :running, node: node) }

    it "calls InstanceControlService.execute with action: :reboot" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.ok(data: { status: "running" }))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/reboot", headers: headers

      expect(System::InstanceControlService).to have_received(:execute)
        .with(instance: instance, action: :reboot, operation_id: nil)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "sync" do
    # InstanceControlService#validate_action! only accepts start/stop/reboot/
    # terminate — routing "sync" through it (even with the right calling
    # convention) would raise ArgumentError every time. Sync must go through
    # CloudSyncService instead.
    let(:instance) { create(:system_node_instance, :running, node: node, status: "starting") }

    it "reflects the cloud-reported state via CloudSyncService and the AASM finalizer" do
      allow(System::CloudSyncService).to receive(:sync_instance_state)
        .with(instance: instance)
        .and_return(System::Runtime::Result.ok(data: {
          status: "running", private_ip_address: "10.0.1.9", public_ip_address: "203.0.113.9", updated: true
        }))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/sync", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body.dig("data", "instance", "status")).to eq("running")
      expect(body.dig("data", "instance", "private_ip_address")).to eq("10.0.1.9")
      expect(instance.reload.status).to eq("running")
    end

    it "renders the service error and does not raise when the sync fails" do
      allow(System::CloudSyncService).to receive(:sync_instance_state)
        .and_return(System::Runtime::Result.err(error: "Instance has no cloud instance ID"))

      post "/api/v1/system/worker_api/node_instances/#{instance.id}/sync", headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
      expect(body["error"]).to eq("Instance has no cloud instance ID")
    end
  end
end
