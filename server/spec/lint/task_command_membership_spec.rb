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
# `create/build/build_stubbed(:system_task, ...)` — extracts every literal
# `command:` string passed at those sites, and fails if any value is not a
# member of System::Task::COMMANDS. It also pins the factory's own default
# `command { "..." }` literal.
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

  let(:spec_root) { File.expand_path("..", __dir__) }

  # Matches the head of a System::Task construction site. The opening paren is
  # located separately so `System::Task.create! (` and multi-line arg lists both
  # work.
  let(:construction_head) do
    /
      System::Task\.(?:create!?|new)\s*\( |
      \b(?:create|build|build_stubbed)\(\s*:system_task\b
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

  def command_literals(args)
    args.scan(/\bcommand:\s*(["'])([^"']*)\1/).map(&:last)
  end

  it "every command: literal at a System::Task construction site is a member of COMMANDS" do
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
        command_literals(args).each do |value|
          next if System::Task::COMMANDS.include?(value)
          next if Array(intentional_invalids[rel]).include?(value)

          line = src[0, match_begin].count("\n") + 1
          violations << "#{rel}:#{line} command: #{value.inspect}"
        end
      end
    end

    # If the scanner ever finds nothing at all, the regex has rotted — that is
    # a "fix this spec" signal, not a green result.
    expect(scanned_sites).to be > 50

    expect(violations).to be_empty, <<~MSG
      Spec fixtures hardcode System::Task command values that are not in
      System::Task::COMMANDS — these examples will fail on the inclusion
      validation before exercising anything:

      #{violations.join("\n")}

      Repoint each at a current member of System::Task::COMMANDS (do not
      re-add retired commands to the model). If an example intentionally
      asserts rejection of an unlisted command, add it to
      intentional_invalids in #{File.basename(__FILE__)}.
    MSG
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
