# frozen_string_literal: true

require "rails_helper"

# IMP-6ea384a0ee79 — one quorum observation per reconcile PASS, not per
# account. The reconcile loop used to let every account's tick! spawn its own
# corosync-quorumtool (5s timeout each): N redundant subprocesses per minute,
# and a corosync blip mid-pass could hand different accounts different
# active/standby verdicts within one logical instant. The controller now
# captures one Reading and carries it across the pass, refreshing only when
# the freshness window expires.
RSpec.describe "POST /api/v1/system/worker_api/fleet/reconcile (pass-scoped quorum)", type: :request do
  let(:account)       { create(:account) }
  let!(:other_account) { create(:account) }
  let!(:worker) { create(:worker, :system_worker, account: account) }
  let(:headers) { worker_mtls_headers(worker) }

  # The system-scoped reconcile only ticks accounts holding a NodeInstance.
  before do
    [ account, other_account ].each do |acct|
      node = create(:system_node, account: acct)
      create(:system_node_instance, node: node, name: "ni-#{SecureRandom.hex(3)}",
             variety: "cloud", status: "running")
    end
  end

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.fleet.reconcile").and_return(true)
  end

  after { System::Autonomy::ControlPlaneRole.reset_quorum_reader! }

  def quorumtool_output
    <<~OUT
      Quorum information
      ------------------
      Node ID:          1
      Quorate:          Yes

      Membership information
      ----------------------
          Nodeid      Votes Name
               1          1 ops-hub-a (local)
               2          1 ops-hub-b
    OUT
  end

  def arm!
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get)
      .with(System::Autonomy::ControlPlaneRole::COORDINATOR_KEY).and_return("rcp-quorum")
    allow(::SiteSetting).to receive(:get)
      .with(System::Autonomy::ControlPlaneRole::FRESHNESS_KEY).and_return(nil)
  end

  it "observes the quorum once for the whole multi-account pass while armed" do
    arm!
    reader_calls = 0
    System::Autonomy::ControlPlaneRole.quorum_reader = -> { reader_calls += 1; quorumtool_output }

    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "tick_count")).to be >= 2
    expect(reader_calls).to eq(1)
  end

  it "never touches the quorum reader while unarmed (single plane)" do
    reader_calls = 0
    System::Autonomy::ControlPlaneRole.quorum_reader = -> { reader_calls += 1; quorumtool_output }

    post "/api/v1/system/worker_api/fleet/reconcile", headers: headers

    expect(response).to have_http_status(:ok)
    expect(reader_calls).to eq(0)
  end
end
