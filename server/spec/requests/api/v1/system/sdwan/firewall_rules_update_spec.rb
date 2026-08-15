# frozen_string_literal: true

require "rails_helper"

# IMP-0e44cf2fc80b — gated-CRUD wiring, firewall-rule update.
#
# FirewallRulesController#update wrote through @rule.save behind the
# permission check alone, so the seeded sdwan.firewall_rule_update policy
# matched no gate call — while CREATE and DELETE on this same controller are
# gated. Unlike peer update (IMP-c159cc6777b1, a clean wiring), this verb
# carried a CONTROLLER-level transform: normalize_port_range re-keys the
# API's port_range {from:, to:} JSON shape to the model's mass-assignable
# port_range_hash accessor. gate! never calls on_proceed on :pending, so the
# transform had to migrate INTO Sdwan::Executors::UpdateFirewallRule before
# the wiring — the gate parks the API-shaped attributes verbatim, and the
# executor is the sole writer on the approved path.
#
# Response contract mirrors peers_update_spec.rb: an operator request carries
# no agent, the seeded sdwan.firewall_rule_update policy is
# ai_agent_id-scoped to the SDWAN Manager, so InterventionPolicyService falls
# through to its require_approval default — 202, the change applied only at
# approval time by the executor. The :proceed branch answers 200 with the
# serialized row.
RSpec.describe "Api::V1::System::Sdwan::FirewallRules update", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.firewall.manage", "system.sdwan.firewall.read") }
  let(:account) { user.account }
  let(:reader)  { user_with_permissions("system.sdwan.firewall.read", account: account) }

  let!(:network) { create(:sdwan_network, account: account) }
  let!(:rule) do
    create(:sdwan_firewall_rule, account: account, network: network, protocol: "tcp")
  end

  let(:payload) { { firewall_rule: { port_range: { from: 8000, to: 8080 } } } }

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/firewall_rules/#{rule.id}"

  def patch_update(as: user)
    patch member_path, params: payload.to_json,
          headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  # Forces the gate's :proceed branch. A fresh spec account has no
  # InterventionPolicy rows, so InterventionPolicyService falls through to its
  # require_approval default; stub resolve to reach :proceed.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  it "requires system.sdwan.firewall.manage" do
    patch_update(as: reader)

    expect(response).to have_http_status(:forbidden)
  end

  # The finding: this wrote the rule inline behind the permission check, so
  # sdwan.firewall_rule_update never resolved against anything.
  it "defers the update through the autonomy gate instead of writing inline" do
    patch_update

    expect(response).to have_http_status(:accepted)
    expect(json_response_data["pending"]).to eq(true)
    expect(rule.reload.dst_port_range).to be_nil,
                                          "the rule was changed without an approval gate"

    deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
    expect(deferred.action_category).to eq("sdwan.firewall_rule_update")
    expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateFirewallRule")
    expect(deferred.params["rule_id"]).to eq(rule.id)
    # The gate parks the API shape verbatim; the model's port_range= writer
    # owns the re-key on replay.
    expect(deferred.params.dig("attributes", "port_range", "from")).to eq(8000)
    expect(deferred.params.dig("attributes", "port_range", "to")).to eq(8080)
    # Matches UpdateFirewallRule#summarize verbatim so both surfaces of the
    # approval speak one sentence (IMP-3a563becb7d7).
    expect(deferred.description).to eq("Update firewall rule '#{rule.name}' on SDWAN network #{network.name}")
  end

  # THE load-bearing example (operator direction on IMP-0e44cf2fc80b): the
  # controller's inline normalize_port_range only ever ran on :proceed, so a
  # naive wiring passes every other example and fails exactly this one — an
  # approved update must still apply the port_range transform.
  it "applies the port_range transform when the deferred update is approved" do
    patch_update

    approve_latest_deferred!

    expect(rule.reload.port_range_hash).to eq({ from: 8000, to: 8080 }),
                                            "approved update dropped the port_range → port_range_hash transform"
  end

  it "updates inline, applies the transform, and renders the row when the policy auto-approves" do
    auto_approve_policy!

    patch_update

    expect(response).to have_http_status(:ok)
    expect(json_response_data.dig("firewall_rule", "port_range", "from")).to eq(8000)
    expect(rule.reload.port_range_hash).to eq({ from: 8000, to: 8080 }),
                                            "answered ok over an unchanged rule"
    # 200-with-the-row is also what the UNGATED controller answered, so
    # without this the example cannot tell fixed from unfixed.
    expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdateFirewallRule"),
                                                            "auto-approved update bypassed the gate entirely"
  end

  it "still answers 422 with field errors and opens no gate row for an invalid payload" do
    # A port range on a non-tcp/udp protocol violates
    # port_range_only_when_tcp_or_udp.
    patch member_path,
          params: { firewall_rule: { protocol: "icmp6", port_range: { from: 1, to: 2 } } }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:unprocessable_content)
    expect(rule.reload.protocol).to eq("tcp")
    expect(rule.dst_port_range).to be_nil
    expect(::Ai::DeferredOperation.count).to eq(0),
                                             "an unsaveable update still opened an autonomy-gate audit row"
  end
end
