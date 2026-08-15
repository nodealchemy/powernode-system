# frozen_string_literal: true

require "rails_helper"

# IMP-c9798d9d5671 — gated-CRUD wiring, route-policy resource. Per-executor
# re-parent analysis (the IMP-c159cc6777b1 contract): UpdateRoutePolicy's
# attrs can carry scope_resource_id, a caller-suppliable id naming a
# Sdwan::Network (scope "network") or Sdwan::Peer (scope "peer"). The model
# validates only presence/consistency (scope_resource_consistency), never
# ownership; RoutePolicy#applicable_to filters by account at compile today,
# so a foreign id is currently inert downstream — but it would persist a
# silent dangling foreign reference, so the anchor_reparent! convention
# applies. The kind the id is anchored against is the EFFECTIVE scope: the
# incoming attrs[:scope] when the update changes it, else the row's own.
RSpec.describe Sdwan::Executors::UpdateRoutePolicy do
  let(:account) { create(:account) }
  let!(:policy) { create(:sdwan_route_policy, account: account, name: "orig") }

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.route_policy_update",
      executor_class: "Sdwan::Executors::UpdateRoutePolicy",
      params: params,
      source_type: "Sdwan::RoutePolicy",
      source_id: policy.id
    )
  end

  # Captures rather than leading with raise_error, so a failing example reports
  # the effect it exists to prevent, not just "nothing was raised".
  def run(params)
    described_class.execute(params, deferred_operation: deferred_for(params))
    nil
  rescue StandardError => e
    e
  end

  it "applies an in-account update" do
    error = run({ policy_id: policy.id, attributes: { name: "renamed", enabled: false } })

    expect(error).to be_nil
    expect(policy.reload.name).to eq("renamed")
    expect(policy.enabled).to be false
  end

  it "refuses to update a policy in another account (resolve_scoped is the guard)" do
    foreign = create(:sdwan_route_policy, name: "victim")

    error = run({ policy_id: foreign.id, attributes: { name: "stolen" } })

    expect(foreign.reload.name).to eq("victim"),
                                   "the executor mutated a policy outside the operation's account"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    expect(error.message).not_to include(foreign.account_id)
  end

  it "anchors an in-account network scope_resource_id" do
    network = create(:sdwan_network, account: account)

    error = run({ policy_id: policy.id,
                  attributes: { scope: "network", scope_resource_id: network.id } })

    expect(error).to be_nil
    expect(policy.reload.scope).to eq("network")
    expect(policy.scope_resource_id).to eq(network.id)
  end

  it "refuses a re-parent onto a FOREIGN network via scope/scope_resource_id" do
    foreign_network = create(:sdwan_network)

    error = run({ policy_id: policy.id,
                  attributes: { scope: "network", scope_resource_id: foreign_network.id } })

    expect(policy.reload.scope_resource_id).not_to eq(foreign_network.id),
                                                   "the executor persisted a dangling reference to a foreign network"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    expect(error.message).not_to include(foreign_network.account_id)
  end

  # The effective kind falls back to the ROW's scope when the update carries
  # only the resource id.
  it "refuses a foreign peer scope_resource_id under the row's existing peer scope" do
    own_network = create(:sdwan_network, account: account)
    own_peer = create(:sdwan_peer, account: account, network: own_network)
    policy.update!(scope: "peer", scope_resource_id: own_peer.id)
    foreign_peer = create(:sdwan_peer)

    error = run({ policy_id: policy.id, attributes: { scope_resource_id: foreign_peer.id } })

    expect(policy.reload.scope_resource_id).to eq(own_peer.id),
                                               "the executor persisted a dangling reference to a foreign peer"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
  end

  # Negative control's positive twin: account scope names no resource, so no
  # anchor fires and the update applies.
  it "applies an account-scope update with no resource id" do
    error = run({ policy_id: policy.id, attributes: { scope: "account", scope_resource_id: nil, name: "acct" } })

    expect(error).to be_nil
    expect(policy.reload.scope).to eq("account")
    expect(policy.name).to eq("acct")
  end
end
