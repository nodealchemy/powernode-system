# frozen_string_literal: true

require "rails_helper"

# IMP-01a05e92 — the K3s worker-join drill must mirror what the platform
# actually receives, and must say so where it cannot.
#
# The two service calls in the db-tier arm are wrong in OPPOSITE directions,
# which is why the inconsistency between them was the visible symptom:
#
#   join_request!      (phase=join_request) — the drill passes target_cluster_id,
#                      and NO AGENT EVER DOES. k3sd.HandshakeRequest
#                      .TargetClusterID is documented "NOT WIRED on the agent
#                      side ... no producer", and handle_join_request forwards
#                      params[:target_cluster_id] straight through. On a real
#                      fleet it is always nil, which is why an account with
#                      more than one non-error cluster cannot join a worker at
#                      all (409, not auto-select).
#
#   register_node_join! (phase=ready) — the drill USED to omit
#                      target_cluster_id, and the agent always sends it: the
#                      cached ClusterID is "Forwarded as target_cluster_id so
#                      the platform resolves the node's actual membership on
#                      every ready re-fire", and handle_k3s_ready passes it as
#                      such.
#
# The omission was invisible on a single-cluster account — auto-select resolves
# and every assertion passed — but that is precisely the branch a second
# cluster would never take, since auto-select REFUSES among candidates. So the
# drill exercised the one path a multi-cluster account cannot use, on the one
# call that CREATES the node row.
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

  it "marks the join_request! target as synthetic, since no agent supplies one" do
    expect(seed).to match(/SYNTHETIC ON PURPOSE|no agent ever sends/i)
    expect(seed).to match(/NOT WIRED/)
  end

  # THE FACTS THE COMMENTS REST ON. If either flips — someone wires a producer,
  # or the ready phase stops forwarding — these fail, and the drill's framing is
  # the next thing to revisit rather than a paragraph that quietly went stale.
  describe "the agent-side asymmetry the seed describes" do
    it "join_request's TargetClusterID still has no agent-side producer" do
      expect(handshake).to match(/NOT WIRED on the agent side/)
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
