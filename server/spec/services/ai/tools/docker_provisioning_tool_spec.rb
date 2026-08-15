# frozen_string_literal: true

require "rails_helper"

# IMP-9b9653e6514e — the seeded Runtime Manager policies had no gate site.
#
# `db/seeds/system_runtime_manager_agent.rb` seeds a policy row for
# `system.runtime_docker_provision` and `system.runtime_docker_decommission`,
# and those rows RENDER in the Autonomy modal — so an operator who sets
# `require_approval` (or `block`) on Docker daemon provisioning has been shown a
# control and told it works. Nothing read it: the only `executor_class:` binding
# in the tree for any `System::Executors::Runtime::*` class was
# DecommissionK3sCluster's, at devops/kubernetes/clusters_controller.rb. Both
# halves of these two gates — the category and the executor — already existed
# and were simply never joined.
#
# WHY THIS SPEC LIVES IN THE EXTENSION TREE while its subject
# (Ai::Tools::DockerProvisioningTool) is core: the assertions name
# System::Executors::Runtime::* and System::DockerDaemonProvisionerService, and
# core-purity gate #9 blocks a NEW core file naming a public extension. The
# tool's own file is grandfathered in .claude/hooks/core-purity-baseline.txt
# (it already wraps the extension's provisioner); a new core SPEC is not, and
# baselining one to host a spec would be the wrong way round. The behaviour
# under test is the system extension's runtime lifecycle either way.
#
# The oracle is deliberately the OBSERVABLE effect, not the return shape: under
# a `block` policy the daemon must not be provisioned and the host row must not
# be destroyed. A tool that returns a refusal payload while still performing the
# mutation would pass a shape assertion and fail this one.
RSpec.describe Ai::Tools::DockerProvisioningTool do
  before { ::System::InternalCaService.reset! }
  after  { ::System::InternalCaService.reset! }

  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:node)          { sdwan_test_node(account: account) }
  let(:node_instance) { sdwan_test_node_instance(node: node) }

  # DockerDaemonProvisionerService#provision! derives the daemon endpoint from
  # the instance's overlay address, so the peer is a prerequisite of the real
  # provisioning path (mirrors provision_docker_host_spec.rb's setup).
  let!(:network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "docker-provisioning-tool-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let!(:peer) do
    ::Sdwan::Peer.create!(
      account: account,
      sdwan_network_id: network.id,
      node_instance: node_instance,
      publicly_reachable: false
    )
  end

  # Operator-path row: scope "action_type", agent-less. This is the shape
  # AgentSetupHelpers.upsert_operator_policies! seeds and the only shape an
  # agent-less caller can match — Ai::InterventionPolicy#agent_matches? rejects
  # an agent-SCOPED row against a nil agent.
  def operator_policy!(category, verb)
    ::Ai::InterventionPolicy.create!(
      account: account, action_category: category, scope: "action_type",
      ai_agent_id: nil, policy: verb, priority: 5, is_active: true
    )
  end

  def agent_policy!(agent, category, verb)
    ::Ai::InterventionPolicy.create!(
      account: account, action_category: category, scope: "agent",
      ai_agent_id: agent.id, policy: verb, priority: 10, is_active: true
    )
  end

  # Account-wide floor: scope "global", agent-less. Distinct from the operator
  # path above — this audience binds BOTH callers (IMP-cb36021d4094).
  def global_policy!(category, verb)
    ::Ai::InterventionPolicy.create!(
      account: account, action_category: category, scope: "global",
      ai_agent_id: nil, user_id: nil, policy: verb, priority: 5, is_active: true
    )
  end

  def operator_tool
    described_class.new(account: account, user: user)
  end

  def provision!(tool = operator_tool)
    tool.execute(params: { action: "system_provision_docker_runtime",
                           node_instance_id: node_instance.id })
  end

  def managed_hosts
    ::Devops::DockerHost.managed.where(node_instance_id: node_instance.id)
  end

  describe "system_provision_docker_runtime" do
    it "refuses and provisions nothing when the operator's policy is block" do
      operator_policy!("system.runtime_docker_provision", "block")

      result = provision!

      expect(result[:success]).to be(false)
      expect(managed_hosts).not_to exist,
                                   "the operator's block policy was not consulted — a daemon was provisioned anyway"
    end

    it "proceeds under notify_and_proceed and records the gated operation" do
      operator_policy!("system.runtime_docker_provision", "notify_and_proceed")

      result = provision!

      expect(result[:success]).to be(true)
      expect(managed_hosts.count).to eq(1)
      expect(result[:host]).to include(id: managed_hosts.first.id)

      operation = ::Ai::DeferredOperation.find_by(
        account: account, action_category: "system.runtime_docker_provision"
      )
      expect(operation).to be_present,
                           "no audit row — the action did not travel through Ai::AutonomyGate"
      expect(operation.executor_class).to eq("System::Executors::Runtime::ProvisionDockerHost")
      expect(operation.requested_by_id).to eq(user.id)
    end

    # The require_approval branch is the one that changes an operator's day:
    # the mutation must be PARKED, not performed, and the caller told so.
    it "parks for approval under require_approval instead of provisioning" do
      operator_policy!("system.runtime_docker_provision", "require_approval")

      result = provision!

      expect(managed_hosts).not_to exist,
                                   "require_approval provisioned the daemon anyway — the approval is decorative"
      expect(result[:pending]).to be(true)
      expect(result[:approval_request_id]).to be_present
    end

    # Audience separation. The seeded Runtime Manager rows are agent-scoped, so
    # they bind only when the caller passes `agent:`. An MCP call made BY the
    # agent must resolve against them.
    it "binds the agent-scoped policy for an agent caller" do
      agent = create(:ai_agent, account: account, provider: provider, name: "Runtime Manager")
      agent_policy!(agent, "system.runtime_docker_provision", "block")

      result = provision!(described_class.new(account: account, agent: agent))

      expect(result[:success]).to be(false)
      expect(managed_hosts).not_to exist,
                                   "the agent-scoped policy did not bind an agent-dispatched provision"
    end

    # IMP-cb36021d4094 — this tool is the seam where both halves of the audience
    # cut are observable, because it is dual-audience: an operator MCP call
    # arrives with `agent` nil, an agent dispatch through
    # system_provision_docker_runtime arrives with it set.
    #
    # The oracle is the REFUSAL, not the parking. While the cut keyed on
    # ai_agent_id, an account-wide block resolved to require_approval for an
    # agent caller, and require_approval is not a denial — the gate opens an
    # ApprovalRequest whose default chain resolves to every active user, so the
    # operator's "never" became "one click from any user". A `pending: true`
    # payload here is the bug, not a near-miss.
    it "refuses an agent-dispatched provision under an account-wide (scope global) block" do
      agent = create(:ai_agent, account: account, provider: provider, name: "Runtime Manager")
      global_policy!("system.runtime_docker_provision", "block")

      result = provision!(described_class.new(account: account, agent: agent))

      expect(managed_hosts).not_to exist
      expect(result[:pending]).to be_falsey,
                                  "the account-wide block became an approval any user could grant"
      expect(result[:success]).to be(false)
      expect(::Ai::ApprovalRequest.where(account: account)).not_to exist
    end

    # Same row, the other audience. Non-vacuity for the example above: the
    # global floor is not agent-only either.
    it "refuses an operator-dispatched provision under the same account-wide block" do
      global_policy!("system.runtime_docker_provision", "block")

      result = provision!

      expect(result[:success]).to be(false)
      expect(managed_hosts).not_to exist
    end

    # The fail-safe half at the seam: a global relaxation must actually reach an
    # agent dispatch, or the audience is only half-restored.
    it "proceeds on an agent dispatch under a scope-global auto_approve" do
      agent = create(:ai_agent, account: account, provider: provider, name: "Runtime Manager")
      global_policy!("system.runtime_docker_provision", "auto_approve")

      result = provision!(described_class.new(account: account, agent: agent))

      expect(result[:success]).to be(true)
      expect(managed_hosts.count).to eq(1)
      expect(
        ::Ai::DeferredOperation.find_by(account: account,
                                        action_category: "system.runtime_docker_provision")&.ai_agent_id
      ).to eq(agent.id), "the dispatch lost its agent attribution"
    end
  end

  describe "system_decommission_docker_runtime" do
    let!(:host) do
      ::System::DockerDaemonProvisionerService.provision!(
        node_instance: node_instance, account: account
      )
    end

    def decommission!(tool = operator_tool)
      tool.execute(params: { action: "system_decommission_docker_runtime", host_id: host.id })
    end

    it "parks for approval under require_approval and leaves the host standing" do
      operator_policy!("system.runtime_docker_decommission", "require_approval")

      result = decommission!

      expect(::Devops::DockerHost.where(id: host.id)).to exist,
                                                         "require_approval tore the host down anyway — the approval is decorative"
      expect(result[:pending]).to be(true)
      expect(result[:approval_request_id]).to be_present
    end

    it "refuses and leaves the host standing when the policy is block" do
      operator_policy!("system.runtime_docker_decommission", "block")

      result = decommission!

      expect(result[:success]).to be(false)
      expect(::Devops::DockerHost.where(id: host.id)).to exist
    end

    # Non-vacuity control for the two examples above: the gate must not be a
    # blanket refusal. With the operator's recorded verb set to auto_approve the
    # teardown still happens, through the executor.
    it "tears the host down under auto_approve" do
      operator_policy!("system.runtime_docker_decommission", "auto_approve")

      result = decommission!

      expect(result[:success]).to be(true)
      expect(::Devops::DockerHost.where(id: host.id)).not_to exist
      expect(
        ::Ai::DeferredOperation.find_by(account: account,
                                        action_category: "system.runtime_docker_decommission")&.executor_class
      ).to eq("System::Executors::Runtime::DecommissionDockerHost")
    end

    # Unchanged by the gate: a host the caller may not see must still be
    # reported missing BEFORE any policy is consulted, so a cross-account probe
    # cannot learn what an account's policy says by reading the refusal wording.
    it "still reports an unknown host without opening the gate" do
      operator_policy!("system.runtime_docker_decommission", "auto_approve")
      unknown = SecureRandom.uuid

      result = operator_tool.execute(
        params: { action: "system_decommission_docker_runtime", host_id: unknown }
      )

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("not found")
      expect(::Ai::DeferredOperation.where(account: account)).not_to exist
    end
  end

  # The ungated actions of this tool must stay ungated: mark_ready is the
  # agent's own heartbeat promotion and list is a read. Gating either would be
  # scope creep with a live cost (a heartbeat that parks for approval).
  describe "actions outside the gated set" do
    let!(:host) do
      ::System::DockerDaemonProvisionerService.provision!(
        node_instance: node_instance, account: account
      )
    end

    it "promotes a pending host on mark_ready without consulting a policy" do
      operator_policy!("system.runtime_docker_provision", "block")

      result = operator_tool.execute(
        params: { action: "system_mark_docker_ready", host_id: host.id, docker_version: "25.0.3" }
      )

      expect(result[:success]).to be(true)
      expect(host.reload.status).to eq("connected")
      expect(::Ai::DeferredOperation.where(account: account)).not_to exist
    end
  end
end
