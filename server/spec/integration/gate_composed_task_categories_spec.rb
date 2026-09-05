# frozen_string_literal: true

require "rails_helper"

# EVERY action_category A GATE SITE NAMES MUST RESOLVE TO A COMMAND
# System::Executors::ExecuteTask CAN ACTUALLY INSERT.
#
# WHY THIS SPEC EXISTS AT ALL, AND WHY IT IS NOT A GREP.
#
# The two public-IP verbs were removed in TWO commits, and they produced TWO
# DIFFERENT FAILURE MODES — which is more informative than the single-commit
# story and is why the history is spelled out rather than reduced to one sha:
#
#   58702a16 "retire the thirteen zero-caller dispatch verbs" removed
#   "associate_public_ip" => System::Runtime::ManagePublicIp (and its sibling)
#   from ExecutionDispatcher::COMMAND_REGISTRY, and deleted the
#   System::Runtime::ManagePublicIp class outright. It left
#   System::Task::COMMANDS alone. In this window the Task INSERTED normally and
#   then failed LATER, in the worker, as "Unsupported command:
#   associate_public_ip" — a different signature, at a different time, seen by a
#   different observer (a failed task row, not a failed request).
#
#   04be5e5b "restore the four dispatch verbs that DO have a producer, and make
#   Task::COMMANDS a real validation" restored start/stop/reboot/terminate to the
#   registry (four + lines, zero - lines) and turned COMMANDS into an inclusion
#   validation — dropping the two public-IP verbs from it. ONLY FROM HERE does
#   the insert itself fail, and only from here does the caller get the 422.
#
# The check that missed the producer was a literal search, and a literal search
# cannot see a COMPOSED identifier: NodeInstanceGating builds its category as
# `"system.task.#{event}"` and its command as `event.to_s`, so
# `associate_public_ip` never appears as a literal anywhere near the producer.
# Both public-IP endpoints have failed closed on every request since
# (IMP-8d944d656c0b).
#
# A grep-driven guard would reproduce that blind spot verbatim. So the sites are
# ENUMERATED BY HAND below, each with the SET of values its interpolated
# variable can take. Adding a gate site means adding an entry here — there is no
# automatic discovery to lean on, deliberately.
#
# The scans in the last example are a BACKSTOP, not the mechanism. They cover
# BOTH shapes a gate site can take, because the enumeration does:
#   * composed  — `"system.task.#{`, literal text even when the identifier it
#                 builds is not;
#   * literal   — `action_category: "system.task.`, which a composed-only scan
#                 would miss entirely. A new literal site naming a verb outside
#                 COMMANDS (say "system.task.provision", still absent from both
#                 COMMANDS and COMMAND_REGISTRY) fails closed in exactly this
#                 offer's shape, so leaving it undiscoverable would reproduce
#                 the very gap this spec exists to close.
# Either scan can only ever find SITES, never their value sets, which is why
# neither can be the primary check.
module GateComposedTaskCategories
  # This extension's server/ dir — spec/integration/../.. rather than
  # Rails.root, which is the CORE app when the suite is run from
  # /home/pnadmin/work/server.
  #
  # Everything in this file lives on this uniquely-named module rather than on
  # the RSpec example group. A constant assigned inside an RSpec block lands on
  # Object, and this repo has a recorded order-dependent duplicate-constant
  # clobber flake class — EXTENSION_ROOT especially is the name a second
  # extension spec would reach for.
  EXTENSION_ROOT = Pathname.new(__dir__).join("..", "..").cleanpath

  # Best-effort: the core Rails app, if it is where the layout says. Core
  # declares no system.task.* gate site today (verified), and this spec scans it
  # so that a future one cannot appear unenumerated. Findings are prefixed
  # "CORE:" so they can never be mistaken for an extension path.
  CORE_ROOT = Pathname.new(__dir__).join("..", "..", "..", "..", "..", "server").cleanpath

  # The two shapes a gate site's action_category can take. Kept together so the
  # backstop and the enumeration agree on what "a site" looks like.
  DISCOVERY_PATTERNS = [
    /system\.task\.\#\{/,
    /action_category:\s*"system\.task\./
  ].freeze

  # ==================================================================
  # THE ENUMERATION. One entry per site that builds a `system.task.*`
  # action_category, composed or literal.
  # ==================================================================
  #
  # :source is asserted to still be present at :file / :line, so a site that
  # moves or changes shape fails here instead of silently drifting out of scope.
  #
  # :commands is the SET the site's variable can take, and the reasoning for
  # each set is in its :domain note.
  #
  # :executor is DOCUMENTATION — no expectation reads it. It records which
  # executor the site names, because only ExecuteTask inserts a System::Task, so
  # a site on a different executor is in the vocabulary but not on the insert
  # path. It is recorded rather than asserted because the binding is a string
  # passed at the call site, and re-asserting it here would duplicate the
  # gate-site source check above without adding a property.
  GATE_SITES = [
    {
      file: "app/controllers/api/v1/system/tasks_controller.rb",
      line: 56,
      source: 'action_category: "system.task.#{attrs[:command]}"',
      executor: "System::Executors::ExecuteTask",
      domain: "attrs[:command] is caller-supplied free text from task_params. " \
              "Any value outside System::Task::COMMANDS is refused at the model, " \
              "which is the intended fail-closed answer to a caller naming a " \
              "command that does not exist — so the set this site must SUPPORT " \
              "is exactly COMMANDS. NOTE: this entry is close to a TAUTOLOGY — " \
              "it checks COMMANDS against a validator holding that same frozen " \
              "array — and carries no discovery value. It is kept because it " \
              "does pin one real property (the constant and the validator have " \
              "not been decoupled) and because omitting the busiest gate site " \
              "from an enumeration whose whole point is completeness would be " \
              "the wrong lesson to leave behind.",
      commands: -> { ::System::Task::COMMANDS }
    },
    {
      file: "app/controllers/concerns/system/node_instance_gating.rb",
      line: 55,
      source: 'action_category: "system.task.#{event}"',
      executor: "System::Executors::ExecuteTask",
      domain: "#gate_or_execute(event). Callers, all in " \
              "Api::V1::System::NodeInstancesController: :start (205), :stop (211), " \
              ":reboot (217), :terminate (230).",
      commands: -> { %w[start stop reboot terminate] }
    },
    {
      file: "app/controllers/concerns/system/node_instance_gating.rb",
      line: 110,
      source: 'action_category: "system.task.#{event}"',
      executor: "System::Executors::ExecuteTask",
      domain: "#gate_ip_action(event). Callers, both in " \
              "Api::V1::System::NodeInstancesController: :associate_public_ip (251), " \
              ":disassociate_public_ip (277). THIS IS THE SITE IMP-8d944d656c0b " \
              "is about.",
      commands: -> { %w[associate_public_ip disassociate_public_ip] }
    },
    {
      file: "app/controllers/concerns/system/node_instance_gating.rb",
      line: 197,
      source: "def create_instance_operation(command)",
      executor: nil,
      domain: "The second variable producer in the same concern — it inserts a " \
              "System::Task directly, ungated, from #control_or_error(event) " \
              "(line 145, `create_instance_operation(event.to_s)`). It composes " \
              "no action_category, so neither backstop scan can see it, and it " \
              "is enumerated by hand for exactly that reason. NOTE: " \
              "#control_or_error currently has NO callers — the four lifecycle " \
              "actions all route through #gate_or_execute — so this producer is " \
              "dormant, not dead: restoring a caller must not silently " \
              "reintroduce an uninsertable command.",
      commands: -> { %w[start stop reboot terminate] }
    },
    {
      file: "app/services/system/governance/policy_declarations.rb",
      line: 253,
      source: '"system.task.#{command}"',
      # NOT a gate site: it composes the category NAME the seed, PolicyReconciler
      # and the engine's registration all consume, and calls no gate. Enumerated
      # anyway because the composed-shape backstop scan finds it and cannot tell
      # the difference — and because enumerating it is what makes the derivation
      # this file's subject: the value set is System::Task::COMMANDS itself, so
      # asserting insertability here pins that the declaration can never again
      # name a category no command backs (IMP-944567d41689, which removed 19 such
      # names and added the 12 that were missing).
      executor: nil,
      domain: "PolicyDeclarations::MANUAL_OPERATION_POLICIES derives its key set " \
              "from System::Task::COMMANDS. Like the tasks_controller entry this " \
              "is close to a TAUTOLOGY — COMMANDS checked against a validator " \
              "holding the same frozen array — and is kept for the same reason: " \
              "the constant and the validator have not been decoupled, and the " \
              "backstop scan sees this line whether or not it is enumerated.",
      commands: -> { ::System::Task::COMMANDS }
    },
    {
      file: "app/services/ai/tools/system_fleet_tool.rb",
      line: 604,
      source: 'action_category: "system.task.terminate"',
      # NOT ExecuteTask. This arm replays System::Executors::TerminateInstance,
      # which calls ProvisioningService directly and inserts no System::Task —
      # see the long declaration comment above that line. Enumerated so the
      # `system.task.*` vocabulary is covered completely, and asserted for
      # insertability anyway: the category is shared with the REST twin, and one
      # operator-tuned policy row governs both.
      executor: "System::Executors::TerminateInstance",
      domain: "Literal category on the MCP system_terminate_instance arm — the " \
              "shape the literal backstop scan exists to keep discoverable.",
      commands: -> { %w[terminate] }
    }
  ].freeze

  # ==================================================================
  # KNOWN-BROKEN EXEMPTION — DELETE THIS WHEN THE OPERATOR RULES.
  # ==================================================================
  #
  # IMP-8d944d656c0b. These two commands are composed by a live gate site
  # (gate_ip_action, above) and System::Task refuses to insert them, so both
  # public-IP endpoints fail closed on every request. The DISPOSITION IS PARKED
  # WITH THE OPERATOR — restore the two commands to System::Task::COMMANDS (plus
  # a dispatch route: neither is in ExecutionDispatcher::COMMAND_REGISTRY or
  # AGENT_DELEGATED_COMMANDS either, so a restored task would insert and then be
  # failed in the worker as "Unsupported command" — the pre-04be5e5b failure
  # mode described in the header, not a fix), or delete the two endpoints,
  # gate_ip_action, the two registered categories and the two seeded policy rows.
  #
  # SCOPE, because this list is GLOBAL and not per-site: an entry here excuses
  # its command at EVERY enumerated site, present and future. It is therefore
  # the one place in this file where a genuinely NEW red can be silenced by
  # appending a line. Anyone adding to it is asserting the command is broken
  # everywhere and that the disposition is open — not narrowing an exemption to
  # the site they were looking at.
  #
  # This iteration was scoped to EVIDENCE + this guard, explicitly not to the
  # fix, so the defect is recorded here rather than left to turn CI red. The
  # exemption is NOT permission for the state to persist:
  #
  #   * the examples below assert every entry is STILL broken AND still composed
  #     by an enumerated site, so the moment one becomes insertable this spec
  #     FAILS and the entry must be deleted — it cannot rot into a permanent
  #     carve-out;
  #   * an empty list is the normal end state, and the examples handle it.
  KNOWN_BROKEN_COMMANDS = %w[associate_public_ip disassociate_public_ip].freeze

  module_function

  # The oracle. Not `COMMANDS.include?` — the inclusion validator captures the
  # constant BY VALUE at class-body load, so a test that reads the constant and
  # a request that hits the validator are two different questions. This asks the
  # validator, on the same attribute ExecuteTask#perform assigns before its
  # `task.save!` (execute_task.rb:30).
  #
  # Scoped to errors on :command deliberately: `restart` reports its
  # scope-declaration failure on :options and the record has no :account, so a
  # bare `task.valid?` oracle would go red on `restart` for reasons that have
  # nothing to do with the command vocabulary.
  def command_insertable?(command)
    task = ::System::Task.new(command: command, status: "pending", progress: 0)
    task.valid?
    task.errors[:command].empty?
  end

  # Scan a tree for gate-site shapes, returning "path" => count.
  #
  # Comment lines are excluded: both patterns appear inside prose that
  # DOCUMENTS these sites (ExecutionDispatcher's header names gate_ip_action's
  # expression verbatim; system_fleet_tool's declaration comment names its own
  # literal category), and a doc reference is not a producer. Code only.
  #
  # COUNT PER FILE, not file:line. The line-number drift check is the
  # "still contains" example's job, and it reports drift with the right
  # diagnosis; if this compared file:line too, inserting a comment above an
  # enumerated site would ALSO fail here with "a new gate site appeared", which
  # is a misdiagnosis of a line shift.
  def scan(root, prefix = "")
    return {} unless root.directory?

    Dir.glob(root.join("app", "**", "*.rb")).each_with_object(Hash.new(0)) do |file, counts|
      rel = "#{prefix}#{Pathname.new(file).relative_path_from(root)}"
      File.readlines(file).each do |line|
        next if line.lstrip.start_with?("#")
        next unless DISCOVERY_PATTERNS.any? { |pattern| line.match?(pattern) }

        counts[rel] += 1
      end
    end
  end

  # The enumerated sites a scan COULD see, counted per file. Derived from each
  # entry's own :source, so an entry is expected to be discoverable exactly when
  # the code it quotes matches a discovery pattern — no second list to keep in
  # step. (#create_instance_operation composes nothing and is correctly absent.)
  def discoverable_enumeration
    GATE_SITES.each_with_object(Hash.new(0)) do |site, counts|
      next unless DISCOVERY_PATTERNS.any? { |pattern| site[:source].match?(pattern) }

      counts[site[:file]] += 1
    end
  end
end

RSpec.describe "gate-composed system.task action categories", type: :model do
  sites  = GateComposedTaskCategories::GATE_SITES
  broken = GateComposedTaskCategories::KNOWN_BROKEN_COMMANDS

  describe "the enumerated sites still look the way this spec claims" do
    sites.each do |site|
      it "#{site[:file]}:#{site[:line]} still contains #{site[:source].inspect}" do
        path = GateComposedTaskCategories::EXTENSION_ROOT.join(site[:file])

        expect(path).to exist, "enumerated gate site file is gone: #{site[:file]}"

        # EXACT line, not a window. A tolerant window would let a site drift a
        # line or two while the backstop below still counted it correctly,
        # leaving the enumeration quietly wrong about where the code is.
        actual = File.readlines(path)[site[:line] - 1].to_s

        expect(actual).to include(site[:source]),
                          "#{site[:file]}:#{site[:line]} no longer contains #{site[:source].inspect} — " \
                          "the enumeration in this spec has drifted from the code it describes.\n" \
                          "  line #{site[:line]} is now: #{actual.strip.inspect}\n" \
                          "If the site merely MOVED, update :line. If it changed shape, " \
                          "re-derive its value set before touching anything else."
      end
    end
  end

  describe "every named category resolves to an insertable command" do
    sites.each do |site|
      it "#{site[:file]}:#{site[:line]} — #{site[:domain].truncate(80)}" do
        commands = site[:commands].call
        expect(commands).not_to be_empty, "a gate site with an empty value set is an enumeration bug"

        uninsertable = commands.reject { |c| GateComposedTaskCategories.command_insertable?(c) }
        unexpected   = uninsertable - broken

        expect(unexpected).to be_empty,
                              "#{site[:file]}:#{site[:line]} names system.task.<cmd> for " \
                              "#{unexpected.inspect}, which System::Task refuses to insert. " \
                              "Every such request fails closed: under the seeded auto_approve " \
                              "policy the gate creates a deferred operation and executes it " \
                              "INLINE (nothing is parked for approval), ExecuteTask#perform " \
                              "raises RecordInvalid on save!, the operation is marked failed and " \
                              "the caller gets a 422 that names a policy block rather than a " \
                              "missing command. Either add the command to System::Task::COMMANDS " \
                              "*and* give it a dispatch route, or remove the gate site."
      end
    end
  end

  # STALE-DIRECTION GUARD. Without this the exemption is a one-way ratchet that
  # stays in the file forever after the defect is fixed, quietly excusing the
  # next verb that lands on it.
  describe "the known-broken exemption cannot go stale" do
    it "every exempted command is STILL uninsertable" do
      wrongly_exempted = broken.select { |c| GateComposedTaskCategories.command_insertable?(c) }

      expect(wrongly_exempted).to be_empty,
                                  "#{wrongly_exempted.inspect} is now insertable, so the " \
                                  "IMP-8d944d656c0b exemption no longer describes reality. " \
                                  "Delete these entries from KNOWN_BROKEN_COMMANDS — the " \
                                  "exemption exists only for as long as the defect does."
    end

    it "every exempted command is actually named by an enumerated site" do
      named    = sites.flat_map { |site| site[:commands].call }.uniq
      orphaned = broken - named

      expect(orphaned).to be_empty,
                          "#{orphaned.inspect} is exempted but no enumerated gate site names " \
                          "it — the exemption is excusing nothing and must be deleted."
    end
  end

  # BACKSTOP ONLY — see the header. These scans find new SITES; they can never
  # find their value sets, which is why the enumeration above is the mechanism.
  describe "no unenumerated gate site has appeared" do
    it "every composed AND literal system.task gate site is enumerated" do
      found = GateComposedTaskCategories.scan(GateComposedTaskCategories::EXTENSION_ROOT)
              .merge(GateComposedTaskCategories.scan(GateComposedTaskCategories::CORE_ROOT, "CORE:"))
      expected = GateComposedTaskCategories.discoverable_enumeration

      surplus = found.reject { |file, count| expected[file] == count }

      expect(surplus).to be_empty,
                         "unenumerated system.task gate sites — file => (found, enumerated): " \
                         "#{surplus.map { |f, c| [ f, [ c, expected[f] ] ] }.to_h.inspect}. " \
                         "A gate site exists that this spec does not enumerate (or one was " \
                         "removed). Add it to GATE_SITES together with the SET of values its " \
                         "action_category can take — a scan can see the site but not the " \
                         "vocabulary it emits, and that gap is exactly what IMP-8d944d656c0b was. " \
                         "Both shapes count: composed (\"system.task.\#{...}\") and literal " \
                         "(action_category: \"system.task.<verb>\")."
    end
  end
end
