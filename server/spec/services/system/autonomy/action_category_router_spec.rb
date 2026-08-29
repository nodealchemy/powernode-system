# frozen_string_literal: true

require "rails_helper"

# IMP-7a6c9a70e050 — EVERY ROUTER DECLARES ITSELF, or this spec goes red.
#
# THE DEFECT THIS EXISTS FOR
#
# System::Autonomy::RoutedLaneGuard tells a routed-but-unseeded lane (a deploy
# defect: db:seed is first-boot-only) from an ordinary refusal. It asked ONE
# source for "is this routed?" — DecisionEngine::SIGNAL_BINDINGS.
#
# There were TWO routers. System::AdaptationGate maps a change_type onto
# `project.<change_type>` and hands it to the same gate_action!, and four of
# those categories (relocate, schema_change, security_change, scale_horizontal)
# appear in no signal binding. A missing policy row for them therefore took the
# quiet arm, and the adaptation lane reported "blocked by policy" for a lane no
# policy had ever answered.
#
# WHY THIS SPEC IS SHAPED THE WAY IT IS
#
# Adding those four categories to the routed set would have closed today's gap
# and left the NEXT router equally invisible — the same one-twin drift
# IMP-b400ec1a2df8 was raised about. So routing is now a DECLARED, enumerable
# property: a router extends System::Autonomy::ActionCategoryRouter and states
# its categories, and the guard reads the union.
#
# A declaration nobody checks is a convention. These examples are the check:
# routers are DISCOVERED from source (any class that CALLS gate_action! is by
# definition routing something to a gate), and a discovered class that has not
# declared itself fails here — loudly, at the moment its author runs the suite,
# rather than silently inheriting the gap.
RSpec.describe System::Autonomy::ActionCategoryRouter do
  # Bounded to THIS extension, for the same reason the RoutedLaneGuard scan is:
  # extensions/private/* carries its own gate with its own lifecycle, and
  # reaching across the boundary fails in any clone that has no private
  # extensions at all.
  ACR_SERVICES_ROOT = Rails.root.join("../extensions/system/server/app/services").cleanpath

  # A CALL, not a definition. `gate_action!(` with parens is the call shape;
  # `def gate_action!` is the gate implementing it (those twins are policed by
  # routed_lane_guard_spec.rb instead). Comment-only lines are dropped so the
  # extensive prose in this subsystem — which names `gate_action!` dozens of
  # times — cannot manufacture a router.
  ACR_CALL = /gate_action!\s*\(/
  ACR_DEFINITION = /def\s+gate_action!/

  def self.discovered_router_classes
    Dir.glob(File.join(ACR_SERVICES_ROOT.to_s, "**", "*.rb")).sort.filter_map do |path|
      calls = File.readlines(path).reject { |line| line.match?(/\A\s*#/) }
                  .any? { |line| line.match?(ACR_CALL) && !line.match?(ACR_DEFINITION) }
      next unless calls

      Pathname.new(path).relative_path_from(ACR_SERVICES_ROOT).to_s.delete_suffix(".rb").camelize
    end
  end

  ACR_DISCOVERED = discovered_router_classes.freeze

  describe "structural: a new router cannot inherit the gap silently" do
    it "finds the two known routers" do
      expect(ACR_DISCOVERED).to include(
        "System::Fleet::DecisionEngine",
        "System::AdaptationGate"
      )
    end

    # THE LOUD FAILURE. A third routing surface — anything that computes an
    # action category and calls gate_action! — appears here whether or not its
    # author knew this file existed, and reds until it is declared.
    it "requires every discovered router to be declared in ROUTERS" do
      expect(ACR_DISCOVERED).to match_array(described_class::ROUTERS), <<~MSG
        A class in extensions/system calls gate_action! but is not declared as a
        router:

          #{(ACR_DISCOVERED - described_class::ROUTERS).join("\n  ")}

        Undeclared routing categories are invisible to
        System::Autonomy::RoutedLaneGuard, so a MISSING intervention policy row for
        them is reported as an operator's deliberate block instead of the deploy
        defect it is. Extend System::Autonomy::ActionCategoryRouter, declare
        `routed_action_categories`, and add the class to ROUTERS.
      MSG
    end

    described_class::ROUTERS.each do |class_name|
      context class_name do
        let(:klass) { class_name.constantize }

        it "declares itself a router as an observable property" do
          expect(klass.singleton_class.include?(described_class)).to be(true),
            "#{class_name} is listed in ROUTERS but does not extend " \
            "System::Autonomy::ActionCategoryRouter — its adoption cannot be enumerated"
        end

        # Not tautological the way `union.include?(klass.declared)` would be
        # (the union IS the flat_map of exactly these): this is what reds when a
        # router extends the seam and never overrides the contract stub.
        it "states a non-empty category set" do
          expect(klass.routed_action_categories).to be_present
        end
      end
    end

    # The contract, not a courtesy: extending without declaring is a mistake
    # that must not degrade to an empty (and therefore silently permissive)
    # category set.
    it "raises rather than routing nothing when a router declares no categories" do
      undeclared = Class.new { extend System::Autonomy::ActionCategoryRouter }

      expect { undeclared.routed_action_categories }.to raise_error(NotImplementedError)
    end
  end

  describe "the union the guard actually reads" do
    # The regression itself. These four are named by NO signal binding.
    it "covers the change_type categories only AdaptationGate routes" do
      only_adaptation = System::AdaptationGate::CHANGE_TYPE_CATEGORIES.values -
                        System::Fleet::DecisionEngine.routed_action_categories

      expect(only_adaptation).not_to be_empty,
        "premise check: AdaptationGate no longer names a category SIGNAL_BINDINGS omits"
      expect(described_class.routed_action_categories).to include(*only_adaptation)
    end

    # A category nothing routes to must stay an ordinary refusal, or the
    # misconfiguration alarm fires on every stray string. This is the cheap
    # half; a declaration that is over-broad in a plausible way (returning the
    # whole InterventionPolicy vocabulary, say) is caught by
    # routed_lane_policy_coherence_spec.rb, which requires a SEEDED ROW for
    # every routed category.
    it "attributes an unrouted category to no router at all" do
      expect(described_class.router_for("system.definitely_not_a_routed_category")).to be_nil
    end

    # The alarm has to name the router an operator should go and read. Naming
    # DecisionEngine for a category only AdaptationGate routes is the same
    # wrong-destination failure this offer is about.
    it "attributes each category to the router that actually declares it" do
      expect(described_class.router_for("project.relocate")).to eq(System::AdaptationGate)
      expect(described_class.router_for("system.cert_rotate")).to eq(System::Fleet::DecisionEngine)
    end
  end

  # END-TO-END THROUGH THE REAL GATE, not the module in isolation. The union is
  # only worth anything if the guard reads it, and the two arms are similar
  # enough that a half-finished change passes a module-only assertion.
  describe "behavioural: the real gate refuses an AdaptationGate-only lane as a deploy defect" do
    let(:account) { create(:account) }
    let(:agent) { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
    let(:category) { System::AdaptationGate::CHANGE_TYPE_CATEGORIES.fetch("relocate") }

    before { allow(Rails.logger).to receive(:error) }

    it "blocks with the policy_missing gate" do
      result = service.gate_action!(category)

      # STILL BLOCKS — fail-safe is right, the defect was the label.
      expect(result[:decision]).to eq(:blocked)
      expect(result[:gate]).to eq(System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)
    end

    it "names the lane and the agent in the misconfiguration alarm" do
      service.gate_action!(category)

      expect(Rails.logger).to have_received(:error)
        .with(/MISCONFIGURED LANE: '#{Regexp.escape(category)}'.*agent 'Fleet Autonomy'/m)
    end

    # WHERE THE OPERATOR IS SENT. The alarm used to say "routed by
    # DecisionEngine" unconditionally — for this category that constant contains
    # nothing, so following the alarm dead-ends.
    it "names the router that actually declares the lane, not DecisionEngine" do
      service.gate_action!(category)

      expect(Rails.logger).to have_received(:error).with(/routed by System::AdaptationGate/)
      expect(Rails.logger).not_to have_received(:error).with(/routed by System::Fleet::DecisionEngine/)
    end

    it "does not intercept the same lane once its policy row exists" do
      Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: agent.id, scope: "agent",
        action_category: category, policy: "block", is_active: true
      )

      expect(service.gate_action!(category)[:gate]).to eq("block")
    end
  end
end
