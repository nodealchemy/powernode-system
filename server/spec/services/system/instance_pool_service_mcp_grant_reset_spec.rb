# frozen_string_literal: true

require "rails_helper"

# IMP-71c852bffc37: the reuse-without-reset release path already revokes the
# prior consumer's dev-cell deploy key for exactly this reason (a credential
# surviving a release boundary is cross-tenant leakage) but left
# granted_mcp_tools untouched right beside it -- the SAME hazard, unaddressed.
# A widening granted to one acquirer (system_grant_instance_mcp_tools, an
# operator/agent action) otherwise survives verbatim into the NEXT acquirer,
# because AgentPeeringService.announce! find_or_initializes the SAME peer row
# keyed on node_instance_id -- a reused pooled instance re-announces onto its
# own prior peer, carrying its grants forward unless something clears them.
# Isolated from the main pool spec (mirrors
# instance_pool_service_dev_cell_revoke_spec.rb) so it doesn't collide with
# concurrent edits to the heartbeat/recycle logic under a shared checkout.
RSpec.describe System::InstancePoolService, "reuse-without-reset MCP grant reset", type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:node) { create(:system_node, account: account, node_template: node_template, lifecycle_class: "ephemeral") }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "warm-devcell-pool",
      target_size: 1, min_size: 1, max_size: 3, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type,
      metadata: { "reuse_without_reset" => true }
    )
  end

  let(:instance) do
    create(:system_node_instance, node: node, name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud", status: "running", provider_region: provider_region,
           provider_instance_type: provider_instance_type, instance_pool_id: pool.id,
           pool_state: "claimed", pool_acquired_at: 1.minute.ago)
  end

  let!(:peer) { create(:system_node_instance_peer, node_instance: instance, account: account) }

  it "clears a widened MCP grant on release so it does not survive into the next acquirer" do
    peer.grant_mcp_tools!(["system_*", "platform.*"], mode: :replace)
    expect(peer.reload.granted_mcp_tools).to contain_exactly("system_*", "platform.*")

    result = described_class.release!(instance: instance, pool: pool)

    expect(result).to eq("reused")
    expect(instance.reload.pool_state).to eq("ready") # release still succeeds
    expect(peer.reload.granted_mcp_tools).to eq([])
  end

  it "is a no-op (no error) when the instance has never announced as a peer" do
    peer.destroy!

    expect { described_class.release!(instance: instance, pool: pool) }.not_to raise_error
  end

  it "leaves granted_peer_skills untouched (a distinct grant, out of this fix's scope)" do
    peer.grant_peer_skills!(["some-peer-skill"], mode: :replace)
    peer.grant_mcp_tools!(["system_*"], mode: :replace)

    described_class.release!(instance: instance, pool: pool)

    expect(peer.reload.granted_peer_skills).to eq(["some-peer-skill"])
  end

  it "still reuses the member when the grant reset raises (best-effort, non-blocking), " \
     "but is LOUD about it -- error log + a high-severity FleetEvent, never silent" do
    peer.grant_mcp_tools!(["system_*"], mode: :replace)
    allow_any_instance_of(System::NodeInstancePeer).to receive(:grant_mcp_tools!).and_raise(StandardError, "boom")
    expect(Rails.logger).to receive(:error).with(/granted_mcp_tools reset FAILED/)

    result = described_class.release!(instance: instance, pool: pool)

    expect(result).to eq("reused")
    expect(instance.reload.pool_state).to eq("ready")
    # Known residual: a failed reset means the member returns to the pool
    # still carrying the prior acquirer's grant -- exactly why this must
    # never be silent. The FleetEvent is the operator's signal to intervene.
    expect(peer.reload.granted_mcp_tools).to eq(["system_*"])

    event = System::FleetEvent.where(account: account, kind: "system.pool.mcp_grant_reset_failed").last
    expect(event).to be_present
    expect(event.severity).to eq("high")
    expect(event.payload["instance_id"]).to eq(instance.id)
    expect(event.payload["pool_id"]).to eq(pool.id)
  end

  it "does not reset an already-empty grant (no spurious write)" do
    expect(peer.granted_mcp_tools).to eq([])

    expect { described_class.release!(instance: instance, pool: pool) }
      .not_to change { peer.reload.updated_at }
  end
end
