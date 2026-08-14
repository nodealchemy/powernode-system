# frozen_string_literal: true

require "rails_helper"

# IMP-0e44cf2fc80b — gated-CRUD wiring, VIP update.
#
# VirtualIpsController#update wrote through @vip.update(vip_params) behind the
# permission check alone, so the seeded sdwan.virtual_ip_update policy matched
# no gate call — while CREATE, DELETE, and manual failover on this same
# controller are gated. Unlike peer update (IMP-c159cc6777b1, a clean wiring),
# this verb carried a CONTROLLER-level side-effect:
# sync_assignments_after_holder_change!, the holder audit trail. gate! never
# calls on_proceed on :pending, so the sync had to migrate INTO
# Sdwan::Executors::UpdateVirtualIp before the wiring — a naive wiring would
# apply an approved holder change while silently dropping the assignment sync.
#
# Response contract mirrors peers_update_spec.rb: an operator request carries
# no agent, the seeded sdwan.virtual_ip_update policy is ai_agent_id-scoped to
# the SDWAN Manager, so InterventionPolicyService falls through to its
# require_approval default — 202, the change applied only at approval time by
# the executor. The :proceed branch answers 200 with the serialized row.
RSpec.describe "Api::V1::System::Sdwan::VirtualIps update", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.vips.manage", "system.sdwan.vips.read") }
  let(:account) { user.account }
  let(:reader)  { user_with_permissions("system.sdwan.vips.read", account: account) }

  let!(:network)    { create(:sdwan_network, account: account) }
  let!(:old_holder) { create(:sdwan_peer, account: account, network: network) }
  let!(:new_holder) { create(:sdwan_peer, account: account, network: network) }
  let!(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network,
                              state: "active", holder_peer_ids: [ old_holder.id ])
  end
  let!(:current_assignment) do
    vip.assignments.create!(peer: old_holder, assumed_at: 1.hour.ago, reason: "initial")
  end

  let(:payload) { { virtual_ip: { holder_peer_ids: [ new_holder.id ] } } }

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips/#{vip.id}"

  def patch_update(as: user)
    patch member_path, params: payload.to_json,
          headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  # Executes the deferred operation the gate parked — the tail of the approval
  # path (Ai::ApprovalRequest ultimately calls execute_now!). Without it the
  # 202 example is vacuous: on the :pending branch the executor never runs
  # during the request, so "the vip is unchanged" proves nothing.
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

  it "requires system.sdwan.vips.manage" do
    patch_update(as: reader)

    expect(response).to have_http_status(:forbidden)
  end

  # The finding: this wrote the VIP inline behind the permission check, so
  # sdwan.virtual_ip_update never resolved against anything.
  it "defers the update through the autonomy gate instead of writing inline" do
    patch_update

    expect(response).to have_http_status(:accepted)
    expect(json_response_data["pending"]).to eq(true)
    expect(vip.reload.holder_peer_ids).to eq([ old_holder.id ]),
                                          "the VIP was changed without an approval gate"

    deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
    expect(deferred.action_category).to eq("sdwan.virtual_ip_update")
    expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateVirtualIp")
    expect(deferred.params["vip_id"]).to eq(vip.id)
    expect(deferred.params.dig("attributes", "holder_peer_ids")).to eq([ new_holder.id ])
    # Matches UpdateVirtualIp#summarize verbatim so both surfaces of the
    # approval speak one sentence (IMP-3a563becb7d7).
    expect(deferred.description).to eq("Update SDWAN VIP '#{vip.name}' on network #{network.name}")
  end

  # THE load-bearing example (operator direction on IMP-0e44cf2fc80b): the
  # controller's inline sync only ever ran on :proceed, so a naive wiring
  # passes every other example and fails exactly this one — an approved
  # holder change must sync the assignment audit trail too.
  it "syncs holder assignments when the deferred update is approved" do
    patch_update

    approve_latest_deferred!

    expect(vip.reload.holder_peer_ids).to eq([ new_holder.id ]),
                                          "approved update left the VIP unchanged"
    expect(current_assignment.reload.released_at).to be_present,
                                                     "approved holder change never released the departed holder's assignment row"

    arrived = vip.assignments.where(sdwan_peer_id: new_holder.id, released_at: nil).first
    expect(arrived).to be_present,
                       "approved holder change left phantom holder state with no assignment history row"
    expect(arrived.reason).to eq("holder_changed")
    expect(arrived.triggered_by_user_id).to eq(user.id),
                                            "the assignment must attribute the REQUESTING operator across the approval window"
  end

  it "updates inline, syncs assignments, and renders the row when the policy auto-approves" do
    auto_approve_policy!

    patch_update

    expect(response).to have_http_status(:ok)
    expect(json_response_data.dig("virtual_ip", "holder_peer_ids")).to eq([ new_holder.id ])
    expect(vip.reload.holder_peer_ids).to eq([ new_holder.id ]), "answered ok over an unchanged VIP"
    expect(current_assignment.reload.released_at).to be_present,
                                                     ":proceed update lost the holder assignment sync"
    # 200-with-the-row is also what the UNGATED controller answered, so
    # without this the example cannot tell fixed from unfixed.
    expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdateVirtualIp"),
                                                            "auto-approved update bypassed the gate entirely"
  end

  it "still answers 422 with field errors and opens no gate row for an invalid payload" do
    # anycast with a single holder violates anycast_requires_holder_set.
    patch member_path, params: { virtual_ip: { anycast: true } }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:unprocessable_content)
    expect(vip.reload.anycast?).to eq(false)
    expect(::Ai::DeferredOperation.count).to eq(0),
                                             "an unsaveable update still opened an autonomy-gate audit row"
  end
end
