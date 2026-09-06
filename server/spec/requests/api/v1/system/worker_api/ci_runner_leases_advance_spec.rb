# frozen_string_literal: true

require "rails_helper"

# The CI lease sweep's honest-aggregate mirror of FulfillmentController#sweep
# (IMP-5fee957b75b5): gated accounts are counted and broken out, never
# summed away as zeros.
RSpec.describe "POST /api/v1/system/worker_api/ci_runner_leases/advance", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, account: account, status: "active") }
  let(:headers) { worker_mtls_headers(worker) }

  def make_sweepable!(acct)
    create(:git_runner, account: acct, name: "fleet-#{SecureRandom.hex(3)}", status: "offline")
  end

  it "sweeps a normal account and reports it swept" do
    make_sweepable!(account)

    post "/api/v1/system/worker_api/ci_runner_leases/advance",
         params: { account_id: account.id }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(1)
    expect(data["accounts_gated"]).to eq(0)
  end

  it "discovers an account whose only sweepable state is a module build batch still in flight" do
    System::ModuleBuildBatch.create_for(account: account, trigger: "manual", base_sha: "base", head_sha: "head",
                                        plan: [ { module: "mod-x", oci_ref: "abc1234" } ])

    post "/api/v1/system/worker_api/ci_runner_leases/advance", params: {}.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(1)
    expect(data).to include("readvanced" => 0, "redispatched" => 0)
  end

  it "reports a halted account as gated, not swept" do
    make_sweepable!(account)
    account.suspend_ai!

    post "/api/v1/system/worker_api/ci_runner_leases/advance",
         params: { account_id: account.id }.to_json, headers: headers

    data = JSON.parse(response.body)["data"]
    expect(data["accounts_swept"]).to eq(0)
    expect(data["accounts_gated"]).to eq(1)
    expect(data.dig("gates", "halted")).to eq(1)
  end
end
