# frozen_string_literal: true

require "rails_helper"

# IMP-53a5c597ec8c — the reaper is what makes drain-by-default safe, so an
# unreachable reaper is not a cosmetic gap: it silently restores the
# one-way-door behaviour the default now depends on being fixed. These
# examples exist to prove the lane is actually WIRED — route resolves,
# worker auth gates it, the service is invoked — not merely that the service
# would work if something called it.
RSpec.describe "Api::V1::System::WorkerApi::HostBridgeReaper", type: :request do
  let(:worker)  { create(:worker) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:path)    { "/api/v1/system/worker_api/sdwan/host_bridges/reap" }

  describe "POST /sdwan/host_bridges/reap" do
    it "invokes the reaper and returns the sweep result" do
      allow(::Sdwan::HostBridgeReaper).to receive(:run!).and_return(
        ::Sdwan::HostBridgeReaper::Result.new(ok?: true, reaped_bridges: 2, ran_at: Time.current)
      )

      post path, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["ok"]).to be true
      expect(data["reaped_bridges"]).to eq(2)
      expect(data["ran_at"]).to be_present
    end

    # End-to-end through the real service — the route, the controller and the
    # sweep together. A stub-only spec would pass against a controller wired
    # to nothing.
    it "actually closes an elapsed drain window through the real service" do
      account = create(:account)
      host = create(:system_node_instance, account: account)
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      bridge.mark_active!
      ::Sdwan::HostBridgeAllocator.release!(bridge)
      bridge.update_column(:draining_at, (::Sdwan::HostBridgeReaper::GRACE_WINDOW + 1.hour).ago)

      post path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("removed")
      expect(::Sdwan::HostBridge.where(id: bridge.id).compilable).to be_empty
    end

    it "401 without worker credentials" do
      post path

      expect(response).to have_http_status(:unauthorized)
    end

    it "500 with a diagnostic when the sweep raises" do
      allow(::Sdwan::HostBridgeReaper).to receive(:run!).and_raise(StandardError, "db gone")

      post path, headers: headers

      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to include("db gone")
    end
  end
end
