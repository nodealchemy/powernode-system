# frozen_string_literal: true

require "rails_helper"

# THE VOCABULARY ORACLE, re-anchored across the language boundary.
#
# System::Task::COMMANDS used to be pinned by equality against two Ruby
# constants in the same repo (ExecutionDispatcher::COMMAND_REGISTRY.keys +
# AGENT_DELEGATED_COMMANDS). That check could not fail for the reason that
# matters: one edit could move a command between the three lists and keep them
# agreeing while the platform's ability to EXECUTE it changed. It was a
# self-describing control.
#
# Campaign 01a0790b increment 3 retired the server dispatch arm, which makes
# the on-node Go agent the sole actuator of a System::Task. So the invariant
# worth pinning is no longer "two Ruby lists agree" but:
#
#     every command the platform can MINT, the agent can RUN
#
# and the only honest source for the right-hand side is the agent's own handler
# registry, in Go. This spec reads that source.
#
# SUBSET, NOT EQUALITY, AND DELIBERATELY SO. The agent registers handlers the
# platform will never mint — `terminate` (retired from COMMANDS in increment 2),
# plus the legacy `provision`, `deprovision`, `sync` and `custom`. An extra
# handler is inert; a MISSING one is a task that can never complete. Only one
# direction is a defect, so only one direction is asserted.
#
# `terminate` IS NOT KEPT "IN CASE AN OLD ROW REACHES AN OLD AGENT" — an earlier
# draft of this comment said that, and it had the safety backwards. The agent
# binds `terminate` to RebootHandler (lifecycle.go:121-124), System::Task
# grandfathers unlisted commands on rows it did not create, and pending_tasks
# applies no command filter. So a surviving legacy `terminate` row would REBOOT
# a live VM, not terminate it — the exact defect increment 2 retired the command
# for. Retaining the handler is a liability, not a compatibility measure.
#
# MEASURED, 2026-09-07, before saying so: of 781 System::Task rows that have
# ever existed on this control plane (system_list_tasks walked to
# has_more:false), ZERO carry command `terminate` — and zero carry `start` or
# `stop`. There is no legacy row for the handler to catch. Deleting the Go
# handler is therefore safe, and is filed separately rather than done here
# because it is an agent change, not a platform one.
RSpec.describe "System::Task::COMMANDS vs the agent's handler registry", type: :lint do
  # Both spellings the agent uses. Missing the second one is not hypothetical:
  # RegisterStorage binds all seven storage.* verbs through a loop variable
  # (`for _, cmd := range []string{...} { r.Register(cmd, h) }`), which a
  # literal `r.Register("` grep does not see at all — the same
  # variable-producer blindness that made an earlier retirement in this
  # subsystem delete four verbs that were still reachable.
  LITERAL_REGISTER_RX = /\br\.Register\(\s*"([^"]+)"/
  LOOP_REGISTER_RX    = /for\s+_,\s*cmd\s*:=\s*range\s*\[\]string\{(.*?)\}/m
  # THE THIRD SHAPE: a range over a DERIVED set. module_build.go declares an
  # allowlist map and registers its keys through a helper —
  #
  #   var ciJobs = map[string]ciJob{ "ci.module_build": ..., "ci.lint_discovery": ... }
  #   func ciJobCommands() []string { for command := range ciJobs { ... } }
  #   for _, command := range ciJobCommands() { r.Register(command, h) }
  #
  # No literal call and no inline []string appears anywhere in that chain. When
  # campaign 01a08c9b turned the literal registration into this form, BOTH ci.*
  # commands disappeared from this scan at once and the subset example reported
  # two handlers as missing that RegisterDefaults demonstrably registers (proven
  # by running it: Lookup returns *ModuleBuildHandler for each). These three
  # follow the chain — the range that registers, the helper it calls, the map the
  # helper reads — and the parser guard asserts both commands come back.
  RANGE_REGISTER_RX   = /for\s+(?:\w+\s*,\s*)?\w+\s*:=\s*range\s+(\w+)(?:\(\))?\s*\{[^{}]*?r\.Register\(/m
  MAP_ALLOWLIST_RX    = /^var\s+(\w+)\s*=\s*map\[string\][^{]*\{(.*?)^\}/m
  FUNC_BODY_RX        = /^func\s+(\w+)\s*\([^)]*\)[^{]*\{(.*?)^\}/m
  # Every `func RegisterX(...)` the handlers package defines, and every one
  # RegisterDefaults actually calls. A registration is only real if the chain
  # RegisterDefaults -> RegisterX -> r.Register is intact, and scanning for the
  # last link alone cannot see a break in the first two.
  REGISTER_FUNC_DEF_RX  = /^func\s+(Register\w+)\s*\(/
  REGISTER_FUNC_CALL_RX = /\b(Register\w+)\s*\(/

  let(:handlers_dir) do
    Rails.root.join("..", "extensions", "system", "agent", "internal", "runtime", "tasks", "handlers")
  end

  let(:go_sources) do
    files = Dir.glob(handlers_dir.join("*.go")).reject { |f| f.end_with?("_test.go") }
    # A silently empty read would make every example below pass vacuously —
    # the directory moving is exactly the kind of drift this spec must survive
    # loudly rather than by returning an empty set.
    expect(files).not_to be_empty,
      "found no agent handler sources under #{handlers_dir} — this spec's oracle is gone, not satisfied"
    # COMMENTS STRIPPED FIRST. `// r.Register("ssh_command", h)` matches the
    # literal pattern exactly as well as a live call does, so without this,
    # DISABLING a handler leaves this lint green — the opposite of what it is
    # for. Block comments too: /* ... */ hides a registration just as well.
    files.to_h { |f| [ f, strip_go_comments(File.read(f)) ] }
  end

  def strip_go_comments(src)
    src.gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "")
  end

  # name => body, for every allowlist map and every plain function in the
  # package. Collected across ALL sources, because the map, the helper and the
  # registering loop need not share a file.
  let(:go_map_bodies) { go_sources.values.flat_map { |src| src.scan(MAP_ALLOWLIST_RX) }.to_h }
  let(:go_func_bodies) { go_sources.values.flat_map { |src| src.scan(FUNC_BODY_RX) }.to_h }

  # The allowlist keys an identifier resolves to: the map itself, or the map a
  # helper function ranges over. ONE hop, deliberately — a deeper indirection
  # returns nothing and so reds the parser guard above, rather than being
  # chased silently until the scan quietly reads the wrong set.
  def derived_commands(identifier, maps, funcs)
    body = maps[identifier]
    if body.nil?
      func = funcs[identifier]
      return [] if func.nil?

      body = maps[func[/range\s+(\w+)/, 1]]
    end
    body.to_s.scan(/"([^"]+)"\s*:/).flatten
  end

  let(:agent_commands) do
    maps = go_map_bodies
    funcs = go_func_bodies
    go_sources.values.flat_map { |src|
      literals = src.scan(LITERAL_REGISTER_RX).flatten
      looped   = src.scan(LOOP_REGISTER_RX).flatten.flat_map { |block| block.scan(/"([^"]+)"/).flatten }
      derived  = src.scan(RANGE_REGISTER_RX).flatten.flat_map { |id| derived_commands(id, maps, funcs) }
      literals + looped + derived
    }.uniq
  end

  it "parses a registry that actually contains the shapes it claims to parse" do
    # Guards the parser, not the platform: if either regex stops matching, the
    # subset assertion below goes vacuous rather than red. `start` is a literal
    # registration and `storage.chown` is only reachable through the loop form,
    # so between them they prove both arms of the scan still work.
    expect(agent_commands).to include("start"), "the literal r.Register(\"...\") scan matched nothing"
    expect(agent_commands).to include("storage.chown"), "the loop-form registration scan matched nothing"
    # The THIRD shape, and the reason this arm exists: RegisterModuleBuild binds
    # its commands by ranging over a DERIVED set — `for _, command := range
    # ciJobCommands()`, whose helper ranges over the `ciJobs` allowlist map. That
    # is neither a literal call nor an inline []string, so when campaign 01a08c9b
    # changed module_build.go into that shape, BOTH ci commands vanished from this
    # scan at once and the subset example below reported two missing handlers that
    # RegisterDefaults demonstrably registers. Asserting them here means the next
    # change of registration shape reds THIS example — the parser's own oracle —
    # instead of silently making the subset example lie.
    expect(agent_commands).to include("ci.module_build", "ci.lint_discovery"),
      "the allowlist-map registration scan matched nothing: ciJobs' keys are registered through " \
      "`for _, command := range ciJobCommands() { r.Register(command, h) }`, so a scan that cannot " \
      "follow a map-derived set reports every ci.* command as unhandled"
  end

  # THE CHAIN, NOT JUST ITS LAST LINK. A `r.Register(...)` call proves nothing
  # unless the function containing it is reached: RegisterDefaults -> RegisterX
  # -> r.Register. Adding handlers/volume.go with a RegisterVolume that nothing
  # calls, and the matching command to COMMANDS, would otherwise leave the
  # subset example below GREEN while the agent answers every such row
  # `unknown_command`. Neither of this file's mutation checks can see that —
  # they perturb COMMANDS, not the Go wiring.
  it "wires every registration function into RegisterDefaults" do
    defined_funcs = go_sources.values.flat_map { |src| src.scan(REGISTER_FUNC_DEF_RX).flatten }.uniq
    defined_funcs -= [ "RegisterDefaults" ]

    defaults_body = go_sources.find { |path, src| src.match?(/^func\s+RegisterDefaults\s*\(/) }&.last
    expect(defaults_body).to be_present,
      "no RegisterDefaults found under #{handlers_dir} — the registration chain has no root"

    called = defaults_body.scan(REGISTER_FUNC_CALL_RX).flatten.uniq
    orphans = defined_funcs - called

    expect(orphans).to be_empty,
      "these handler registration functions are defined but never called by RegisterDefaults: " \
      "#{orphans.inspect}. Every command they bind is invisible to the agent at runtime, so a " \
      "command in System::Task::COMMANDS relying on one would mint rows that answer " \
      "`unknown_command` forever — while the subset example below stayed green."
  end

  # ...and RegisterDefaults itself has to be called, or the chain has an
  # unchecked root. It is invoked from the runtime service, one directory up.
  it "wires RegisterDefaults into the agent runtime" do
    runtime_dir = Rails.root.join("..", "extensions", "system", "agent", "internal", "runtime")
    callers = Dir.glob(File.join(runtime_dir, "**", "*.go"))
                 .reject { |f| f.end_with?("_test.go") }
                 .select { |f| strip_go_comments(File.read(f)).include?("RegisterDefaults(") }

    expect(callers).not_to be_empty,
      "nothing under #{runtime_dir} calls handlers.RegisterDefaults( — the agent registers no " \
      "task handlers at all, and every assertion in this file about what it can run is vacuous."
  end

  it "registers a handler for every command System::Task can mint" do
    missing = ::System::Task::COMMANDS - agent_commands

    expect(missing).to be_empty,
      "System::Task::COMMANDS lists #{missing.inspect}, which the agent registers no handler for. " \
      "Since campaign 01a0790b increment 3 the agent is the SOLE actuator of a System::Task, so such " \
      "a command mints a row nothing can ever execute. Either add the handler in " \
      "extensions/system/agent/internal/runtime/tasks/handlers/ or drop the command from COMMANDS."
  end

  it "documents the handlers the platform deliberately never mints" do
    # Not a constraint, a LEDGER — asserted so that an unexplained new entry
    # shows up in a diff instead of accumulating silently. Extra handlers are
    # inert, but each one is a verb some caller might reasonably expect to work
    # through POST /api/v1/system/tasks, and none of these do.
    expect(agent_commands - ::System::Task::COMMANDS).to match_array(
      # start/stop joined this ledger when they left COMMANDS: the agent still
      # registers both (LifecycleHandler), but every such row failed
      # validateUnit without options["unit"], and the working capability is
      # Executors::ControlInstance on the provider plane.
      %w[terminate provision deprovision sync custom start stop]
    )
  end
end
