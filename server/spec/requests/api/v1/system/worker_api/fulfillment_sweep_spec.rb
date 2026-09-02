# frozen_string_literal: true

require "rails_helper"

# IMP-5fee957b75b5 — the sweep response must distinguish "nothing to do" from
# "the gates ate every account". aggregate() summed only counter keys and
# accounts_swept counted every target, so a halted/standby account contributed
# zeros and its gate reason vanished: accounts_swept 5 / advanced 0 read
# identically for an idle fleet and a fleet-wide kill switch. This controller
# also had no request spec at all.
RSpec.describe "POST /api/v1/system/worker_api/fulfillment/sweep", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, account: account, status: "active") }
  let(:headers) { worker_mtls_headers(worker) }

  # Puts the account in the sweep's target scope (task_scoped instance path).
  def make_sweepable!(acct)
    node = create(:system_node, account: acct)
    create(:system_node_instance, node: node, name: "ts-#{SecureRandom.hex(3)}",
           variety: "cloud", status: "running", lease_class: "task_scoped")
  end

  it "sweeps a normal account and reports the aggregate (pins the previously unspecced happy path)" do
    make_sweepable!(account)

    post "/api/v1/system/worker_api/fulfillment/sweep",
         params: { account_id: account.id }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(1)
    expect(data["accounts_gated"]).to eq(0)
    expect(data).to include("advanced", "instances_reaped", "errored")
  end

  it "reports a halted account as gated, not swept" do
    make_sweepable!(account)
    account.suspend_ai!

    post "/api/v1/system/worker_api/fulfillment/sweep",
         params: { account_id: account.id }.to_json, headers: headers

    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(0)
    expect(data["accounts_gated"]).to eq(1)
    expect(data.dig("gates", "halted")).to eq(1)
  end

  it "reports a standby-plane account as gated with the fence visible" do
    make_sweepable!(account)
    allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
    allow(::System::Autonomy::ControlPlaneRole).to receive(:status).and_return(:standby)

    post "/api/v1/system/worker_api/fulfillment/sweep",
         params: { account_id: account.id }.to_json, headers: headers

    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(0)
    expect(data["accounts_gated"]).to eq(1)
    expect(data.dig("gates", "standby")).to eq(1)
  end
end
