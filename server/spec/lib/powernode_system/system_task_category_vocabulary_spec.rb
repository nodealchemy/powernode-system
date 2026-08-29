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

  let(:expected_categories) { commands.map { |command| "system.task.#{command}" }.sort }

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
                       "\"system.task.\#{command}\" (tasks_controller.rb:55), so an unregistered " \
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

  it "declares a default verb for every command and for nothing else" do
    expect(declared_verbs.keys.sort).to eq(commands.sort),
                                        "MANUAL_OPERATION_DEFAULT_VERBS and System::Task::COMMANDS " \
                                        "disagree. A command missing here still gets a row — the " \
                                        "MANUAL_OPERATION_FALLBACK_VERB fail-safe keeps boot working " \
                                        "and matches what absence already resolved to — but its verb " \
                                        "is then an accident rather than a decision. A key here that " \
                                        "is not a command is dead."
  end

  it "declares only verbs Ai::InterventionPolicy accepts" do
    expect(declared_verbs.values.uniq - ::Ai::InterventionPolicy::POLICIES).to be_empty
  end

  # Vacuity guard. The two set-difference examples above both pass on empty
  # inputs, which is precisely what an engine that never ran (extension
  # unloaded, to_prepare removed) or a renamed COMMANDS would produce. The
  # pinned names predate this spec, so nothing added here can satisfy it.
  it "has real inputs on both sides" do
    expect(commands.size).to be >= 20
    expect(registered_categories.size).to be >= 20
    expect(registered_categories).to include("system.task.terminate", "system.task.ssh_command")
    expect(declared_verbs.fetch("upgrade_boot_image")).to eq("require_approval")
  end
end
