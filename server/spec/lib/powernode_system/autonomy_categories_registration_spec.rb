# frozen_string_literal: true

require "rails_helper"
require "ripper"

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

  # Categories the code DECLARES. This is the authoritative half: the agent and
  # operator policy sets moved out of the seed files into
  # System::Governance::PolicyDeclarations so the reconciler could assert them
  # against a running database, which by construction put them beyond the reach
  # of a literal scan. Reading the constants is strictly better than the regex
  # that used to find them — it cannot miss a reformatted hash.
  let(:declared_categories) do
    d = System::Governance::PolicyDeclarations
    ([ d::MANUAL_OPERATION_POLICIES ] + d::POLICY_SETS.map { |set| set[:policies] })
      .flat_map(&:keys)
  end

  # Residual scan, deliberately KEPT: seed files that still carry their own
  # literal hashes (and any added later) are covered by nothing else. The
  # vacuous-pass guard below now watches the union, so neither half can quietly
  # go to zero.
  let(:scanned_categories) do
    Dir[File.join(seed_dir, "*.rb")].sort
      .flat_map { |f| File.read(f).scan(seed_entry_pattern).flatten }
  end

  let(:seeded_categories) do
    (declared_categories + scanned_categories).uniq.sort
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

  # Since the engine now DERIVES its registration list from these same
  # constants, this holds by construction — which is the point: it pins the
  # construction. It fails if the derivation is removed, if the to_prepare block
  # skips (its `defined?` guards), or if a future set is added to POLICY_SETS by
  # a path the engine does not read. Before the derivation this was a genuine
  # drift class: a category could be seeded and reconciled but never registered,
  # invisible until an operator's Autonomy-modal save was refused.
  it "registers every DECLARED policy category" do
    missing = declared_categories.uniq.reject { |cat| Ai::InterventionPolicy.category_registered?(cat) }

    expect(missing).to be_empty,
                       "#{missing.size} DECLARED category(ies) are absent from the registry, so the " \
                       "reconciler creates their policy rows but PATCH /api/v1/system/autonomy rejects " \
                       "every operator edit to them: #{missing.join(', ')}"
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
    # Each half separately: the union staying above 50 would otherwise hide one
    # of them collapsing to nothing — which is exactly what moving the hashes
    # into constants did to the scan.
    expect(declared_categories.size).to be > 50
    expect(seeded_categories).to include("system.instance_reboot")
    expect(Ai::InterventionPolicy.registered_categories)
      .to include("system.instance_reprovision", "sdwan.network_create")
  end

  # INVERSE enumeration, and the guard the two examples above cannot be: they
  # ask "is everything reachable registered?", which no amount of dead
  # vocabulary can fail. This asks the other question — "is everything
  # registered still real?" — which `system.runtime_docker_tls_rotate` failed
  # for three months (IMP-6e52d6aa53da).
  #
  # Registration is not cosmetic. It is the gate System::AutonomyActions#update
  # passes (`category_registered?`), so a category registered here but seeded
  # nowhere is one the bulk PATCH /api/v1/system/autonomy will happily
  # `find_or_initialize_by` a policy row for — a persisted operator control for
  # an action nothing can execute. The 2026-05-19 audit deleted that category's
  # seed because no executor backed it, and left the registration standing.
  #
  # The remainder is PINNED rather than derived because "has a backing
  # executor" is not mechanically decidable from here. It is EMPTY since
  # HIER-P2DECL: the last member, system.sdwan_federation_compose
  # (Skills::SdwanFederationComposeExecutor), is declared on the System
  # Topology Designer's set beside its two composer siblings
  # (PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES), and the engine's
  # explicit concat for the trio is gone — every extension category now
  # arrives through the derivation over POLICY_SETS.
  #
  # This list held three more until IMP-eb60db901f5f — runtime_docker_host_
  # provision / _decommission and runtime_k8s_cluster_create — annotated here
  # rather than decided. They turned out to be duplicate SPELLINGS of three
  # seeded categories (docker_provision, docker_decommission,
  # k8s_cluster_bootstrap) rather than reserved capabilities, so their
  # registrations were deleted; the engine records why, and
  # spec/controllers/api/v1/system/autonomy_controller_spec.rb pins the
  # consequence at the endpoint. If you add a name to this list, say which
  # executor backs it or why it is reserved.
  #
  # ASSUMPTION, stated because it is invisible in the code: the registry is
  # process-global, so this selects `system.`/`sdwan.`-prefixed names from
  # EVERY engine that ran, not just this one. Today that is exactly this
  # extension — `register_categories!` has one production call site (the
  # `concat` block below this file's subject) and core's STATIC_CATEGORIES
  # holds no such prefix — but a sibling extension registering one would red
  # this example in a maintainer checkout while public CI stayed green. That is
  # the correct failure (the bulk PATCH accepts those names too); it just needs
  # to be read as "who else registered this?", not as a bug here.
  it "registers no system category that nothing seeds, executes or gates" do
    # NO COUNT AND NO ROSTER, deliberately (IMP-51e5c6184ae4). This comment
    # used to carry both — "the eleven APO-1c skill categories … every one of
    # the fourteen" — and it also carried two CONTRADICTORY sentences about the
    # same set once the branch-health pass of 2026-09-02 seeded them: one saying
    # "none is seeded", the next saying all fourteen are. The counts drift every
    # time an executor lands or a duplicate category is retired (this task
    # retired three), and a stale count sitting next to a live assertion reads
    # as authority the assertion never gave it. The list below is the whole claim.
    #
    # What the list means: an extension category that is REGISTERED — through
    # the engine's concat blocks, or through the derivation over
    # System::Governance::PolicyDeclarations — but seeded by no agent. Such a
    # category is still tunable through PATCH /api/v1/system/autonomy, and
    # BaseSkillExecutor#execute resolves it before #perform, so it is a real
    # operator control with no row behind it until someone creates one. These
    # reach an operator through the MCP / REST / Concierge doors rather than
    # through an agent's seed; the engine names the executor behind each.
    deliberately_unseeded = [].sort

    extension_registered = Ai::InterventionPolicy.registered_categories
                                                 .select { |cat| cat.start_with?("system.", "sdwan.") }

    expect((extension_registered - seeded_categories).sort).to eq(deliberately_unseeded),
                                                              "the set of extension categories that are REGISTERED but seeded nowhere changed. " \
                                                              "Each one is a control PATCH /api/v1/system/autonomy will create a policy row for; " \
                                                              "a new entry needs a backing executor (and a note above), a removed entry needs " \
                                                              "this list updated."
  end

  # THIRD set — GATED (APO-1c, IMP-7e2bdc1774e4). Every executor that declares
  # `requires_approval: true` in its descriptor now has its action_category
  # resolved by System::Ai::Skills::BaseSkillExecutor#execute before #perform,
  # and an unregistered category cannot be tuned through
  # System::AutonomyActions#update — so the operator's only supported response
  # to the gate is unavailable and the action is stuck at the
  # require_approval default.
  #
  # This is a RATCHET, not a restatement of the seed scan: none of these
  # fourteen categories is seeded, so the SEEDED example above cannot see them,
  # and none of them is in SIGNAL_BINDINGS except through
  # BootImageDriftRolloutExecutor, so the BOUND example cannot either. The next
  # executor to declare the flag reds here unless its category is registered.
  #
  # Classes are derived from the FILES rather than from a constant list, so a
  # new executor is covered without a second edit.
  it "registers the action_category of every approval-gated skill executor" do
    skills_dir = File.expand_path("../../../app/services/system/ai/skills", __dir__)

    gated = Dir[File.join(skills_dir, "*.rb")].sort.filter_map do |path|
      klass = begin
        "System::Ai::Skills::#{File.basename(path, '.rb').camelize}".constantize
      rescue NameError
        nil
      end
      next unless klass.is_a?(Class) && klass < System::Ai::Skills::BaseSkillExecutor

      # An intermediate base (System::Ai::Skills::CrudFactory) declares no
      # descriptor of its own and RAISES on #descriptor by design — it is not an
      # invocable skill and has no category to register.
      begin
        next unless klass.gate_required?
      rescue NotImplementedError
        next
      end

      [ klass.name, klass.action_category ]
    end

    expect(gated).not_to be_empty,
                         "no gated executor found — the derivation broke, not the registration"

    unregistered = gated.reject { |(_name, cat)| Ai::InterventionPolicy.category_registered?(cat) }

    expect(unregistered).to be_empty,
                            "these approval-gated executors resolve an UNREGISTERED action_category, so "                             "PATCH /api/v1/system/autonomy refuses to save a policy for them and the gate "                             "is stuck at the require_approval default: #{unregistered.inspect}. Register "                             "the category in lib/powernode_system/engine.rb (and add it to the "                             "deliberately_unseeded list above), or declare an existing registered category "                             "on the descriptor with `action_category:`."
  end

  # Coupling guard for the two halves of a category removal. Deleting a
  # category's registration is only half the job: the seeded KB article
  # `container-runtime-troubleshooting` went on telling operators to "rotate
  # cert via `system.runtime_docker_tls_rotate`" for three months after the
  # seed that created its policy row was deleted, and that article is shipped
  # into the knowledge base — and into Concierge RAG — on every seed run.
  #
  # Scans the seed SOURCES because the seeds ARE the shipped text, and LEXES
  # them with Ripper rather than dropping lines that start with `#`. A
  # line-based comment filter is wrong here in both directions: KB articles are
  # markdown heredocs, so it silently discards every `#`/`##` heading
  # (system_kb_seed.rb's own "## Docker" among them) and a future article
  # naming the action in a heading would walk straight past. Keeping only
  # `:on_tstring_content` takes every string and heredoc body — the
  # operator-facing prose AND the seeded policy keys, so a re-seeded row is
  # caught too — while excluding Ruby comments exactly, which matters because
  # system_runtime_manager_agent.rb correctly RECORDS the removal in a `#`
  # block. Recording history is the opposite of instructing someone to use it.
  it "ships no seeded operator-facing text naming the removed docker-TLS action" do
    seed_strings = Dir[File.join(seed_dir, "*.rb")].sort.flat_map do |path|
      Ripper.lex(File.read(path))
            .select { |(_pos, type, _tok, _state)| type == :on_tstring_content }
            .map { |(_pos, _type, tok, _state)| [ File.basename(path), tok ] }
    end

    offenders = seed_strings.select { |(_file, text)| text.include?("system.runtime_docker_tls_rotate") }
                            .map(&:first).uniq

    expect(offenders).to be_empty,
                         "seed file(s) #{offenders.join(', ')} still ship operator-facing text naming " \
                         "system.runtime_docker_tls_rotate, which the 2026-05-19 audit removed because " \
                         "nothing executes it"

    # Positive twin, scoped to the file that carried the bad advice: the same
    # scan sees the KB article's REPLACEMENT sentence, so an empty `offenders`
    # means the text was corrected rather than that the scan reads nothing (a
    # moved seed dir, a lexer returning no string tokens). Scoped deliberately
    # — counting `system.cert_rotate` across ALL seeds is satisfied by
    # fleet_autonomy_agent.rb's policy key on its own, and would stay green
    # with the article's replacement sentence deleted outright.
    kb_replacement = seed_strings.count do |(file, text)|
      file == "system_kb_seed.rb" && text.include?("system.cert_rotate")
    end
    expect(kb_replacement).to be >= 1
  end

  # IMP-17bc5546009a — system.sdwan_route_policy_audit was seeded (on Fleet
  # Autonomy, auto_approve) and registered here, but nothing emits the signal
  # it would dedup, no DecisionEngine binding routes to it, and no executor
  # carries the category. Removed per operator direction (2026-08-21) rather
  # than built out, same precedent as the runtime_docker_tls_rotate removal in
  # the 2026-05-19 audit this file already guards above.
  it "no longer seeds or registers the removed system.sdwan_route_policy_audit lane" do
    expect(seeded_categories).not_to include("system.sdwan_route_policy_audit")
    expect(Ai::InterventionPolicy.category_registered?("system.sdwan_route_policy_audit")).to be(false)
  end
end
