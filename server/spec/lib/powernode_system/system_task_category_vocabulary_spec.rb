# frozen_string_literal: true

require "rails_helper"

# THE system.task.* VOCABULARY HAS EXACTLY ONE AUTHORITY: System::Task::COMMANDS.
#
# IMP-944567d41689. It used to have three, and they disagreed in both
# directions at once:
#
#   * System::Task::COMMANDS — what the model will actually insert (an
#     inclusion validation since 04be5e5b, not documentation);
#   * PolicyDeclarations::MANUAL_OPERATION_POLICIES — what the seed writes and
#     what PolicyReconciler creates on an established install;
#   * the engine's `powernode_system.autonomy_categories` registration — what
#     PATCH /api/v1/system/autonomy will let an operator SAVE.
#
# The declaration named 19 categories for commands the model refuses
# (provision, deprovision, the two public-IP verbs, the volume/snapshot/network
# verbs, sync, build_module, commit_module, backup, restore, custom) and omitted
# 12 commands in daily use (upgrade_boot_image, a2a_call, the seven storage.*
# verbs, the two ci.* verbs, probe.module_smoke). Production carried all 27 rows
# from the 07-16 seed run; none had ever been edited.
#
# The declaration is now DERIVED from COMMANDS and the registration is derived
# from the declaration, so both hops hold BY CONSTRUCTION. That is exactly why
# they are pinned here: a construction that nothing asserts is a construction
# the next refactor is free to unwind, and the failure is silent in both
# directions —
#
#   command with no category  -> the operator's POST /api/v1/system/tasks
#     resolves through InterventionPolicyService#default_policy to
#     require_approval, so the request PARKS instead of running, and no row
#     exists for an operator to retune it with;
#   category with no command  -> a policy row that renders in the Autonomy
#     modal (the by_action pivot reads rows, not the registry) and governs
#     nothing, or — once deregistered — cannot be saved at all.
#
# BOTH DIRECTIONS ARE PROVEN RED, not assumed: a command injected into COMMANDS
# after boot reds the first example (registration is a boot-time snapshot of the
# constant, so the spec compares the LIVE constant against the LIVE registry),
# and a category injected into the registry reds the second.
RSpec.describe "system.task.* category vocabulary", type: :lib do
  # `let`, not constants: a bare constant assigned inside a describe block lands
  # on Object, which is the recorded duplicate-constant clobber class here.
  let(:commands) { ::System::Task::COMMANDS }

  # THE AUTHORITY IS NO LONGER COMMANDS ALONE (campaign 01a0790b increment 2).
  # A gated OPERATION and a Task COMMAND used to be the same set, because every
  # gated operation actuated through a Task. Increment 1 ended that: the REST
  # and MCP lifecycle arms actuate the provider plane through
  # Executors::ControlInstance / TerminateInstance and insert nothing.
  #
  # `terminate` is the one such operation today. It left COMMANDS because the
  # agent — the sole Task actuator — answers it with `systemctl reboot`, but
  # both surfaces still gate the destroy on system.task.terminate, so the
  # category must keep existing or the most destructive verb the platform has
  # loses its tunable row and its registration.
  #
  # THIS IS A LOOSENING, and pretending otherwise is how it would rot. An
  # earlier draft of this comment claimed the phantom example below still
  # catches a bogus entry. It does NOT: that example compares the registry to
  # the declaration, and the declaration is what CREATES the registration, so a
  # garbage key added to GATED_NON_COMMAND_OPERATIONS would be declared,
  # registered, seeded and tunable with all three examples green.
  #
  # COMMANDS does not have that problem because it carries two independent
  # oracles — equality against the dispatcher sets (task_spec.rb) and the model
  # validator. The exception set needs its own, and it is the example
  # "every gated non-command names a real gated operation" below: each key must
  # be claimed by an executor's ACTION_CATEGORY. That is the property that
  # keeps this narrow.
  let(:gated_non_commands) do
    ::System::Governance::PolicyDeclarations::GATED_NON_COMMAND_OPERATIONS.keys
  end

  let(:expected_categories) do
    (commands + gated_non_commands).uniq.map { |command| "system.task.#{command}" }.sort
  end

  # Process-global by construction (Ai::InterventionPolicy.@category_registry),
  # so this selects every `system.task.` name ANY loaded engine registered.
  # Today that is only this one; a sibling extension registering into the
  # namespace would red the phantom example, and that is the correct failure —
  # PATCH /api/v1/system/autonomy would accept its names too.
  let(:registered_categories) do
    ::Ai::InterventionPolicy.registered_categories.select { |c| c.start_with?("system.task.") }.sort
  end

  let(:declared_categories) do
    ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES.keys.sort
  end

  let(:declared_verbs) do
    ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS
  end

  it "registers a category for every System::Task command" do
    missing = expected_categories - registered_categories

    expect(missing).to be_empty,
                       "#{missing.size} executable command(s) have no registered action_category: " \
                       "#{missing.join(', ')}. The operator's POST /api/v1/system/tasks composes " \
                       "\"system.task.\#{command}\" in TasksController#create, so an unregistered " \
                       "command resolves through InterventionPolicyService#default_policy to " \
                       "require_approval — the request parks, and PATCH /api/v1/system/autonomy " \
                       "refuses to save a row that would change that. Add the command's default " \
                       "verb to PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS."
  end

  it "registers no system.task.* category that is not a System::Task command" do
    phantom = registered_categories - expected_categories

    expect(phantom).to be_empty,
                       "#{phantom.size} registered system.task.* category(ies) name no command " \
                       "System::Task will insert: #{phantom.join(', ')}. A gate site composing one " \
                       "gets a policy decision for an action that fails closed at the model, and a " \
                       "seeded row for one is an operator control over nothing."
  end

  # The middle hop, stated separately from the registration examples above so a
  # break says WHICH derivation came apart. If the declaration and the registry
  # disagree, the engine's to_prepare block stopped deriving; if the declaration
  # and COMMANDS disagree, PolicyDeclarations stopped deriving.
  it "declares exactly the categories COMMANDS names" do
    expect(declared_categories).to eq(expected_categories)
  end

  it "declares a default verb for every gated operation and for nothing else" do
    expect(declared_verbs.keys.sort).to eq((commands + gated_non_commands).uniq.sort),
                                        "MANUAL_OPERATION_DEFAULT_VERBS and System::Task::COMMANDS " \
                                        "disagree. A command missing here still gets a row — the " \
                                        "MANUAL_OPERATION_FALLBACK_VERB fail-safe keeps boot working " \
                                        "and matches what absence already resolved to — but its verb " \
                                        "is then an accident rather than a decision. A key here that " \
                                        "is not a command is dead."
  end

  # THE ORACLE FOR THE EXCEPTION SET. Without it GATED_NON_COMMAND_OPERATIONS
  # is an unchecked back door into the registered vocabulary — see the comment
  # on `gated_non_commands` above. An executor that declares ACTION_CATEGORY is
  # what makes a category a REAL gated operation rather than a name: it is the
  # class the gate replays on approval.
  it "declares no gated non-command that no executor actually gates" do
    # BOTH constant forms, because one executor may gate several verbs.
    # TerminateInstance gates one (ACTION_CATEGORY); ControlInstance gates
    # start/stop/reboot (ACTION_CATEGORIES). Reading only the singular form
    # would leave start and stop unclaimed the moment they moved out of
    # COMMANDS — i.e. the guard would red on a correct change, which is how a
    # guard gets deleted.
    executors = [ ::System::Executors::TerminateInstance, ::System::Executors::ControlInstance ]
    claimed = executors.flat_map { |k|
      Array(k.const_defined?(:ACTION_CATEGORY) ? k::ACTION_CATEGORY : nil) +
        Array(k.const_defined?(:ACTION_CATEGORIES) ? k::ACTION_CATEGORIES : nil)
    }.compact

    unclaimed = gated_non_commands.map { |c| "system.task.#{c}" } - claimed

    expect(unclaimed).to be_empty,
                         "#{unclaimed.join(', ')} is declared in "                          "PolicyDeclarations::GATED_NON_COMMAND_OPERATIONS but no executor names "                          "it as its ACTION_CATEGORY. The set exists for operations that are GATED "                          "without being System::Task commands; a key nothing gates is a policy row "                          "over nothing — registered, seeded and tunable, governing no code path. "                          "Add the executor that gates it, or remove the key."
  end

  it "declares only verbs Ai::InterventionPolicy accepts" do
    expect(declared_verbs.values.uniq - ::Ai::InterventionPolicy::POLICIES).to be_empty
  end

  # THE VALUE, NOT ONLY THE KEY (IMP-01a07c0a). Every other example in this
  # file reads GATED_NON_COMMAND_OPERATIONS.keys; none reads what those keys
  # are declared AT.
  #
  # The offer that prompted these called that value "dead configuration wearing
  # the costume of live configuration" — a near-verbatim quote of the source
  # comment at policy_declarations.rb:281-286, which describes a state an
  # earlier increment ALREADY FIXED by making GATED_NON_COMMAND_OPERATIONS
  # authoritative through .fetch. Measured by mutation on 2026-09-10, against
  # that hash specifically, every value is live and already caught:
  #
  #   terminate -> auto_approve   system_fleet_terminate_gating_spec:64
  #   start/stop -> block         policy_reconciler_spec:74, :310, :330 and
  #                               tasks_retired_command_spec:140
  #
  # These examples are kept anyway, because those oracles are INDIRECT. Two are
  # about the reconciler's behaviour, one about retired commands, and
  # policy_reconciler_spec:310 pins the verb mix as a COUNT ("20 rows in a
  # 5/5/10 split") — a count cannot distinguish one changed verb from two
  # changed in opposite directions. A direct per-key assertion on the RESOLVED
  # hash says what the seed writes, in the file whose subject is that
  # vocabulary, and survives any refactor of the specs that currently catch it
  # by side effect.
  #
  # ASSERTED ON MANUAL_OPERATION_POLICIES, the resolved hash the seed writes,
  # never on either input. Both inputs carry "require_approval" for terminate,
  # so pinning either alone cannot say which one won — which is precisely the
  # hazard :281-286 describes.
  #
  # A NOTE ON MEASURING THIS: the first attempt at the mutation above edited
  # the `"start" => "auto_approve"` pair in MANUAL_OPERATION_DEFAULT_VERBS,
  # which appears EARLIER in the file and is the input .fetch falls back to —
  # so it correctly changed nothing and read as "unpinned". Mutate inside the
  # GATED_NON_COMMAND_OPERATIONS block, or the answer is about the wrong hash.
  it "pins the verb each gated non-command actually resolves to" do
    resolved = ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES

    expect(resolved.fetch("system.task.terminate")).to eq("require_approval")
    expect(resolved.fetch("system.task.start")).to eq("auto_approve")
    expect(resolved.fetch("system.task.stop")).to eq("auto_approve")
  end

  # The set is small and destructive-adjacent, so it is pinned WHOLE rather than
  # key by key: a fourth key added here would otherwise arrive with its verb
  # unasserted.
  it "pins the gated non-command set itself, so a new key cannot arrive unasserted" do
    expect(::System::Governance::PolicyDeclarations::GATED_NON_COMMAND_OPERATIONS)
      .to eq("terminate" => "require_approval", "start" => "auto_approve", "stop" => "auto_approve")
  end

  # Vacuity guard. The two set-difference examples above both pass on empty
  # inputs, which is precisely what an engine that never ran (extension
  # unloaded, to_prepare removed) or a renamed COMMANDS would produce. The
  # pinned names predate this spec, so nothing added here can satisfy it.
  it "has real inputs on both sides" do
    # 17 commands + 3 gated non-commands (terminate, start, stop). Was 19 + 1
    # until start/stop moved to the exception set — the TOTAL is unchanged at
    # 20, which is the number that matters: the move must not add or drop a
    # registered category, only change which side of the split it sits on.
    expect(commands.size).to be >= 17
    expect(registered_categories.size).to be >= 20
    expect(gated_non_commands).to include("terminate", "start", "stop")
    expect(commands).not_to include("start", "stop")
    expect(registered_categories).to include("system.task.terminate", "system.task.ssh_command")
    expect(declared_verbs.fetch("upgrade_boot_image")).to eq("require_approval")
  end
end
