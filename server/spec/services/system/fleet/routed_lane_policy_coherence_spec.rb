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
  SEEDS = %w[
    fleet_autonomy_agent
    system_provisioning_intervention_policies
    system_cve_responder_agent
    system_sdwan_manager_agent
    system_gitops_reconciler_agent
    system_disk_image_manager_agent
    system_topology_designer_agent
  ].freeze

  # HIER-P2DECL: the boot that this spec models is seeds + PolicyReconciler —
  # the reconciler is what writes a declared set onto its agent on every boot
  # (and re-homes the rows wave 1 moved off Fleet Autonomy), and the four
  # wave-1 managers have NO seed until wave 2. So the declared identities no
  # seed produced are stubbed as the bare agents wave 2 will seed, and the
  # reconciler runs once, exactly as it does at boot. Without the stubs the
  # moved sensor-routed lanes (instance_replace, storage_assignment_reconcile,
  # package_repository.sync, project.adapt / cost_control) have a row NOWHERE
  # on a fresh install seeded between the waves — the tick's fallback gate
  # finds nothing on Fleet Autonomy either, because its seed no longer
  # declares them. An ESTABLISHED install still holds them on Fleet Autonomy;
  # the fresh-install gap is wave 2's to close, and this spec must not hide
  # it, so it is asserted below by name rather than papered over.
  WAVE_2_STUBS = %w[capacity-manager storage-manager ingress-manager supply-chain-manager].freeze

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

  def stub_wave_2_agents!
    WAVE_2_STUBS.each do |key|
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch(key)
      next if ::Ai::Agent.resolve_for(account.id, name: identity[:name], agent_type: identity[:agent_type])

      create(:ai_agent, account: account, name: identity[:name], agent_type: identity[:agent_type], source_key: key)
    end
  end

  def boot!
    stub_wave_2_agents!
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
    # The provisioning seed wrote project.* onto Fleet Autonomy; the
    # reconciler RE-HOMED them (no duplicate left behind).
    expect(policies_for("Fleet Autonomy")).not_to include("project.adapt", "system.instance_replace")
  end

  # THE FRESH-INSTALL GAP, stated by name so it cannot be forgotten: with the
  # wave-1 agents absent (seeds only, no stubs), the moved sensor-routed lanes
  # have no row on any agent — the Fleet Autonomy seed no longer declares them
  # and their owners do not exist to reconcile onto. An established install is
  # unaffected (its rows stay on Fleet Autonomy, where the tick's fallback
  # gate reads them — sensor_owner_gating_spec). Wave 2's seeds close this;
  # when they land, this example should start FAILING and be deleted.
  it "leaves the moved sensor-routed lanes rowless on a fresh install seeded between the waves (wave 2 closes it)" do
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    rowless = %w[system.instance_replace system.storage_assignment_reconcile system.package_repository.sync]
    rowless.each do |category|
      expect(::Ai::InterventionPolicy.where(account: account, action_category: category)).to be_empty,
        "#{category} has a row on a fresh install — wave 2 landed; delete this example"
    end
    # project.* are the exception: their seed still writes them onto Fleet
    # Autonomy, so the fallback gate does find them.
    expect(policies_for("Fleet Autonomy")).to include("project.adapt")
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
