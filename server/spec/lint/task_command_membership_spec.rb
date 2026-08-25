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
      "models/system/task_spec.rb" => %w[not_a_real_command]
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
      "models/system/task_spec.rb" => [56],
      # `command` is a keyword param defaulting to a listed literal
      # ("sync_modules"); every caller in the file passes a listed literal.
      "models/system/preserves_task_history_spec.rb" => [28],
      "requests/api/v1/system/worker_api/janitor_spec.rb" => [27],
      "services/system/fleet/sensors/stuck_task_backlog_sensor_spec.rb" => [31],
      # `command` ranges over a hardcoded
      # %w[start stop restart reboot terminate] list in the enclosing .each.
      "services/system/runtime/control_instance_spec.rb" => [38]
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

    expect(assignments.map { |a| a[:kind] }).to eq([:literal])
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
