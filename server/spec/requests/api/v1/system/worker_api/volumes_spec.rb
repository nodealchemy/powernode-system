# frozen_string_literal: true

require "rails_helper"

# Audit F4-04 — the routed volume lifecycle endpoints 500'd on every call:
# they instantiated VolumeManagementService.new(@volume) (the service has a
# zero-arg initializer + class-method interface), called methods that no
# longer exist (check_status), and read Hash-style result[:success] from
# what is now a System::Runtime::Result.
RSpec.describe "WorkerApi volume lifecycle endpoints (F4-04)", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, :system_worker, status: "active") }
  let(:headers) { worker_mtls_headers(worker) }
  let!(:node) { create(:system_node, account: account, worker: worker) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:volume) { create(:system_provider_volume, account: account) }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?).and_return(true)
  end

  describe "POST /api/v1/system/worker_api/volumes/:id/attach" do
    it "attaches via the class-method interface and returns the device" do
      expect(::System::VolumeManagementService).to receive(:attach)
        .with(volume: volume, instance: instance, device: "/dev/vdb")
        .and_return(::System::Runtime::Result.ok(data: { device: "/dev/vdb" }))

      post "/api/v1/system/worker_api/volumes/#{volume.id}/attach",
           params: { instance_id: instance.id, device_name: "/dev/vdb" },
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "device_name")).to eq("/dev/vdb")
      expect(body.dig("data", "attached_to")).to eq(instance.id)
    end

    it "surfaces a Runtime::Result error without raising" do
      allow(::System::VolumeManagementService).to receive(:attach)
        .and_return(::System::Runtime::Result.err(error: "Volume is already attached"))

      post "/api/v1/system/worker_api/volumes/#{volume.id}/attach",
           params: { instance_id: instance.id },
           headers: headers

      expect(response).not_to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be false
    end
  end

  describe "POST /api/v1/system/worker_api/volumes/:id/detach" do
    it "detaches via the class-method interface" do
      expect(::System::VolumeManagementService).to receive(:detach)
        .with(volume: volume)
        .and_return(::System::Runtime::Result.ok)

      post "/api/v1/system/worker_api/volumes/#{volume.id}/detach", headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "detached")).to be true
    end
  end

  describe "POST /api/v1/system/worker_api/volumes/:id/check" do
    it "returns the provider-side status from check" do
      expect(::System::VolumeManagementService).to receive(:check)
        .with(volume: volume)
        .and_return(::System::Runtime::Result.ok(data: { status: "available", size_gb: 20 }))

      post "/api/v1/system/worker_api/volumes/#{volume.id}/check", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "cloud_status", "status")).to eq("available")
      expect(body.dig("data", "cloud_status", "size_gb")).to eq(20)
    end
  end
end
