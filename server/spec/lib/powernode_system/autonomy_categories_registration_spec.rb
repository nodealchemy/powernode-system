# frozen_string_literal: true

require "rails_helper"

# Confirms the system extension's engine initializer
# ("powernode_system.autonomy_categories", lib/powernode_system/engine.rb)
# registered every action_category an operator can be shown — the subset
# invariant `reachable ⊆ registered`.
#
# Why this matters (IMP-097a267b50b7): `Ai::InterventionPolicy` does NOT
# validate action_category against the registry, so an unregistered category
# seeds and gates fine — the failure is operator-facing and one layer up.
# System::AutonomyActions#update (the bulk PATCH /api/v1/system/autonomy the
# Autonomy modal saves through) rejects any update whose category is not
# `category_registered?`. A seeded policy row for an unregistered category is
# therefore VISIBLE in the modal (the by_action pivot reads rows, not the
# registry) but cannot be saved. FOURTEEN categories were in that state.
#
# TWO sets are asserted, and the SEEDED one is the load-bearing half:
#
#   * SEEDED — every category the agent seeds create a policy row for. This is
#     exactly the set that can appear in the modal, so it is the set whose
#     absence from the registry produces the operator-visible failure. It is
#     derived by scanning the seed files (reading a seed file in a spec is an
#     established pattern here — cf. sdwan_service_health_sensor_spec.rb).
#     A binding-only invariant is NOT enough: nine seeded categories
#     (system.architecture.*, system.package_module.*, system.gitops_*) reach
#     an operator without ever passing through SIGNAL_BINDINGS — they gate
#     from the executor/MCP path — and a SIGNAL_BINDINGS-shaped assertion
#     stays green while every one of them is broken.
#
#   * BOUND — DecisionEngine::SIGNAL_BINDINGS. Both `gate_action!` call sites
#     in the engine (the normal decide path and escalate_stuck_remediation!)
#     pass `binding[:action_category]`. Today this is a subset of SEEDED, so it
#     is kept as the guard for the case that would escape the seed scan: a
#     future binding whose category no seed file ships.
#
# Registration is hand-maintained in the engine, so these two examples are what
# fail when the next category lands without it.
RSpec.describe "PowernodeSystem autonomy category registration", type: :lib do
  # Deliberately `let`, not constants: a bare constant assigned inside a
  # describe block lands on Object, and a generic name there is exactly the
  # duplicate-constant clobber that makes suites order-dependent.
  #
  # A seed entry is a `"category" => "policy"` pair, so anchoring the RHS to
  # Ai::InterventionPolicy::POLICIES is what keeps this from matching arbitrary
  # string-to-string hashes elsewhere in the seed files.
  let(:seed_entry_pattern) do
    /"([a-z][a-z0-9_.]*)"\s*=>\s*"(?:#{Ai::InterventionPolicy::POLICIES.join('|')})"/
  end

  let(:seed_dir) { File.expand_path("../../../db/seeds", __dir__) }

  let(:seeded_categories) do
    Dir[File.join(seed_dir, "*.rb")].sort
      .flat_map { |f| File.read(f).scan(seed_entry_pattern).flatten }
      .uniq
      .sort
  end

  let(:bound_categories) do
    System::Fleet::DecisionEngine::SIGNAL_BINDINGS.values
      .filter_map { |binding| binding[:action_category] }
      .uniq
      .sort
  end

  it "registers every action_category the agent seeds create a policy row for" do
    missing = seeded_categories.reject { |cat| Ai::InterventionPolicy.category_registered?(cat) }

    expect(missing).to be_empty,
                       "#{missing.size} seeded category(ies) are not in the registry, so their policy rows " \
                       "render in the Autonomy modal but PATCH /api/v1/system/autonomy rejects every edit " \
                       "to them: #{missing.join(', ')}"
  end

  it "registers every action_category DecisionEngine::SIGNAL_BINDINGS can gate" do
    missing = bound_categories.reject { |cat| Ai::InterventionPolicy.category_registered?(cat) }

    expect(missing).to be_empty,
                       "SIGNAL_BINDINGS gates #{missing.size} category(ies) the registry does not know, " \
                       "so PATCH /api/v1/system/autonomy rejects operator tuning for them: " \
                       "#{missing.join(', ')}"
  end

  # Non-regression guard: no mutant of the fix reds this one. It fails only if
  # one of the two invariants above loses its input and starts passing
  # vacuously — a renamed/emptied SIGNAL_BINDINGS, a seed scan that matches
  # nothing (moved seed dir, reformatted hash literals), or an initializer that
  # never ran at all (extension unloaded, to_prepare hook removed), which would
  # leave a core-only registry for both to pass against.
  #
  # The two pinned categories were registered long before this spec, so no
  # addition of mine can satisfy this example — that is what makes it a real
  # guard rather than a restatement of the fix.
  it "has real inputs and a populated registry (guards both invariants from passing vacuously)" do
    expect(bound_categories).not_to be_empty
    expect(seeded_categories.size).to be > 50
    expect(seeded_categories).to include("system.instance_reboot")
    expect(Ai::InterventionPolicy.registered_categories)
      .to include("system.instance_reprovision", "sdwan.network_create")
  end
end
