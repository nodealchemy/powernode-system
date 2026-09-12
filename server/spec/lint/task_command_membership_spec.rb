# frozen_string_literal: true

require "rails_helper"

# IMP-971d672eabc8 — spec fixtures kept hardcoding System::Task command values
# that had been retired from System::Task::COMMANDS ("provision_node",
# "configure", "test_cmd", "other_cmd"). Every such example fails on the
# inclusion validation — "Command is not included in the list" — before it
# ever exercises the behavior it exists to cover, and those standing reds
# masked real regressions in the same files on every gate run. The factory
# default rotted the same way once before ("sync", retired with the
# zero-caller dispatch verbs — see the comment in system_factories.rb).
#
# This guard scans the spec tree for System::Task CONSTRUCTION sites —
# `System::Task.create/create!/new(...)` and the FactoryBot forms
# `create/build/build_stubbed/create_list/build_list(:system_task, ...)` —
# extracts every `command:` value passed at those sites, and fails if a
# literal is not a member of System::Task::COMMANDS. It also pins the
# factory's own default `command { "..." }` literal.
#
# IMP-fc1c3f3d805a — the original extractor matched only a plain quoted
# string (`/\bcommand:\s*(["'])([^"']*)\1/`), so four forms slipped past it
# UNSEEN rather than merely unchecked: interpolated values
# (`command: "#{verb}"`), symbol values (`command: :restart`), variable/
# expression values (`command: cmd`), and `create_list`/`build_list` sites
# (the old construction-head regex didn't even match the call). Per operator
# direction this guard does NOT try to evaluate a non-literal value — it
# fails loud instead, so an unchecked site is a visible decision (either
# convert it to a literal, or audit it once and add it to
# ACKNOWLEDGED_UNCHECKED_SITES below) rather than a silent skip.
#
# What it does NOT catch (deliberately): attribute assignment after
# construction (`task.command = '...'`) and `update_column` writes — those are
# how task_spec.rb exercises the legacy-row grandfathering, and they bypass or
# intentionally violate the validation. Examples that PROVE the validation
# rejects an unlisted command at construction belong in INTENTIONAL_INVALIDS
# below, keyed by spec-relative path.
RSpec.describe "System::Task command membership across the spec tree" do
  # Values that are deliberately invalid: the example asserts the validation
  # rejects them. Keyed by path relative to server/spec/.
  let(:intentional_invalids) do
    {
      # `terminate` joined this list in campaign 01a0790b increment 2: the spec
      # asserts the model now REFUSES it, so the literal is deliberate and its
      # absence from COMMANDS is the property under test.
      "models/system/task_spec.rb" => %w[not_a_real_command terminate]
    }
  end

  # Construction sites where `command:` is bound to a value this scanner
  # deliberately refuses to evaluate (interpolated string / symbol /
  # variable / expression) — audited by hand and confirmed every value the
  # binding can carry at runtime is a System::Task::COMMANDS member. Keyed
  # by path relative to server/spec/, value is the array of construction-site
  # line numbers (the line the `create`/`build`/... call starts on, same
  # line a violation would report). Keying on the line rather than the value
  # means an edit that shifts the line forces re-acknowledgment instead of
  # silently continuing to match.
  let(:acknowledged_unchecked_sites) do
    {
      # `cmd` ranges over described_class::COMMANDS itself — the example IS
      # the membership check.
      # RE-ACKNOWLEDGED TWICE. Increment 2 inserted examples above this site
      # (56 -> 120); increment 3 replaced the COMMAND_REGISTRY equality example
      # with the comment explaining where that oracle went (120 -> 133). The
      # re-audit is the point of keying on the line — `command: cmd` still
      # ranges over System::Task::COMMANDS itself, so every value the binding
      # can carry is a member by construction.
      "models/system/task_spec.rb" => [ 133 ],
      # `command` is a keyword param defaulting to a listed literal
      # ("sync_modules"); every caller in the file passes a listed literal.
      "models/system/preserves_task_history_spec.rb" => [ 28 ],
      # MOVED 27 -> 28 when that spec's header gained the note recording
      # WorkerApi::TasksController's deletion. RE-AUDITED — still the
      # `create(:system_task, ..., command: command, ...)` inside #stuck_task,
      # whose `command:` keyword still defaults to the listed literal
      # "sync_modules", and every caller in the file still takes that default
      # or passes one.
      "requests/api/v1/system/worker_api/janitor_spec.rb" => [ 28 ],
      "services/system/fleet/sensors/stuck_task_backlog_sensor_spec.rb" => [ 31 ],
      # `command` is a keyword param of the local #task_with helper (:955),
      # defaulting to "sync_modules". AUDITED by grepping every `task_with`
      # call in the file — 22 of them. Only THREE pass `command:` at all:
      # :1076 "sync_modules", :1077 "apply_config", :1078 "upgrade_boot_image".
      # The other 19 take the default. So the binding carries three distinct
      # values, all three COMMANDS members.
      #
      # (An earlier draft of this note listed eight line numbers as "every
      # caller" and said four values. Both were wrong — it had enumerated the
      # calls that pass ANY keyword, not the calls that pass `command:`.)
      #
      # THIS SITE WAS RED ON develop, not introduced by campaign 01a0790b: it
      # arrived with the IMP-9cc83aa64bff terminate-cleanup examples and was
      # merged without this lint being run. Acknowledged here rather than left
      # for a later increment to trip over.
      #
      # MOVED 956 -> 957 in increment 3: the `before { allow(WorkerDispatch)... }`
      # line above it went with System::Task's dispatch after_commit, and the
      # comment replacing it is longer. Re-audited — the call sites are
      # unchanged, still three distinct values.
      "models/system/node_instance_spec.rb" => [ 957 ],
      # `command: command` inside a HEREDOC FIXTURE (<<~RUBY) that the census
      # scanner parses as text — it is source code under test, never executed,
      # and constructs no System::Task. The scanner's own "FIRES on the variable
      # shape a literal grep cannot see" example is the whole point of it.
      # MOVED 411 -> 415 in increment 3: this spec's own COMMANDS boundary
      # comment was rewritten (it named the deleted COMMAND_REGISTRY /
      # AGENT_DELEGATED_COMMANDS split), which is four lines longer. RE-AUDITED
      # — line 415 is still `::System::Task.create!(` inside the <<~RUBY
      # heredoc fixture, still parsed as text, still constructing nothing.
      #
      # Red on develop for the same REASON as the entry above but from a
      # different commit — this site arrived with dbb26a93
      # (IMP-498cd7db446d), the node_instance_spec one with 9b9323b1
      # (IMP-9cc83aa64bff). Neither was acknowledged there; both are here.
      #
      # RE-PINNED 415/486 -> 498 at the merge of campaign 01a0790b into develop.
      # The two branches acknowledged this site at different lines and
      # DESCRIBED IT DIFFERENTLY — campaign as "a heredoc fixture the scanner
      # parses as text", dev-improve as "the scanner's own self-test" — which
      # read as two sites. It is ONE: the <<~RUBY block of the "FIRES on the
      # variable shape a literal grep cannot see" example. Keeping both
      # spellings would have been a duplicate hash key silently dropping one,
      # and keeping both LINES failed this file's own staleness guard, which is
      # what caught the error. RE-AUDITED — 498 is the
      # `::System::Task.create!(` head inside that heredoc, still synthetic
      # source handed to the scanner as a string, still constructing nothing.
      #
      # MOVED 498 -> 496 when Api::V1::System::WorkerApi::TasksController was
      # deleted: its `#create` key left this census (net -2 lines above the
      # site). RE-AUDITED — 496 is still the `::System::Task.create!(` head
      # inside the <<~RUBY heredoc of the "FIRES on the variable shape a literal
      # grep cannot see" example, still synthetic source handed to the scanner
      # as a string, still constructing nothing.
      #
      # MOVED 496 -> 513 when the lint_discovery producer was censused (campaign
      # 01a08c9b D1b). It moved TWICE for that one change: the entry landed
      # :gated at 13 lines (496 -> 509) and was then re-dispositioned to
      # :acknowledged, which made it 17 (509 -> 513). RE-AUDITED — 513 is still
      # the `::System::Task.create!(` head inside the <<~RUBY heredoc of the
      # "FIRES on the variable shape a literal grep cannot see" example, still
      # synthetic source handed to the scanner as a string, still constructing
      # nothing.
      "lint/on_node_task_producer_census_spec.rb" => [ 513 ],
      # (spec/services/system/runtime/control_instance_spec.rb was acknowledged
      # here until increment 3 DELETED it, along with the
      # System::Runtime::ControlInstance class it covered and the server
      # dispatch arm that reached it. Removed rather than left pointing at a
      # file that no longer exists — see the staleness guard below, which now
      # makes that mistake impossible to leave in place.)
      # `command_insertable?` is an INSERTABILITY PROBE, not a fixture. It is
      # reached from two call sites (:310, :332) whose values are the command
      # names DECLARED BY GATE SITES plus KNOWN_BROKEN_COMMANDS — precisely the
      # set whose membership is unknown, which is what the enclosing examples
      # exist to decide. Requiring a listed literal here would invert the file:
      # the probe must be free to ask about a name System::Task refuses, and
      # the "every named category resolves to an insertable command" example is
      # red exactly when one does. It calls .new + .valid? and never persists,
      # so an unlisted value reaches no database and no dispatch route.
      #
      # MOVED TWICE and RE-AUDITED at the merge of campaign 01a0790b into
      # develop: increment 3 corrected three comment blocks above it (243 ->
      # 246), the dev-improve line moved it independently (234), and repinning
      # that file's own system_fleet_tool gate site in this same merge added
      # three comment lines above it (246 -> 249). RE-AUDITED — line 249 is
      # still `::System::Task.new(command: command, ...)` inside
      # #command_insertable?, which calls .new + .valid? and never persists.
      "integration/gate_composed_task_categories_spec.rb" => [ 249 ]
    }
  end

  let(:spec_root) { File.expand_path("..", __dir__) }

  # Matches the head of a System::Task construction site. The opening paren is
  # located separately so `System::Task.create! (` and multi-line arg lists both
  # work.
  let(:construction_head) do
    /
      System::Task\.(?:create!?|new)\s*\( |
      \b(?:create|build|build_stubbed|create_list|build_list)\(\s*:system_task\b
    /x
  end

  # Returns the balanced-paren argument segment starting at open_idx (the index
  # of the opening paren), skipping over string literals and comments so a ")"
  # inside either cannot end the capture early.
  def call_args(src, open_idx)
    depth = 0
    quote = nil
    i = open_idx
    while i < src.length
      ch = src[i]
      if quote
        quote = nil if ch == quote && src[i - 1] != "\\"
      elsif ch == '"' || ch == "'"
        quote = ch
      elsif ch == "#"
        i = src.index("\n", i) || src.length
        next
      elsif ch == "("
        depth += 1
      elsif ch == ")"
        depth -= 1
        return src[open_idx..i] if depth.zero?
      end
      i += 1
    end
    src[open_idx..] # unbalanced (EOF) — scan what we have
  end

  # Classifies the value bound to a `command:` keyword, given the source text
  # starting immediately after `command:` and its whitespace. A plain single-
  # quoted string, or a double-quoted string with no `#{` interpolation, is a
  # checkable :literal. Everything else — an interpolated string, a symbol, a
  # bare variable, a method call/expression — is :unchecked: this scanner
  # does not try to resolve it (IMP-fc1c3f3d805a operator direction).
  def classify_command_value(rest)
    if rest =~ /\A'((?:[^'\\]|\\.)*)'/
      { kind: :literal, value: Regexp.last_match(1), raw: Regexp.last_match(0) }
    elsif rest =~ /\A"((?:[^"\\]|\\.)*)"/
      content = Regexp.last_match(1)
      if content.include?('#{')
        { kind: :unchecked, raw: Regexp.last_match(0) }
      else
        { kind: :literal, value: content, raw: Regexp.last_match(0) }
      end
    elsif rest =~ /\A:[A-Za-z_]\w*[?!]?/
      { kind: :unchecked, raw: Regexp.last_match(0) }
    else
      token = rest[/\A[^,)\n]+/].to_s.strip
      { kind: :unchecked, raw: token.empty? ? "(unparseable)" : token }
    end
  end

  # Every `command:` keyword occurrence within a construction site's argument
  # list, classified. There can be more than one match (e.g. a nested hash
  # inside `options:` that itself happens to use the key `command:`) — that's
  # a rare false positive this scanner accepts in exchange for not having to
  # parse Ruby for real.
  def command_assignments(args)
    assignments = []
    args.to_enum(:scan, /\bcommand:\s*/).each do
      val_start = Regexp.last_match.end(0)
      assignments << classify_command_value(args[val_start..])
    end
    assignments
  end

  # THE ACKNOWLEDGMENT LIST MUST NOT OUTLIVE WHAT IT ACKNOWLEDGES.
  #
  # Each entry above suppresses a violation at one file:line. Nothing made an
  # entry decay when its file was deleted or its site stopped being reported —
  # so a stale entry sat there suppressing nothing while reading as a
  # deliberate, audited exemption. Increment 3 hit exactly that case: it
  # deleted control_instance_spec.rb, whose acknowledgment would otherwise
  # still be listed.
  #
  # THE PREDICATE IS THE SCANNER ITSELF, and two earlier drafts of this guard
  # got that wrong by trying to re-derive it. The first looked for "command:" on
  # the pinned line; the second, for a `construction_head` match on it. BOTH
  # rest on "the pin is the line the construction call starts on", which THIS
  # FILE ASSERTED AND WHICH IS FALSE: the line is computed from the match offset,
  # so for a heredoc fixture (on_node_task_producer_census_spec.rb) or a
  # multi-line helper (gate_composed_task_categories_spec.rb) it lands on an
  # `it` block or a comment. Asking `unchecked_sites` — the same scan the
  # membership example runs — is exact by construction and cannot drift from it.
  it "acknowledges only sites the scanner still reports" do
    live = unchecked_sites

    stale = acknowledged_unchecked_sites.filter_map do |rel, lines|
      next "#{rel} (file no longer exists)" unless File.exist?(File.join(spec_root, rel))

      orphaned = Array(lines) - live[rel]
      "#{rel} lines #{orphaned.inspect} are no longer reported as unchecked" if orphaned.any?
    end

    expect(stale).to be_empty, <<~MSG
      acknowledged_unchecked_sites names sites that are gone or no longer flagged:

      #{stale.join("\n")}

      An acknowledgment that suppresses nothing is worse than no acknowledgment:
      it reads as an audited exemption. Delete the entry if the site is gone; if
      it moved, re-audit the values the binding can carry and re-pin it to the
      line the scanner now reports (the failure message of the membership
      example prints it).
    MSG
  end

  # Every (relative path, line) at which the scanner currently finds an
  # UNCHECKED `command:` binding — precisely the set `acknowledged_unchecked_sites`
  # exists to suppress. Both the membership example and the staleness guard read
  # it, so neither can drift from the other's idea of what a site is.
  def unchecked_sites
    sites = Hash.new { |h, k| h[k] = [] }

    Dir.glob(File.join(spec_root, "**", "*_spec.rb")).sort.each do |path|
      rel = path.delete_prefix("#{spec_root}/")
      next if rel == "lint/task_command_membership_spec.rb"

      src = File.read(path)
      src.to_enum(:scan, construction_head).each do
        match_begin = Regexp.last_match.begin(0)
        open_idx = src.index("(", match_begin)
        next unless open_idx

        args = call_args(src, open_idx)
        line = src[0, match_begin].count("\n") + 1
        sites[rel] << line if command_assignments(args).any? { |a| a[:kind] == :unchecked }
      end
    end

    sites
  end

  it "every command: value at a System::Task construction site is a checked COMMANDS member" do
    violations = []
    scanned_sites = 0

    Dir.glob(File.join(spec_root, "**", "*_spec.rb")).sort.each do |path|
      rel = path.delete_prefix("#{spec_root}/")
      next if rel == "lint/task_command_membership_spec.rb"

      src = File.read(path)
      src.to_enum(:scan, construction_head).each do
        match_begin = Regexp.last_match.begin(0)
        open_idx = src.index("(", match_begin)
        next unless open_idx

        scanned_sites += 1
        args = call_args(src, open_idx)
        line = src[0, match_begin].count("\n") + 1

        command_assignments(args).each do |assignment|
          if assignment[:kind] == :unchecked
            next if Array(acknowledged_unchecked_sites[rel]).include?(line)

            violations << "#{rel}:#{line} command: #{assignment[:raw]} " \
              "(UNCHECKED — not a literal the scanner can verify; convert to a " \
              "literal, or audit and add to acknowledged_unchecked_sites)"
            next
          end

          value = assignment[:value]
          next if System::Task::COMMANDS.include?(value)
          next if Array(intentional_invalids[rel]).include?(value)

          violations << "#{rel}:#{line} command: #{value.inspect}"
        end
      end
    end

    # If the scanner ever finds nothing at all, the regex has rotted — that is
    # a "fix this spec" signal, not a green result. 136 is the tree's current
    # count with create_list/build_list included in construction_head (no
    # site currently uses either form, so the count didn't move — but the
    # regex now covers them).
    expect(scanned_sites).to be >= 136

    expect(violations).to be_empty, <<~MSG
      Spec fixtures hardcode a System::Task command that is not in
      System::Task::COMMANDS, or bind command: to a value this scanner
      cannot verify (interpolated string / symbol / variable / expression)
      without an explicit acknowledgment:

      #{violations.join("\n")}

      Repoint a bad literal at a current member of System::Task::COMMANDS (do
      not re-add retired commands to the model). If an example intentionally
      asserts rejection of an unlisted command, add it to
      intentional_invalids. If a command: value is legitimately unchecked
      (e.g. it ranges over System::Task::COMMANDS itself), audit every value
      it can carry and add the site to acknowledged_unchecked_sites in
      #{File.basename(__FILE__)}.
    MSG
  end

  it "classifies interpolated strings, symbols, and variables as unchecked instead of silently skipping them" do
    {
      'command: "#{verb}"'       => :unchecked, # interpolated
      "command: :restart"        => :unchecked, # symbol
      "command: cmd"             => :unchecked, # bare variable
      "command: compute_cmd(x)"  => :unchecked, # method call / expression
      'command: "restart"'       => :literal,   # control: plain double-quoted literal
      "command: 'restart'"       => :literal    # control: plain single-quoted literal
    }.each do |snippet, expected_kind|
      assignments = command_assignments(snippet)
      expect(assignments.size).to eq(1), "expected exactly one command: assignment in #{snippet.inspect}"
      expect(assignments.first[:kind]).to eq(expected_kind),
        "expected #{snippet.inspect} to classify as #{expected_kind.inspect}, got #{assignments.first[:kind].inspect}"
    end
  end

  it "recognizes create_list/build_list(:system_task, ...) as construction sites and still checks their literals" do
    src = 'create_list(:system_task, 2, account: account, command: "not_a_real_command")'
    expect(src).to match(construction_head)

    match_begin = src =~ construction_head
    open_idx = src.index("(", match_begin)
    args = call_args(src, open_idx)
    assignments = command_assignments(args)

    expect(assignments.map { |a| a[:kind] }).to eq([ :literal ])
    expect(assignments.first[:value]).to eq("not_a_real_command")
    expect(System::Task::COMMANDS).not_to include(assignments.first[:value])
  end

  it "the :system_task factory default command is a member of COMMANDS" do
    factory_src = File.read(File.join(spec_root, "factories", "system_factories.rb"))
    factory_block = factory_src[/factory :system_task,.*?(?=^  factory |\z)/m]
    expect(factory_block).to be_present, "could not locate factory :system_task in system_factories.rb"

    default = factory_block[/^\s*command\s*\{\s*(["'])([^"']+)\1\s*\}/, 2]
    expect(default).to be_present, "could not parse the factory's default command literal"
    expect(System::Task::COMMANDS).to include(default)
  end
end
