# frozen_string_literal: true

require "rails_helper"

# Focused spec for FleetAutonomyService#dedup_key_for — the per-action dedup
# keys that stop repeat sensor firings from queuing duplicate ApprovalRequests
# every 60s tick. Kept separate from fleet_autonomy_service_spec (which skips in
# core mode because gate_action! needs the business-extension ApprovalChain);
# dedup_key_for is a pure method that runs fine in core mode.
RSpec.describe System::Fleet::FleetAutonomyService, "#dedup_key_for" do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { described_class.new(account: account, agent: agent) }

  def dedup(action, metadata)
    service.send(:dedup_key_for, action, metadata)
  end

  it "scopes system.federation_peer_remediate dedup to the federation peer" do
    expect(dedup("system.federation_peer_remediate", { "federation_peer_id" => "fp-1" }))
      .to eq([ "federation_peer_id", "fp-1" ])
  end

  it "falls back to action-level cooldown (nil) when federation_peer_id is absent" do
    expect(dedup("system.federation_peer_remediate", {})).to be_nil
  end

  it "keeps the analogous sdwan_peer_remediate dedup on peer_id" do
    expect(dedup("system.sdwan_peer_remediate", { "peer_id" => "p-9" }))
      .to eq([ "peer_id", "p-9" ])
  end

  it "returns nil for an unknown action (action-level cooldown only)" do
    expect(dedup("system.totally_unknown_action", { "x" => "y" })).to be_nil
  end

  # F3-08: honeypot quarantine signals may arrive without an instance target
  # when nothing currently hosts the canary module.
  it "scopes system.instance_terminate dedup to the instance when present" do
    expect(dedup("system.instance_terminate", { "instance_id" => "i-1", "module_id" => "m-1" }))
      .to eq([ "instance_id", "i-1" ])
  end

  it "falls back to module_id for system.instance_terminate when instance_id is absent" do
    expect(dedup("system.instance_terminate", { "module_id" => "m-1" }))
      .to eq([ "module_id", "m-1" ])
  end

  # Regression: an instance-wide system.module_drift routes to
  # system.module_assign, whose natural keys are module_id/module_version_id —
  # neither of which an instance-level drift carries. Before the signal_fingerprint
  # fallback this resolved to nil → no dedup → one ApprovalRequest minted per
  # escalation tick (the "Fleet Operator Approval" flood; imps 019f3cdc-efc9/d0a8).
  it "falls back to signal_fingerprint for instance-level module_assign (no module_id)" do
    metadata = {
      "instance_id" => "019f54fd-6083-754e-b4c1-0a571d3931a2",
      "signal_kind" => "system.module_drift",
      "signal_fingerprint" => "module_drift:019f54fd-6083-754e-b4c1-0a571d3931a2"
    }
    expect(dedup("system.module_assign", metadata))
      .to eq([ "signal_fingerprint", "module_drift:019f54fd-6083-754e-b4c1-0a571d3931a2" ])
  end

  it "prefers the natural module key over the fingerprint fallback for module_assign" do
    expect(dedup("system.module_assign", { "module_id" => "m-1", "signal_fingerprint" => "x:y" }))
      .to eq([ "module_id", "m-1" ])
  end

  # The fallback is universal: any signal-driven action that lacks its natural
  # key still dedups on the stamped fingerprint rather than the coarse
  # action-level cooldown.
  it "falls back to signal_fingerprint for any signal-driven action missing its natural key" do
    expect(dedup("system.federation_peer_remediate", { "signal_fingerprint" => "fp:1" }))
      .to eq([ "signal_fingerprint", "fp:1" ])
  end

  it "still returns nil for a non-signal action with no natural key and no fingerprint" do
    expect(dedup("system.federation_peer_remediate", {})).to be_nil
  end

  # IMP-17bc5546009a — system.sdwan_route_policy_audit was seeded (auto_approve,
  # dedup'd on route_policy_id) for a lane that has no sensor, no
  # DecisionEngine binding, and no executor. Removed rather than built per
  # operator direction (2026-08-21) — a compiled-policy-vs-FRR-observed drift
  # sensor is real work that should be chosen deliberately, not backed into
  # because a stray seed row exists. This pins the dedup arm gone.
  it "has no dedup arm for the removed system.sdwan_route_policy_audit lane" do
    expect(dedup("system.sdwan_route_policy_audit", { "route_policy_id" => "rp-1" })).to be_nil
  end
end
