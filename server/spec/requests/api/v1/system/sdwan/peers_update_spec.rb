# frozen_string_literal: true

require "rails_helper"

# IMP-c159cc6777b1 — gated-CRUD wiring, peer resource (slice 3).
#
# PeersController#update wrote through @peer.update(peer_update_params) behind
# the permission check alone, so the seeded sdwan.peer_update policy matched no
# gate call — while DELETE on this same controller has been gated
# (sdwan.peer_delete) since slice 1. Changing a peer's endpoint / lan_subnets /
# publicly_reachable rewrites AllowedIPs and BGP for every session that peer
# participates in, so it is at least as consequential as deleting the peer.
#
# Unlike VIP/firewall update, this is a CLEAN wiring: the controller action is a
# bare update with no controller-level side-effect, and the peer's side-effects
# (sync_subnet_advertisements_from_lan_subnets, normalize_tags) are MODEL
# callbacks — so the executor's update!(attrs) fires them on both the immediate
# and the approved path, and nothing is dropped on the :pending branch.
#
# Response-contract note (202): an operator request carries no agent, and the
# seeded sdwan.peer_update policy is ai_agent_id-scoped to the SDWAN Manager, so
# Ai::InterventionPolicy#agent_matches? rejects it for an agent-less caller and
# InterventionPolicyService falls through to its require_approval default — 202,
# the change applied only at approval time by the executor. The :proceed branch
# (auto_approve) answers 200 with the serialized row.
RSpec.describe "Api::V1::System::Sdwan::Peers update", type: :request do
  let(:user) { user_with_permissions("system.sdwan.peers.manage", "system.sdwan.peers.read") }
  let(:account) { user.account }
  let(:reader) { user_with_permissions("system.sdwan.peers.read", account: account) }
  let!(:network) { create(:sdwan_network, account: account) }
  let!(:peer) { create(:sdwan_peer, account: account, network: network, tags: []) }

  let(:payload) { { peer: { tags: ["edge"] } } }

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}"

  def patch_update(as: user)
    patch member_path, params: payload.to_json,
          headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  # Executes the deferred operation the gate parked — the tail of the approval
  # path (Ai::ApprovalRequest ultimately calls execute_now!). Without it the 202
  # example is vacuous: on the :pending branch the executor never runs during the
  # request, so "the peer is unchanged" proves nothing about the executor.
  def approve_latest_deferred!
    ::Ai::DeferredOperation.order(created_at: :desc).first.tap(&:execute_now!)
  end

  # Forces the gate's :proceed branch. A fresh spec account has no
  # InterventionPolicy rows, so InterventionPolicyService falls through to its
  # require_approval default; stub resolve to reach :proceed.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  it "requires system.sdwan.peers.manage" do
    patch_update(as: reader)

    expect(response).to have_http_status(:forbidden)
  end

  # The finding: this wrote the peer inline behind the permission check, so
  # sdwan.peer_update never resolved against anything.
  it "defers the update through the autonomy gate instead of writing inline" do
    patch_update

    expect(response).to have_http_status(:accepted)
    expect(json_response_data["pending"]).to eq(true)
    expect(peer.reload.tags).to eq([]), "the peer was changed without an approval gate"

    deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
    expect(deferred.action_category).to eq("sdwan.peer_update")
    expect(deferred.executor_class).to eq("Sdwan::Executors::UpdatePeer")
    expect(deferred.params["peer_id"]).to eq(peer.id)
    expect(deferred.params.dig("attributes", "tags")).to eq(["edge"])
  end

  # gate! never calls on_proceed on its :pending branch, so the executor is the
  # only thing that touches the row.
  it "applies the update when the deferred operation is approved" do
    patch_update

    approve_latest_deferred!

    expect(peer.reload.tags).to eq(["edge"]), "approved update left the peer unchanged"
  end

  it "updates inline and renders the row when the policy auto-approves" do
    auto_approve_policy!

    patch_update

    expect(response).to have_http_status(:ok)
    expect(peer.reload.tags).to eq(["edge"]), "answered ok over an unchanged peer"
    # 200-with-the-row is also what the UNGATED controller answered, so without
    # this the example cannot tell fixed from unfixed.
    expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdatePeer"),
                                                            "auto-approved update bypassed the gate entirely"
  end

  it "still answers 422 with field errors and opens no gate row for an invalid payload" do
    patch member_path, params: { peer: { listen_port: 0 } }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:unprocessable_content)
    expect(peer.reload.tags).to eq([])
    expect(::Ai::DeferredOperation.count).to eq(0),
                                             "an unsaveable update still opened an autonomy-gate audit row"
  end
end
