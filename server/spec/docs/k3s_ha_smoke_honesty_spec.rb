# frozen_string_literal: true

require "rails_helper"

# IMP-01a05dce — the HA smoke drill must not read as proof of HA.
#
# smoke_test_k3s_ha_control_plane.rb described itself as adding two
# k3s-server NodeInstances "to form a 3-server HA control plane", and at the db
# tier it called System::KubernetesClusterProvisionerService.register_node_join!
# with role "server" directly at the service layer. That is a call the AGENT
# cannot make, and the gap is checkable rather than a matter of opinion:
#
#   * agent/internal/k3sd/applier.go — BootstrapConfig carries CNI knobs only,
#     with no server URL and no join token, so `k3s server` can never be told
#     to join an existing cluster;
#   * agent/internal/k3sd/server_manager.go — ServerManager's state machine has
#     no join branch; its step 5 is "cluster NOT yet bootstrapped → Bootstrap".
#
# So a green run evidenced VirtualIp bookkeeping and nothing more, while
# reading as an HA control plane — and at site+ it waited 600s for a
# node_count that could never arrive.
#
# THE DRILL IS KEPT. The VirtualIp half is real coverage. What this pins is
# that the file keeps saying what it does and does not prove, because that
# sentence is the whole difference between useful coverage and a synthetic
# proof of a capability that does not exist.
RSpec.describe "smoke_test_k3s_ha_control_plane.rb honesty (IMP-01a05dce)" do
  ext_root = File.expand_path("../../..", __dir__)

  let(:seed) { File.read(File.join(ext_root, "server/db/seeds/smoke_test_k3s_ha_control_plane.rb")) }

  it "exists where this spec expects it" do
    expect(File).to exist(File.join(ext_root, "server/db/seeds/smoke_test_k3s_ha_control_plane.rb"))
  end

  it "states that K3s HA is NOT implemented" do
    expect(seed).to match(/HA is NOT IMPLEMENTED|NOT IMPLEMENTED.*HA/i)
  end

  # The reason, not just the verdict: a verdict alone invites someone to
  # "fix" the seed by re-adding the wait.
  it "cites the checkable agent-side reason" do
    expect(seed).to match(/BootstrapConfig/)
    expect(seed).to match(/ServerManager/)
    expect(seed).to match(/join (branch|token|path)/i)
  end

  it "does not claim to FORM an HA control plane" do
    expect(seed).not_to match(/to form a[n]? .*HA control plane/i)
    expect(seed).not_to match(/^#.*adds 2 more k3s-server NodeInstances to form/i)
  end

  # The 600s poll for a node_count that cannot arrive is the specific waste
  # this closes: at site+ the run must refuse by name instead.
  it "no longer waits for an agent-driven server join that cannot happen" do
    expect(seed).not_to match(/wait_until\(timeout:\s*600,\s*label:\s*"cluster\.node_count/)
    expect(seed).to match(/fail_with\(/)
  end

  it "describes node_count as platform-side rows rather than a quorum" do
    expect(seed).to match(/platform-side rows/)
  end

  # The agent-side facts this spec's reasoning rests on. If either stops being
  # true — someone adds a join path — these fail, and the seed's refusal is the
  # next thing to revisit rather than a sentence that quietly went stale.
  describe "the agent-side gap the seed cites" do
    let(:applier) { File.read(File.join(ext_root, "agent/internal/k3sd/applier.go")) }
    let(:server_manager) { File.read(File.join(ext_root, "agent/internal/k3sd/server_manager.go")) }

    it "BootstrapConfig still carries no server URL and no join token" do
      struct = applier[/type BootstrapConfig struct \{(.*?)\n\}/m, 1]
      expect(struct).not_to be_nil, "BootstrapConfig struct not found"
      expect(struct).not_to match(/ServerURL|JoinToken|Token\b/i),
        "BootstrapConfig grew a join field — the seed's refusal may now be wrong:\n#{struct}"
    end

    it "ServerManager still has no server-join branch" do
      expect(server_manager).not_to match(/transitionJoin|JoinExisting|joinCluster/i)
    end
  end
end
