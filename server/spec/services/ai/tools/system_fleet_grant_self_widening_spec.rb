# frozen_string_literal: true

require "rails_helper"

# SECURITY (IMP-2110c94ad735) — an instance principal must not be able to WIDEN
# an MCP tool grant (or an A2A peer-skill grant).
#
# For an instance principal the grant glob is documented as the only remaining
# authorization control (Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS: "one
# over-broad pattern ... is an unattributed, unapproved, unaudited destroy").
# But the two verbs that REWRITE that grant are themselves ordinary tool names:
#
#   * Mcp::Principal.destructive_tool?("platform.system_grant_instance_mcp_tools")
#     is false — *revoke* covers removal, nothing covers WIDENING.
#   * McpPlatformToolRegistrar#enforce_permission! returns early for an
#     instance principal, and SystemFleetTool#action_permitted? does the same,
#     so ACTION_PERMISSIONS["system_grant_instance_mcp_tools"] is never read.
#   * enforce_action_scope! pins the executed action to the invoked name — and
#     the invoked name IS the grant-rewriting one.
#
# So the control was self-mutable: one call of `tool_patterns: ["platform.*"]`
# and the glob bounds nothing.
#
# ORACLE SHAPE: every refusal asserts the PERSISTED ROW is unchanged, never the
# response body (a guard that renders a refusal after the write still writes).
# Every refusal is paired with the OPPOSITE direction — narrowing, and the
# operator/user lane — so a "refuse everything" change cannot pass this file.
RSpec.describe Ai::Tools::SystemFleetTool, "instance-principal grant widening" do
  let(:account) { create(:account) }

  def announce(granted_mcp: [], granted_skills: [])
    inst = create(:system_node_instance, account: account, status: "running")
    peer = System::NodeInstancePeer.create!(
      node_instance: inst, account: inst.node.account,
      handle: "p-#{SecureRandom.hex(3)}", status: "active", enabled: true,
      trust_score: 0.5, daily_decision_budget: 10,
      granted_mcp_tools: granted_mcp, granted_peer_skills: granted_skills
    )
    [ inst, peer ]
  end

  # A call arriving exactly as the MCP layer builds it for an mTLS node cert:
  # no User, instance_authorized set by McpPlatformToolRegistrar, and the
  # caller's own node_instance carried across (BUG-S provenance writer).
  def instance_tool(own_instance)
    described_class.new(account: account, user: nil).tap do |t|
      t.instance_authorized = true
      t.node_instance = own_instance
    end
  end

  def call(tool, action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  describe "system_grant_instance_mcp_tools" do
    it "refuses a self-widening grant and leaves the persisted grant untouched" do
      inst, peer = announce(granted_mcp: %w[platform.system_list_nodes platform.dev_*])

      r = call(instance_tool(inst), "system_grant_instance_mcp_tools",
               instance_id: inst.id, tool_patterns: %w[platform.*], mode: "add")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/widen/i)
      expect(peer.reload.granted_mcp_tools)
        .to contain_exactly("platform.system_list_nodes", "platform.dev_*")
    end

    it "refuses a replace-shaped widening too (mode is not the control)" do
      inst, peer = announce(granted_mcp: %w[platform.dev_*])

      r = call(instance_tool(inst), "system_grant_instance_mcp_tools",
               instance_id: inst.id, tool_patterns: %w[platform.system_*], mode: "replace")

      expect(r[:success]).to be false
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.dev_*")
    end

    it "refuses widening a DIFFERENT instance's grant" do
      caller_inst, = announce(granted_mcp: %w[platform.*])
      _target_inst, target_peer = announce(granted_mcp: %w[platform.health])

      r = call(instance_tool(caller_inst), "system_grant_instance_mcp_tools",
               instance_id: target_peer.node_instance_id,
               tool_patterns: %w[platform.system_*], mode: "add")

      expect(r[:success]).to be false
      expect(target_peer.reload.granted_mcp_tools).to contain_exactly("platform.health")
    end

    # OWNERSHIP RUNG, ISOLATED. In the example above the target's grant is also
    # what `current` is compared against, so the widening rung refuses it too —
    # deleting the ownership branch would leave that example green. Here the
    # write is a genuine NARROWING of the target (it holds "platform.*"), which
    # the widening rung passes: only ownership can refuse it. Mutate each rung
    # separately or a redundant guard corrupts the oracle.
    it "refuses even a NARROWING write against a different instance (ownership rung alone)" do
      caller_inst, = announce(granted_mcp: %w[platform.health])
      _target_inst, target_peer = announce(granted_mcp: %w[platform.*])

      r = call(instance_tool(caller_inst), "system_grant_instance_mcp_tools",
               instance_id: target_peer.node_instance_id,
               tool_patterns: %w[platform.system_get_node], mode: "replace")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/OWN/)
      expect(target_peer.reload.granted_mcp_tools).to contain_exactly("platform.*")
    end

    # instance_authorized? is set for EVERY restricted principal
    # (streamable_http_controller: `current_mcp_principal&.restricted?`), which
    # includes a federation partner — and federation carries no node_instance.
    # A restricted call with no provenance must fail closed, not fall through
    # the ownership check.
    it "refuses a restricted call that carries no node_instance provenance" do
      _inst, peer = announce(granted_mcp: %w[platform.health])
      tool = described_class.new(account: account, user: nil).tap { |t| t.instance_authorized = true }

      r = call(tool, "system_grant_instance_mcp_tools",
               instance_id: peer.node_instance_id, tool_patterns: %w[platform.*])

      expect(r[:success]).to be false
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.health")
    end

    # --- the opposite direction: narrowing is explicitly still allowed -------

    it "PERMITS narrowing a glob to a literal name it already covered" do
      inst, peer = announce(granted_mcp: %w[platform.system_*])

      r = call(instance_tool(inst), "system_grant_instance_mcp_tools",
               instance_id: inst.id, tool_patterns: %w[platform.system_get_node], mode: "replace")

      expect(r[:success]).to be true
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.system_get_node")
    end

    it "PERMITS narrowing a glob to a narrower glob under the same prefix" do
      inst, peer = announce(granted_mcp: %w[platform.system_* platform.dev_*])

      r = call(instance_tool(inst), "system_grant_instance_mcp_tools",
               instance_id: inst.id, tool_patterns: %w[platform.system_get_*], mode: "replace")

      expect(r[:success]).to be true
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.system_get_*")
    end

    it "PERMITS a no-op re-grant of the patterns already held" do
      inst, peer = announce(granted_mcp: %w[platform.system_* platform.health])

      r = call(instance_tool(inst), "system_grant_instance_mcp_tools",
               instance_id: inst.id, tool_patterns: %w[platform.system_* platform.health], mode: "add")

      expect(r[:success]).to be true
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.system_*", "platform.health")
    end

    # --- the operator lane is untouched -------------------------------------

    it "still lets a user principal holding the permission widen a grant" do
      _inst, peer = announce(granted_mcp: %w[platform.health])
      operator = create(:user, account: account, permissions: %w[system.node_instances.manage])
      tool = described_class.new(account: account, user: operator)

      r = call(tool, "system_grant_instance_mcp_tools",
               instance_id: peer.node_instance_id, tool_patterns: %w[platform.*], mode: "add")

      expect(r[:success]).to be true
      expect(peer.reload.granted_mcp_tools).to include("platform.*")
    end

    it "still lets an in-process internal caller widen a grant" do
      _inst, peer = announce(granted_mcp: %w[platform.health])
      tool = described_class.new(account: account, user: nil, internal: true)

      r = call(tool, "system_grant_instance_mcp_tools",
               instance_id: peer.node_instance_id, tool_patterns: %w[platform.*], mode: "add")

      expect(r[:success]).to be true
      expect(peer.reload.granted_mcp_tools).to include("platform.*")
    end
  end

  # The A2A sibling is reachable by the same principal, with no ladder either:
  # granted_peer_skills is what NodeInstancePeer#may_invoke_peer_skill? reads.
  describe "system_grant_instance_peer_skills" do
    it "refuses a self-widening skill grant and leaves the persisted grant untouched" do
      inst, peer = announce(granted_skills: %w[embed-text])

      r = call(instance_tool(inst), "system_grant_instance_peer_skills",
               instance_id: inst.id, skill_patterns: %w[*], mode: "add")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/widen/i)
      expect(peer.reload.granted_peer_skills).to contain_exactly("embed-text")
    end

    it "refuses widening a DIFFERENT instance's skill grant" do
      caller_inst, = announce(granted_skills: %w[*])
      _target_inst, target_peer = announce(granted_skills: %w[embed-text])

      r = call(instance_tool(caller_inst), "system_grant_instance_peer_skills",
               instance_id: target_peer.node_instance_id, skill_patterns: %w[summarize], mode: "add")

      expect(r[:success]).to be false
      expect(target_peer.reload.granted_peer_skills).to contain_exactly("embed-text")
    end

    it "PERMITS narrowing its own skill grant" do
      inst, peer = announce(granted_skills: %w[embed-*])

      r = call(instance_tool(inst), "system_grant_instance_peer_skills",
               instance_id: inst.id, skill_patterns: %w[embed-text], mode: "replace")

      expect(r[:success]).to be true
      expect(peer.reload.granted_peer_skills).to contain_exactly("embed-text")
    end

    it "still lets a user principal holding the permission widen a skill grant" do
      _inst, peer = announce(granted_skills: %w[embed-text])
      operator = create(:user, account: account, permissions: %w[system.node_instances.manage])
      tool = described_class.new(account: account, user: operator)

      r = call(tool, "system_grant_instance_peer_skills",
               instance_id: peer.node_instance_id, skill_patterns: %w[*], mode: "add")

      expect(r[:success]).to be true
      expect(peer.reload.granted_peer_skills).to include("*")
    end
  end

  # A refusal must leave a row an operator can QUERY, not just a log line: the
  # control this rung backstops is the one core describes as standing between
  # an instance and an "unattributed, unapproved, unaudited" action.
  describe "refusal is auditable" do
    it "emits a high-severity fleet event naming caller, target and action" do
      inst, peer = announce(granted_mcp: %w[platform.health])

      expect {
        call(instance_tool(inst), "system_grant_instance_mcp_tools",
             instance_id: inst.id, tool_patterns: %w[platform.*], mode: "add")
      }.to change { System::FleetEvent.where(kind: "system.mcp_grant_widening_refused").count }.by(1)

      event = System::FleetEvent.where(kind: "system.mcp_grant_widening_refused").last
      expect(event.severity).to eq("high")
      expect(event.payload["action"]).to eq("system_grant_instance_mcp_tools")
      expect(event.payload["caller_instance_id"]).to eq(inst.id)
      expect(event.payload["target_instance_id"]).to eq(peer.node_instance_id)
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.health")
    end

    it "emits nothing for a permitted narrowing" do
      inst, = announce(granted_mcp: %w[platform.system_*])

      expect {
        call(instance_tool(inst), "system_grant_instance_mcp_tools",
             instance_id: inst.id, tool_patterns: %w[platform.system_get_node], mode: "replace")
      }.not_to change { System::FleetEvent.where(kind: "system.mcp_grant_widening_refused").count }
    end
  end

  # Unit coverage for the matcher itself — every clause exercised directly, so
  # a "simplification" of one of them cannot hide behind the end-to-end cases.
  describe "#grant_pattern_covered? (the non-widening predicate)" do
    subject(:matcher) { described_class.new(account: account, internal: true) }

    def covered?(current, incoming)
      matcher.send(:grant_pattern_covered?, current, incoming)
    end

    it "case 1 — an exact re-statement of a held pattern is covered" do
      expect(covered?(%w[platform.system_*], "platform.system_*")).to be true
    end

    it "case 2 — a held prefix glob covers a tighter glob under the same prefix" do
      expect(covered?(%w[platform.system_*], "platform.system_get_*")).to be true
      expect(covered?(%w[platform.system_*], "platform.dev_*")).to be false
    end

    it "case 3 — a literal name a held pattern already matches is covered" do
      expect(covered?(%w[platform.system_*], "platform.system_get_node")).to be true
      expect(covered?(%w[platform.system_*], "platform.health")).to be false
    end

    it "refuses a strictly wider glob" do
      expect(covered?(%w[platform.system_*], "platform.*")).to be false
      expect(covered?(%w[platform.system_*], "*")).to be false
    end

    it "will not use a META-BEARING prefix as a covering prefix" do
      # "platform.*improvement*" matches "platform.list_improvements" but NOT
      # every "platform.*..." string, so its text may not be used as a prefix.
      expect(covered?(%w[platform.*improvement*], "platform.*")).to be false
      expect(covered?(%w[platform.*improvement*], "platform.list_improvements")).to be true
    end

    it "will not use an ESCAPE-bearing prefix as a covering prefix" do
      # "platform.dev_\*" matches only the literal name "platform.dev_*".
      expect(covered?([ 'platform.dev_\*' ], 'platform.dev_\next_task')).to be false
    end

    it "does not let a wildcard cover a leading-period pattern (no FNM_DOTMATCH)" do
      expect(File.fnmatch("*", ".exfil", File::FNM_EXTGLOB)).to be false
      expect(covered?(%w[*], ".exfil")).to be false
      expect(covered?(%w[.*], ".exfil")).to be true
    end

    it "treats an empty or junk current grant as covering nothing" do
      expect(covered?([], "platform.health")).to be false
      expect(covered?(nil, "platform.health")).to be false
      expect(covered?([ nil ], "platform.health")).to be false
    end
  end

  # The guard must not change what an ALREADY-ISSUED grant authorizes: no
  # running instance may be stranded by shipping it. Mcp::Principal#may_invoke?
  # reads the stored patterns through the injected resolver and is not touched.
  describe "already-issued grants" do
    it "leaves may_invoke? verdicts for a stored grant byte-for-byte unchanged" do
      inst, peer = announce(granted_mcp: %w[platform.system_* platform.dev_*])
      principal = Mcp::Principal.new(kind: :instance, account: account,
                                     node_instance: inst, subject_id: inst.id)
      allow(Mcp::Principal).to receive(:tool_grant_resolver)
        .and_return(->(_i) { peer.reload.granted_mcp_tools })

      expect(principal.may_invoke?("platform.system_list_nodes")).to be true
      expect(principal.may_invoke?("platform.dev_next_task")).to be true
      expect(principal.may_invoke?("platform.health")).to be false
      # ... and the refusal above does not disturb them.
      call(instance_tool(inst), "system_grant_instance_mcp_tools",
           instance_id: inst.id, tool_patterns: %w[platform.*], mode: "add")
      expect(principal.may_invoke?("platform.system_list_nodes")).to be true
      expect(principal.may_invoke?("platform.health")).to be false
    end
  end
end
