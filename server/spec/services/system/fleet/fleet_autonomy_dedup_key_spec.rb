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
end
