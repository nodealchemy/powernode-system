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

  # The sense pass runs under ONE agent, so a policy seeded onto a DIFFERENT
  # agent is invisible to it — the trap the seed comments repeatedly warn about.
  let(:agent) do
    ::Ai::Agent.resolve_for(account.id, name: "Fleet Autonomy", agent_type: "monitor")
  end

  # A routed lane is gated by whichever autonomy service runs the sensor that
  # emits it, and there are TWO. FleetAutonomyService::SENSORS gates as "Fleet
  # Autonomy"; System::CveOps::CveResponderService runs the CVE sensors on its
  # own tick, builds its own DecisionEngine, and gates as "CVE Responder". A
  # policy on the wrong agent is invisible to the tick that needs it — the trap
  # the seed files repeatedly warn about.
  #
  # So the CVE lanes are not EXEMPT here, they are RE-HOMED: listing one below
  # does not excuse it, it only moves which agent must carry the row, and that
  # is asserted just as strictly. Nothing can be silenced by adding it to a list.
  CVE_GATED = %w[
    system.cve_remediate
    system.module_critical_upgrade_ready
  ].freeze

  # The REAL seeds are loaded, not a hand-built set of policies. That is the
  # whole point: this must fail when a lane is declared in code and no seed
  # produces a row for it. Building the policies here with a helper would only
  # prove the spec agrees with itself.
  #
  # Fleet-Autonomy-scoped policies are split across TWO files — the agent seed
  # and the provisioning policy seed (which writes project.* onto the SAME
  # agent). Loading only one produced four false positives on the first run.
  SEEDS = %w[
    fleet_autonomy_agent
    system_provisioning_intervention_policies
    system_cve_responder_agent
  ].freeze

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

  def policies_for(agent_name)
    a = ::Ai::Agent.resolve_for(account.id, name: agent_name, agent_type: "monitor")
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

    routed = System::Autonomy::ActionCategoryRouter.routed_action_categories
    expect(routed).not_to be_empty

    fleet_seeded = policies_for("Fleet Autonomy")
    cve_seeded   = policies_for("CVE Responder")

    missing = routed.reject do |category|
      if CVE_GATED.include?(category)
        cve_seeded.include?(category)
      else
        fleet_seeded.include?(category)
      end
    end

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

  # Guards the re-homing list itself. A category parked in CVE_GATED must
  # genuinely be carried by the CVE Responder agent, so the list can never be
  # used to silence a lane — only to move which agent is responsible for it.
  it "actually seeds every re-homed CVE lane onto the CVE Responder agent" do
    expect(policies_for("CVE Responder")).to include(*CVE_GATED)
  end

  # The gate's own view, not ours — proves the routed set is reachable through
  # the exact predicate that blocks, rather than through a query we wrote to
  # agree with ourselves.
  it "makes every routed category permitted from the gate's own perspective" do
    service = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)
    permitted = service.send(:permitted_actions)
    fleet_gated = System::Autonomy::ActionCategoryRouter.routed_action_categories - CVE_GATED

    expect(fleet_gated - permitted).to be_empty
  end

  describe "a missing row is reported as MISCONFIGURATION, not as a policy decision" do
    let(:routed_category) do
      (System::Autonomy::ActionCategoryRouter.routed_action_categories - CVE_GATED).first
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
