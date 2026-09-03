# frozen_string_literal: true

require "rails_helper"

# IMP-5a450411d873 — every ROUTED lane must have a POLICY ROW.
#
# THE DEFECT THIS EXISTS FOR
#
# `rails-start.sh` runs `db:seed` only on FIRST BOOT (marker-guarded). Migrations
# re-run on every deploy; seeds never do. So an intervention policy added to a
# seed after a host's first boot never reaches that database.
#
# FleetAutonomyService#permitted_actions IS the Ai::InterventionPolicy row set,
# and gate_action! blocks anything outside it. So a routed lane with no row is
# blocked on every tick — silently. The sensor emits, the gate decides, nothing
# reaches an operator, and no error is raised.
#
# Measured on live ops-hub 2026-08-24: ai_intervention_policies held 127 rows;
# re-running one seed changed 11 and added 9. Among the missing was
# `system.module_verify_investigate` — a shipped feature whose sensors had been
# firing into a blocked gate since the day it landed.
#
# WHY THIS SPEC ASSERTS ROWS AND NOT SEED TEXT
#
# The existing wiring specs assert the seed FILE contains the policy string, and
# they passed throughout the entire outage — because the file did contain it.
# A spec that greps a seed proves the DECLARATION, never the ROW. This one seeds
# and then queries, so it fails when a lane is declared in code but never
# actually seeded onto the agent that gates it.
RSpec.describe "routed lane / intervention policy coherence" do
  let(:account) { create(:account) }

  # The sense pass runs under ONE agent (the tick agent), but since HIER-P2A a
  # decision is gated under the agent that OWNS the binding's action_category
  # (FleetAutonomyService#for_owner), so a policy row must sit on the OWNER —
  # a row on any other agent is invisible to the gate that needs it.
  let(:agent) do
    ::Ai::Agent.resolve_for(account.id, name: "Fleet Autonomy", agent_type: "monitor")
  end

  # A routed lane is gated by the agent its declared policy set names:
  # `PolicyDeclarations.owner_of(category)` — Fleet Autonomy by default, SDWAN
  # Manager for the sdwan_* / federation_* remediations, GitOps Reconciler for
  # gitops drift, Disk Image Manager for the publication streak, and CVE
  # Responder for the two CVE lanes (System::CveOps::CveResponderService runs
  # the CVE sensors on its own tick and gates as that agent). The owner is
  # DERIVED, never listed here: nothing can be silenced by adding it to a list,
  # and sensor_owner_gating_spec pins that every binding's `owner:` equals this
  # derivation.
  CVE_GATED = %w[
    system.cve_remediate
    system.module_critical_upgrade_ready
  ].freeze

  def owner_key_for(category)
    System::Governance::PolicyDeclarations.owner_of(category) ||
      System::Fleet::FleetAutonomyService::DEFAULT_OWNER
  end

  def owner_name_for(category)
    System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch(owner_key_for(category))[:name]
  end

  # The REAL seeds are loaded, not a hand-built set of policies. That is the
  # whole point: this must fail when a lane is declared in code and no seed
  # produces a row for it. Building the policies here with a helper would only
  # prove the spec agrees with itself.
  #
  # Fleet-Autonomy-scoped policies are split across TWO files — the agent seed
  # and the provisioning policy seed (which writes project.* onto the SAME
  # agent). Loading only one produced four false positives on the first run.
  # Every owner agent's seed is loaded, because every owner must carry its rows.
  #
  # HIER-P2B: listed in SYSTEM_SEED_FILES ORDER — every agent seed, then the
  # first-boot POLICY seeds that write onto one of them. The order is
  # load-bearing, not cosmetic: an agent seed writes its own declared set, and
  # PolicyReconciler short-circuits on a category the owner already has
  # (`existing.include?(action_category)`), so a policy seed that resolves the
  # WRONG agent after the owner's seed ran leaves a duplicate the reconciler
  # can never re-home. Loading these in the real order is what makes that
  # visible here.
  SEEDS = %w[
    fleet_autonomy_agent
    system_runtime_manager_agent
    system_cve_responder_agent
    system_sdwan_manager_agent
    system_gitops_reconciler_agent
    system_disk_image_manager_agent
    system_topology_designer_agent
    system_capacity_manager_agent
    system_storage_manager_agent
    system_ingress_manager_agent
    system_supply_chain_manager_agent
    system_instance_pool_policies
    system_provisioning_intervention_policies
  ].freeze

  # HIER-P2DECL: the boot that this spec models is seeds + PolicyReconciler —
  # the reconciler is what writes a declared set onto its agent on every boot
  # (and re-homes the rows wave 1 moved off Fleet Autonomy). While the four
  # wave-1 managers had no seed, each was stubbed here as a bare account row;
  # wave 2 (HIER-P2B/P2C/P2D/P2E) seeded all four as GLOBAL canonicals, so
  # every owner identity now comes from its real seed in SEEDS above and
  # NOTHING is stubbed — a stub would both mask the seed and collide with the
  # `AgentSetupHelpers.find_or_initialize_global_agent` CanonicalAgentConflict
  # guard (HIER-P2SWEEP removed the last one, ingress-manager).

  # agent_setup_helpers#bootstrap_admin_context! resolves the account by name
  # (falling back to Account.first), then requires an admin user and an
  # Ai::Provider, so all three preconditions are created up front.
  before do
    create(:user, account: account)
    create(:ai_provider) unless ::Ai::Provider.exists?
    SEEDS.each do |seed|
      load Rails.root.join("../extensions/system/server/db/seeds/#{seed}.rb")
    end
  end

  def boot!
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
  end

  def policies_for(agent_name)
    identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.values.find { |i| i[:name] == agent_name }
    a = ::Ai::Agent.resolve_for(account.id, name: agent_name, agent_type: identity ? identity[:agent_type] : "monitor")
    return [] unless a

    ::Ai::InterventionPolicy
      .where(ai_agent_id: a.id, scope: "agent", is_active: true)
      .pluck(:action_category)
  end

  # THE UNION, not DecisionEngine alone (IMP-7a6c9a70e050). System::AdaptationGate
  # is a second router: it resolves a `project.<change_type>` category that no
  # signal binding names, and four of those were outside every assertion here.
  # System::Autonomy::ActionCategoryRouter is the declared set the gate itself
  # reads, so asserting against it is asserting against what actually blocks.
  it "seeds an intervention policy row for EVERY action_category the platform routes to" do
    expect(agent).to be_present, "Fleet Autonomy agent was not seeded"
    boot!

    routed = System::Autonomy::ActionCategoryRouter.routed_action_categories
    expect(routed).not_to be_empty

    seeded = Hash.new { |memo, name| memo[name] = policies_for(name) }

    missing = routed.reject { |category| seeded[owner_name_for(category)].include?(category) }
                    .map { |category| "#{category} (owner: #{owner_name_for(category)})" }

    expect(missing).to be_empty, <<~MSG
      These action_categories are ROUTED by a declared
      System::Autonomy::ActionCategoryRouter but have no active intervention policy
      row on the agent that gates them:

        #{missing.join("\n  ")}

      Every signal on those lanes is blocked by the not_permitted arm and reaches no
      operator. Seed each onto the gating agent — and note that seeding it is not
      enough for an ALREADY-RUNNING host: db:seed is first-boot-only, so the seed
      must also be re-run against that database.
    MSG
  end

  # Guards the derivation itself. The CVE lanes must genuinely be carried by
  # the CVE Responder agent and derive to it, so the owner rule can never be
  # used to silence a lane — only to move which agent is responsible for it.
  it "actually seeds every CVE lane onto the CVE Responder agent, and derives that owner" do
    expect(policies_for("CVE Responder")).to include(*CVE_GATED)
    CVE_GATED.each { |category| expect(owner_name_for(category)).to eq("CVE Responder") }
  end

  # HIER-P2A: the derivation really moves lanes off Fleet Autonomy. Without
  # this, an owner_of that answered fleet-autonomy for everything would keep
  # the sweep above green while the tick gated the sdwan lanes against rows
  # that are not there.
  it "derives specialist owners for the re-homed lanes and seeds them there" do
    expect(owner_name_for("system.sdwan_peer_remediate")).to eq("SDWAN Manager")
    expect(owner_name_for("system.gitops_drift_remediate")).to eq("GitOps Reconciler")
    expect(owner_name_for("system.disk_image_publication_investigate")).to eq("Disk Image Manager")
    expect(policies_for("SDWAN Manager")).to include("system.sdwan_peer_remediate")
    expect(policies_for("Fleet Autonomy")).not_to include("system.sdwan_peer_remediate")
  end

  # HIER-P2DECL: the wave-1 owners, and the rows the reconciler writes for
  # them once the agent exists.
  it "derives the wave-1 owners for the lanes moved off Fleet Autonomy and reconciles them there" do
    boot!

    expect(owner_name_for("system.instance_replace")).to eq("Capacity Manager")
    expect(owner_name_for("project.adapt")).to eq("Capacity Manager")
    expect(owner_name_for("system.storage_assignment_reconcile")).to eq("Storage Manager")
    expect(owner_name_for("system.package_repository.sync")).to eq("Supply Chain Manager")
    expect(owner_name_for("system.expose_service_local")).to eq("Ingress Manager")
    expect(owner_name_for("system.sdwan_federation_compose")).to eq("System Topology Designer")

    expect(policies_for("Capacity Manager")).to include("system.instance_replace", "project.adapt",
                                                        "system.instance_pool_create")
    expect(policies_for("Storage Manager")).to include("system.storage_assignment_reconcile")
    expect(policies_for("Supply Chain Manager")).to include("system.package_repository.sync")
    expect(policies_for("System Topology Designer")).to include("system.sdwan_federation_compose")
    # Since HIER-P2B the provisioning seed writes project.* onto the Capacity
    # Manager directly, so there is no Fleet Autonomy row to re-home and none
    # left behind either.
    expect(policies_for("Fleet Autonomy")).not_to include("project.adapt", "system.instance_replace")
  end

  # HIER-P2SWEEP: the fresh-install gap wave 1 opened (a moved sensor-routed
  # lane with a row NOWHERE while its owner had no seed) is CLOSED for every
  # owner — the four "closes the fresh-install gap" examples below pin each
  # lane by name from the same boot model, and this one pins the whole: a
  # fresh install seeded from SEEDS skips NO declared set.
  it "skips no declared set on a fresh install — every owner the declarations name is seeded" do
    result = System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    expect(result.skipped_sets).to be_empty,
      "PolicyReconciler skipped #{result.skipped_sets.inspect} on a fresh install seeded from SEEDS"
  end

  # project.* used to be the exception to that gap (their seed wrote them onto
  # Fleet Autonomy, so the fallback gate found them). HIER-P2B re-pointed that
  # seed at the owner, so they are on the Capacity Manager now — and the
  # "no Fleet Autonomy duplicate" example below pins that the owner's rows are
  # not shadowed by a leftover copy on the former owner.
  it "writes the project.* provisioning rows onto the Capacity Manager, none onto Fleet Autonomy" do
    boot!

    expect(policies_for("Capacity Manager")).to include("project.adapt", "project.cost_control")
    expect(policies_for("Fleet Autonomy")).not_to include("project.adapt")
  end

  # HIER-P2B: the capacity half of that gap is CLOSED, from the same boot
  # model — the SYSTEM seeds plus the reconciler, with NO stub agent.
  # `system.instance_replace` is the lane `instance_unrecoverable_sensor`
  # routes to; before this seed a fresh install dropped every one of those
  # disaster-recovery signals into the not_permitted arm, silently.
  it "closes the fresh-install gap for the capacity lane (seed, no stub)" do
    capacity = ::Ai::Agent.resolve_for(account.id, name: "Capacity Manager", agent_type: "monitor")
    expect(capacity).to be_present, "the Capacity Manager seed did not run"
    expect(capacity.account_id).to be_nil, "the Capacity Manager must be the GLOBAL canonical, not a stub"

    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    expect(owner_name_for("system.instance_replace")).to eq("Capacity Manager")
    expect(policies_for("Capacity Manager")).to include("system.instance_replace")
    expect(::Ai::InterventionPolicy.where(account: account,
                                          action_category: "system.instance_replace")).not_to be_empty
  end

  # HIER-P2B — the FIRST-BOOT DUPLICATE, which the reconciler provably cannot
  # clean up. `db/seeds/system_capacity_manager_agent.rb` runs at position 9 of
  # SYSTEM_SEED_FILES and writes every declared CAPACITY_MANAGER_POLICIES row;
  # `system_instance_pool_policies.rb` (15) and
  # `system_provisioning_intervention_policies.rb` (19) run after it. While
  # those two resolved "Fleet Autonomy", a fresh install ended up with 14
  # ACTIVE agent-scope rows on an agent that no longer declares any of them —
  # including an auto_approve row for `project.scale_horizontal`. Nothing
  # collects them: PolicyReconciler#reconcile! answers `present` and skips
  # `rehomable_row` for a category the owner already has, and
  # AgentSetupHelpers.clean_unregistered_policies! only collects DEREGISTERED
  # categories. That is the "row the gate never reads" class this campaign
  # exists to close, so it is asserted against the real seed order rather than
  # argued about.
  it "leaves no Fleet Autonomy duplicate for a category the Capacity Manager owns" do
    boot!

    owned = System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES.keys
    expect(owned).not_to be_empty

    expect(policies_for("Capacity Manager")).to include(*owned)
    expect(policies_for("Fleet Autonomy") & owned).to be_empty,
      "first-boot policy seeds left rows on Fleet Autonomy for categories the " \
      "Capacity Manager owns: #{(policies_for('Fleet Autonomy') & owned).sort.inspect}"
  end

  # HIER-P2C: the storage half of that gap is CLOSED, asserted from the same
  # boot model the gap was defined against — the SYSTEM seeds plus the
  # reconciler, with NO stub agent. `system.storage_assignment_reconcile` is
  # the lane `storage_assignment_drift_sensor` routes to; before this seed a
  # fresh install dropped every one of those signals into the not_permitted
  # arm, silently.
  it "closes the fresh-install gap for the storage lane (seed, no stub)" do
    storage = ::Ai::Agent.resolve_for(account.id, name: "Storage Manager", agent_type: "monitor")
    expect(storage).to be_present, "the Storage Manager seed did not run"
    expect(storage.account_id).to be_nil, "the Storage Manager must be the GLOBAL canonical, not a stub"

    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    expect(owner_name_for("system.storage_assignment_reconcile")).to eq("Storage Manager")
    expect(policies_for("Storage Manager")).to include("system.storage_assignment_reconcile")
    expect(::Ai::InterventionPolicy.where(account: account,
                                          action_category: "system.storage_assignment_reconcile")).not_to be_empty
  end

  # HIER-P2E: the supply-chain half of the same gap, asserted the same way —
  # seeds plus the reconciler, no stub. `system.package_repository.sync` is the
  # lane `package_drift_sensor` routes to; before this seed a fresh install
  # dropped every package-drift signal into the not_permitted arm, and
  # BaseSkillExecutor resolved the unmatched require_approval default for the
  # re-bound sync executor (DRIVER NOTE, HIER-P2DECL).
  it "closes the fresh-install gap for the supply-chain lane (seed, no stub)" do
    supply_chain = ::Ai::Agent.resolve_for(account.id, name: "Supply Chain Manager", agent_type: "monitor")
    expect(supply_chain).to be_present, "the Supply Chain Manager seed did not run"
    expect(supply_chain.account_id).to be_nil, "the Supply Chain Manager must be the GLOBAL canonical, not a stub"

    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    expect(owner_name_for("system.package_repository.sync")).to eq("Supply Chain Manager")
    expect(policies_for("Supply Chain Manager")).to include("system.package_repository.sync")
    expect(::Ai::InterventionPolicy.where(account: account,
                                          action_category: "system.package_repository.sync")).not_to be_empty
  end

  # HIER-P2D / HIER-P2SWEEP: the ingress owner, from the same boot model —
  # seeds plus the reconciler, no stub. Nothing sensor-routed lands here; the
  # five rows gate the expose / ACME executors and the backend-set door, so
  # the assertion is that the GLOBAL canonical exists and carries them.
  it "seeds the Ingress Manager as the global canonical and reconciles its five gates (seed, no stub)" do
    ingress = ::Ai::Agent.resolve_for(account.id, name: "Ingress Manager", agent_type: "monitor")
    expect(ingress).to be_present, "the Ingress Manager seed did not run"
    expect(ingress.account_id).to be_nil, "the Ingress Manager must be the GLOBAL canonical, not a stub"

    boot!

    expect(owner_name_for("system.expose_service_local")).to eq("Ingress Manager")
    expect(policies_for("Ingress Manager"))
      .to include(*System::Governance::PolicyDeclarations::INGRESS_MANAGER_POLICIES.keys)
  end

  # The gate's own view, not ours — proves the routed set is reachable through
  # the exact predicate that blocks, rather than through a query we wrote to
  # agree with ourselves. Per OWNER gate: the tick asks
  # FleetAutonomyService#for_owner(owner) and that gate's #permitted_actions.
  it "makes every routed category permitted from the gate's own perspective" do
    boot!
    service = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)
    fleet_gated = System::Autonomy::ActionCategoryRouter.routed_action_categories - CVE_GATED

    unpermitted = fleet_gated.reject do |category|
      service.for_owner(owner_key_for(category)).send(:permitted_actions).include?(category)
    end

    expect(unpermitted).to be_empty
  end

  describe "a missing row is reported as MISCONFIGURATION, not as a policy decision" do
    # A Fleet-Autonomy-owned lane, so the tick agent's own gate is the one that
    # reports it.
    let(:routed_category) do
      (System::Autonomy::ActionCategoryRouter.routed_action_categories - CVE_GATED)
        .find { |category| owner_key_for(category) == System::Fleet::FleetAutonomyService::DEFAULT_OWNER }
    end

    it "blocks with the policy_missing gate and logs at error level" do
      ::Ai::InterventionPolicy
        .where(ai_agent_id: agent.id, action_category: routed_category)
        .destroy_all

      service = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)
      expect(Rails.logger).to receive(:error).with(/MISCONFIGURED LANE.*#{Regexp.escape(routed_category)}/)

      result = service.gate_action!(routed_category)

      # Still blocks — fail-safe is correct. The defect was the silence.
      expect(result[:decision]).to eq(:blocked)
      expect(result[:gate]).to eq(System::Fleet::FleetAutonomyService::GATE_POLICY_MISSING)
    end

    # A category nothing routes to is an ordinary refusal, not a deploy defect.
    # Conflating them would make the new alarm fire on every stray string.
    it "still reports an unrouted category as plain not_permitted" do
      service = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)

      result = service.gate_action!("system.definitely_not_a_routed_category")

      expect(result[:decision]).to eq(:blocked)
      expect(result[:reason]).to eq("not_permitted")
      expect(result[:gate]).to be_nil
    end

    # The whole point of the split: before this change both cases produced an
    # identical event, so no query could separate a deploy defect from an
    # operator's deliberate block.
    it "uses a gate distinct from a deliberate block" do
      expect(System::Fleet::FleetAutonomyService::GATE_POLICY_MISSING)
        .not_to be_in(%w[block silent unknown_policy auto_approve notify_and_proceed require_approval])
    end
  end
end
