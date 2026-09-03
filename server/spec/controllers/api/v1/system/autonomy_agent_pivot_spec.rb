# frozen_string_literal: true

require "rails_helper"

# IMP-e3a30e2dd5ee — `System::AutonomyActions::SYSTEM_AGENT_NAMES` and the
# `by_agent` pivot it drives (GET /api/v1/system/autonomy).
#
# The constant is a hand-maintained literal naming the system agents the pivot
# builds a bucket for; `by_agent_pivot` then DROPS any row whose owning agent
# is not one of them. It listed five while the extension's seeds bind
# agent-scoped policy rows to six — the GitOps Reconciler (added later, in the
# same wave as the System Topology Designer) was never added, so its three
# `system.gitops_*` rows were absent from that view.
#
# SCOPE OF THE DEFECT, stated because it is narrower than "the operator cannot
# see them": since IMP-0874acd5b50c the Settings modal renders from `by_domain`
# and keys each row by the `agent_bucket` the row itself carries, so those rows
# DO reach the operator and DO save. What drifted is the endpoint's internal
# agreement — one payload shipping rows in `by_domain` that its own `by_agent`
# view and its own `agents` list deny exist. The guard below is therefore about
# the CONSTANT tracking its source of truth, not about a broken panel.
#
# The oracle is DERIVED rather than restated as a second literal, for the
# reason the sibling autonomy_domain_pivot_spec.rb derives its category set the
# same way: a list that drifted once will drift again, and an oracle that is
# itself a hand-maintained copy drifts with it.
#
# WHAT IT DERIVES FROM (HIER-P2DECL): the DECLARATIONS —
# PolicyDeclarations::POLICY_SETS × AGENT_IDENTITIES, every agent that keys an
# agent-scoped set. That is the population PolicyReconciler writes agent-scoped
# rows for on every boot, which since HIER-P2A is the writer of record; the
# seed files are the first-boot copy of the same declarations, and since wave 1
# they LAG them by design (the four managers' sets are declared before their
# seeds exist, so the pivot has a bucket waiting the first boot after wave 2).
# The seed scan is KEPT as the second direction: every agent a seed writes
# agent-scoped rows for must be a declared owner, or the seed is writing rows
# the reconciler and the tick do not know about.
#
# Deriving the ORACLE, not the CONSTANT. The constant stays a literal on
# purpose: the two sound runtime sources are both wrong here. Reading db/seeds
# at request time is not available to a controller, and deriving the set from
# the account's own policy rows would make the pivot's shape a function of the
# data it is pivoting — an account with no rows yet would report no system
# agents, and any operator's own agent holding one system policy would be
# promoted into the extension's agent list.
RSpec.describe "Api::V1::System::Autonomy by_agent pivot", type: :request do
  let(:account) { create(:account) }
  let(:read_user) { user_with_permissions("system.infra_tasks.read", account: account) }

  let(:seed_dir) { File.expand_path("../../../../../db/seeds", __dir__) }

  # Which files to scan: anything that can write a policy row at all — the
  # shared helper (`upsert_policies!`, which hardcodes scope "agent") or a
  # direct `Ai::InterventionPolicy` write.
  #
  # Gating on the literal `scope: "agent"` instead is too narrow, and provably
  # so rather than theoretically: `system_provisioning_intervention_policies.rb`
  # writes agent-scoped rows through `scope = fleet_agent ? "agent" : "global"`
  # and then `scope: scope`, so the literal never appears and the whole file
  # went unscanned. It contributes Fleet Autonomy, which another seed supplies
  # anyway — so the omission changed no result and was invisible. That is
  # exactly the shape of drift this file exists to catch, and the reason the
  # gate is deliberately loose: a file that writes only global/action_type rows
  # (`system_manual_operation_policies.rb`) resolves no agent name and still
  # contributes nothing, and the "no empty bucket" example rejects anything
  # spurious that does slip through.
  #
  # Two shapes name the agent: the agent's OWN seed declares it through
  # `find_or_initialize_global_agent`, and a sibling policy seed resolves an
  # already-seeded agent through `Ai::Agent.resolve_for`. One seed passes a
  # local variable rather than a literal, so an identifier is resolved back to
  # its assignment in the same file. A name this cannot resolve is DROPPED
  # rather than guessed — silently, which is why the integrity example below
  # exists as well as the vacuity one.
  def policy_agent_names_in(source)
    return [] unless source.include?("upsert_policies!") || source.include?("Ai::InterventionPolicy")

    declared = source.scan(
      /find_or_initialize_global_agent\(\s*name:\s*(?:"([^"]+)"|([a-z_][a-zA-Z0-9_]*))/m
    ).map { |literal, identifier| literal || source[/^\s*#{Regexp.escape(identifier.to_s)}\s*=\s*"([^"]+)"/, 1] }

    resolved = source.scan(/Ai::Agent\.resolve_for\([^)]*?name:\s*"([^"]+)"/m).flatten

    (declared + resolved).compact
  end

  let(:seeded_policy_agents) do
    Dir[File.join(seed_dir, "*.rb")].sort
      .flat_map { |file| policy_agent_names_in(File.read(file)) }
      .uniq
      .sort
  end

  # The population the reconciler writes agent-scoped rows for: the name of
  # every agent that keys an agent-scoped POLICY_SETS entry.
  let(:declared_policy_agents) do
    d = System::Governance::PolicyDeclarations
    d::POLICY_SETS.select { |set| set[:scope] == "agent" && set[:agent_key] }
                  .map { |set| d::AGENT_IDENTITIES.fetch(set[:agent_key])[:name] }
                  .uniq
                  .sort
  end

  def payload
    get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)
    expect(response).to have_http_status(:ok)
    json_response_data
  end

  it "declares a bucket for every agent the declarations bind an agent-scoped set to" do
    missing = declared_policy_agents - System::AutonomyActions::SYSTEM_AGENT_NAMES

    expect(missing).to be_empty,
                       "#{missing.size} agent(s) key an agent-scoped PolicyDeclarations set but have no " \
                       "SYSTEM_AGENT_NAMES entry, so `by_agent` builds no bucket for them and drops the rows " \
                       "PolicyReconciler writes for them: #{missing.join(', ')}"
  end

  # The other direction, and the reason the fix is not "add every seeded
  # agent". System Concierge (`assistant`, chat) carries NO intervention
  # policies — no set declares it and its seed never writes a policy row — so
  # listing it would ship a permanently empty bucket and an agent the operator
  # has nothing to configure.
  it "declares no agent the declarations bind no agent-scoped set to" do
    empty = System::AutonomyActions::SYSTEM_AGENT_NAMES - declared_policy_agents

    expect(empty).to be_empty,
                     "#{empty.size} SYSTEM_AGENT_NAMES entry(ies) key no agent-scoped PolicyDeclarations set, so " \
                     "`by_agent` ships a permanently empty bucket for them: #{empty.join(', ')}"
  end

  # The seeds are the first-boot copy of the same declarations and may LAG
  # them (wave-1 managers declared, seeded in wave 2) but must never LEAD
  # them: a seed writing agent-scoped rows for an agent no set declares is
  # writing rows the reconciler cannot reconcile and the tick never gates by.
  it "seeds agent-scoped policies only for declared agents" do
    undeclared = seeded_policy_agents - declared_policy_agents

    expect(undeclared).to be_empty,
                          "#{undeclared.size} seed file agent(s) get agent-scoped rows but key no " \
                          "PolicyDeclarations set: #{undeclared.join(', ')}"
  end

  # The EFFECT, through the real endpoint. The two examples above compare a
  # constant against a file scan and would both stay green against a pivot that
  # had stopped consulting the constant at all.
  #
  # Stated as "no row is dropped" rather than as an expected bucket list: the
  # defect is rows disappearing between two views of one payload, and that
  # phrasing survives a rename or a reordering of the buckets.
  it "keeps every agent-scoped row — the pivot drops none of them" do
    agents = declared_policy_agents.to_h { |name| [ name, create(:ai_agent, account: account, name: name) ] }

    rows = agents.values.map do |agent|
      Ai::InterventionPolicy.create!(
        account: account, action_category: "system.cert_rotate", scope: "agent",
        ai_agent_id: agent.id, policy: "notify_and_proceed", priority: 10, is_active: true
      )
    end

    pivot = payload["policies"]
    kept = pivot["by_agent"].values.flatten.map { |r| r["id"] }
    dropped = rows.reject { |row| kept.include?(row.id) }

    expect(dropped.map { |r| r.agent.name }).to be_empty,
                                                "the by_agent pivot dropped #{dropped.size} agent-scoped row(s) " \
                                                "that by_domain in the SAME payload returns"

    # Positive twin: the pivot is populated and keyed by agent name, so the
    # emptiness above is a real agreement and not a pivot that returned nothing.
    expect(pivot["by_agent"].keys).to include(*declared_policy_agents)
  end

  # The endpoint's `agents` list is built from the same constant, and an agent
  # missing from it is missing its trust tier and autonomy config for any
  # client that reads the list rather than the rows.
  it "serializes every declared system agent in the payload's agents list" do
    declared_policy_agents.each { |name| create(:ai_agent, account: account, name: name) }

    expect(payload["agents"].map { |a| a["name"] }).to match_array(declared_policy_agents)
  end

  # The derivation's OWN integrity, which the two set comparisons cannot see.
  # They compare the constant against whatever the scan returned; a seed file
  # that binds an agent-scoped policy through a shape `policy_agent_names_in`
  # cannot parse contributes nothing, and "nothing missing" then means "nothing
  # was looked for". The failure is silent by construction — an agent added
  # that way would be dropped from the pivot with every example still green.
  #
  # So: any file that can write a policy AND mentions the agent scope must
  # yield at least one agent name. The scope test accepts the indirect spelling
  # (`scope: scope`) precisely because that is the one the gate above used to
  # miss.
  it "resolves an agent name for every seed file that writes an agent-scoped policy" do
    silent = Dir[File.join(seed_dir, "*.rb")].sort.select do |file|
      source = File.read(file)
      next false unless source.include?("upsert_policies!") || source.include?("Ai::InterventionPolicy")
      next false unless source.match?(/\bscope\s*[:=]\s*(?:scope\b|["']agent["'])/)

      policy_agent_names_in(source).empty?
    end

    expect(silent.map { |f| File.basename(f) }).to be_empty,
                                                   "#{silent.size} seed file(s) write an agent-scoped intervention " \
                                                   "policy but name their agent in a shape this spec's derivation " \
                                                   "cannot parse, so they contribute nothing to the oracle and any " \
                                                   "agent they introduce would drift undetected: " \
                                                   "#{silent.map { |f| File.basename(f) }.join(', ')}"
  end

  # Non-regression guard. Every example above reads `seeded_policy_agents`, and
  # a moved seed directory or a reformatted call shape would make the scan
  # return nothing — at which point the two set comparisons pass VACUOUSLY and
  # the effect example asserts nothing at all.
  it "has real inputs (guards the examples above from passing vacuously)" do
    expect(seeded_policy_agents.size).to be >= 6
    expect(seeded_policy_agents).to include("Fleet Autonomy", "GitOps Reconciler", "SDWAN Manager")
    expect(declared_policy_agents.size).to be >= 11
    expect(declared_policy_agents).to include("Capacity Manager", "System Topology Designer")
    # The declarations LEAD the seeds by exactly the wave-2 agents: the four
    # managers (no seed yet) and the Topology Designer (its seed writes no
    # policy row; the reconciler writes its set). When wave 2 lands, this
    # shrinks — update it, do not widen it.
    expect(declared_policy_agents - seeded_policy_agents).to match_array(
      [ "Capacity Manager", "Storage Manager", "Ingress Manager", "Supply Chain Manager", "System Topology Designer" ]
    )

    # The identifier-resolution branch specifically: the GitOps Reconciler seed
    # passes a local variable to `find_or_initialize_global_agent`, so a scan
    # that only matched string literals would silently omit the one agent this
    # file exists for and still satisfy the size floor above.
    gitops = policy_agent_names_in(File.read(File.join(seed_dir, "system_gitops_reconciler_agent.rb")))
    expect(gitops).to eq([ "GitOps Reconciler" ])

    # And the exclusion is a real derivation, not an artifact of those two
    # seeds being unreadable: both files ARE scanned and simply contribute no
    # agent, because neither writes a policy row.
    expect(seeded_policy_agents).not_to include("System Concierge", "System Topology Designer")
    expect(Dir[File.join(seed_dir, "system_{concierge,topology_designer}_agent.rb")].size).to eq(2)
  end
end
