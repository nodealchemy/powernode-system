# frozen_string_literal: true

require "rails_helper"

# Worker → server callback for the daily UnclaimedDevice reaper.
# See plan wondrous-yawning-anchor.md §10.
RSpec.describe "POST /api/v1/system/worker_api/unclaimed_devices/expire", type: :request do
  let(:account) { create(:account) }
  let(:plain_token) { "wrk-tok-#{SecureRandom.hex(8)}" }
  let!(:worker) do
    w = create(:worker, account: account, status: "active")
    w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
    w
  end
  let(:headers) { { "X-Worker-Token" => plain_token, "Content-Type" => "application/json" } }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.unclaimed_devices.discard").and_return(true)
  end

  it "deletes expired rows + emits a single FleetEvent summary" do
    fresh = create(:system_unclaimed_device, account: account, expires_at: 1.hour.from_now)
    stale_a = create(:system_unclaimed_device, account: account, expires_at: 1.hour.ago)
    stale_b = create(:system_unclaimed_device, account: account, expires_at: 1.day.ago)

    expect {
      post "/api/v1/system/worker_api/unclaimed_devices/expire",
           params: {}.to_json, headers: headers
    }.to change { System::UnclaimedDevice.count }.by(-2)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)["data"]
    expect(body["reaped_count"]).to eq(2)

    # Surviving row
    expect(System::UnclaimedDevice.where(id: fresh.id)).to exist
    expect(System::UnclaimedDevice.where(id: [ stale_a.id, stale_b.id ])).to be_empty
  end

  it "returns reaped_count: 0 with no FleetEvent when nothing's expired" do
    create(:system_unclaimed_device, account: account, expires_at: 1.hour.from_now)
    expect {
      post "/api/v1/system/worker_api/unclaimed_devices/expire",
           params: {}.to_json, headers: headers
    }.not_to change { System::FleetEvent.count }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "reaped_count")).to eq(0)
  end

  it "rejects unauthenticated requests" do
    create(:system_unclaimed_device, account: account, expires_at: 1.hour.ago)
    post "/api/v1/system/worker_api/unclaimed_devices/expire",
         params: {}.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end
end
