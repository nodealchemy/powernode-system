# frozen_string_literal: true

require "rails_helper"

# IMP-01a05e92 — the K3s worker-join drill must mirror what the platform
# actually receives, and must say so where it cannot.
#
# UPDATED FOR IMP-a5f236e8cc56 (2026-09-17): the join_request! call below is
# no longer synthetic because "no agent ever sends this" — a real agent now
# can, via k3sd.HTTPAgentConfigClient + the k3s-agent module assignment's
# config. It is synthetic because THIS DRILL runs at the db tier, which never
# starts the agent binary and calls the platform service directly instead.
# That distinction is exactly the scope-over-claim shape SMOKE_TEST.md already
# documents for this seed's default tier — a green run evidences the platform
# service, not the agent-side delivery path.
#
#   join_request!      (phase=join_request) — the drill passes target_cluster_id
#                      directly at the service layer. handle_join_request
#                      forwards params[:target_cluster_id] straight through,
#                      unchanged by IMP-a5f236e8cc56. On a real fleet an agent
#                      now sends a real value when the k3s-agent assignment's
#                      config names one; an unconfigured (or unresolvable)
#                      target still resolves only by single-cluster
#                      auto-select, and an account with more than one
#                      non-error cluster and no usable target still refuses
#                      the join (409), rather than guessing.
#
#   register_node_join! (phase=ready) — the drill USED to omit
#                      target_cluster_id, and the agent always sends it: the
#                      cached ClusterID is "Forwarded as target_cluster_id so
#                      the platform resolves the node's actual membership on
#                      every ready re-fire", and handle_k3s_ready passes it as
#                      such. Unaffected by IMP-a5f236e8cc56 — this phase never
#                      consulted the config-sourced target, only the cached
#                      join.
#
# The omission was invisible on a single-cluster account — auto-select resolves
# and every assertion passed — but that is precisely the branch a second
# cluster would never take, since auto-select REFUSES among candidates. So the
# drill exercised the one path an unconfigured multi-cluster account cannot
# use, on the one call that CREATES the node row.
RSpec.describe "smoke_test_k3s_agent_join.rb cluster targeting (IMP-01a05e92)" do
  ext_root = File.expand_path("../../..", __dir__)

  let(:seed) { File.read(File.join(ext_root, "server/db/seeds/smoke_test_k3s_agent_join.rb")) }
  let(:handlers) do
    File.read(File.join(ext_root, "server/app/controllers/concerns/system/runtime_handshake_handlers.rb"))
  end
  let(:handshake) { File.read(File.join(ext_root, "agent/internal/k3sd/handshake.go")) }

  # The creating call must carry the target, like the real handler does.
  it "passes target_cluster_id to register_node_join!" do
    call = seed[/register_node_join!\((.*?)\)\n/m, 1]
    expect(call).not_to be_nil, "register_node_join! call not found"
    expect(call).to match(/target_cluster_id:/),
      "the node-creating call omits the target the agent always sends:\n#{call}"
  end

  it "marks the join_request! target as synthetic because the drill bypasses the agent" do
    expect(seed).to match(/SYNTHETIC ON PURPOSE/)
    expect(seed).to match(/db tier never runs the agent binary/)
  end

  # THE FACTS THE COMMENTS REST ON. If either flips — the producer is reverted,
  # or the ready phase stops forwarding — these fail, and the drill's framing is
  # the next thing to revisit rather than a paragraph that quietly went stale.
  describe "the agent-side asymmetry the seed describes" do
    # IMP-a5f236e8cc56 flipped this trip-wire's polarity: it used to assert
    # the producer's ABSENCE; now it asserts the producer's EXISTENCE, so a
    # future revert (someone reverting the HTTPAgentConfigClient wiring)
    # reddens this exactly the way the original wiring reddened it.
    it "join_request's TargetClusterID now has an agent-side producer" do
      expect(handshake).to match(/WIRED end to end/)
      expect(handshake).not_to match(/NOT WIRED on the agent side/)
    end

    it "the ready phase still forwards the cached cluster_id as target_cluster_id" do
      expect(handshake).to match(/Forwarded as target_cluster_id/)
    end

    it "handle_k3s_ready still passes target_cluster_id through" do
      ready = handlers[/def handle_k3s_ready(.*?)\n    end/m, 1]
      expect(ready).not_to be_nil, "handle_k3s_ready not found"
      expect(ready).to match(/target_cluster_id:\s*params\[:cluster_id\]/)
    end
  end
end
