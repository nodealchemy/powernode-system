# frozen_string_literal: true

require "pathname"

# IMP-498cd7db446d — the scanner behind spec/lint/on_node_task_producer_census_spec.rb.
#
# It lives here, taking (path, source) rather than reading the tree itself, for
# one reason: a detector that can only run against the real tree cannot be
# tested. The census spec drives it BOTH ways — over the real source roots for
# the census, and over synthetic sources to prove each arm fires. On
# 2026-09-06 this project shipped a lint that scanned the wrong file, matched
# nothing, passed green, and would have missed the very offender that motivated
# it; the only thing that caught it was mutating the real offender and watching
# the lint stay green.
#
# ══ WHAT IT CLASSIFIES ════════════════════════════════════════════════════
#
# Every System::Task CONSTRUCTION site becomes one of:
#
#   ON-NODE LITERAL — command: "sync_modules" / "apply_config". In scope.
#   UNRESOLVABLE    — the command is anything not readable as a plain string
#                     literal: a bare variable (`command: command`), an
#                     expression (`command: @batch.member_task_command`), a
#                     hash built elsewhere (`Task.new(attrs)`), or no readable
#                     `command:` at all. In scope, ALWAYS.
#   OTHER LITERAL   — some other command. Out of scope, not reported.
#
# Unresolvable is in scope BY DESIGN and it is the point of the file.
# DecisionEngine#dispatch_reconcile_task passes `command: command`, so the
# single most important producer — the one behind the observed incident — is
# invisible to any literal `command: "sync_modules"` grep. Treating "I cannot
# read this statically" as a census OBLIGATION rather than an absence is what
# makes the guard fail closed.
#
# ══ WHY THE CALL FORMS ARE PLURAL ═════════════════════════════════════════
#
# An independent review of the first version found two REAL producers in this
# tree that a `System::Task.create!` scan cannot see, and one of them is a
# genuine ungated path that exists today:
#
#   Executors::ExecuteTask — `::System::Task.new(attrs)` + `task.save!`,
#     reached from POST /api/v1/system/tasks, whose permitted params include
#     :command and whose System::Task::COMMANDS contains sync_modules and
#     apply_config. That is a sixth producer, and the first scanner reported
#     nothing about it.
#   NodeInstanceGating#create_instance_operation — the ASSOCIATION form,
#     `current_account.system_tasks.create(command: command, ...)`: non-bang,
#     no `System::Task` receiver, variable command. Invisible three ways over.
#
# So CALL_FORMS matches construction, not one spelling of it. A false positive
# is cheap (it forces a census entry); a false negative is the whole bug.
#
# ══ WHY THE EXTENT IS PAREN-BALANCED, NOT A BYTE WINDOW ═══════════════════
#
# The first version read `command:` from a fixed 600-byte window. The same
# review showed that steals the NEXT call's command: the two creates in
# storage/gateway_provisioning_service.rb are 460 bytes apart, so a new
# `Task.create!(**attrs)` above them would have picked up
# `"storage.gateway.deprovision"` from its neighbour, classified OUT OF SCOPE,
# and been dropped — turning the fail-closed case into a silent pass. The
# extent is now the construction call's own parentheses.
module OnNodeTaskProducers
  # The two on-node reconcile commands. NOTE the deliberate boundary: this is
  # NOT all of System::Task::COMMANDS (upgrade_boot_image, the storage.* verbs,
  # ci.module_build, ci.package_build, probe.module_smoke are outside it), and
  # the census does not cover those — see the census spec's boundary section.
  # (This used to name ExecutionDispatcher::AGENT_DELEGATED_COMMANDS as the
  # wider set; that constant was deleted with the dispatcher in campaign
  # 01a0790b increment 3.)
  ON_NODE_COMMANDS = %w[sync_modules apply_config].freeze

  # Construction of a System::Task, in every spelling this tree uses or could
  # plausibly grow: create / create! / new / build, via the class or via a
  # `tasks` / `system_tasks` association.
  CALL_FORMS = /
    (?:System::Task\.(?:create!?|new))
    |
    (?:\.(?:system_tasks|tasks)\.(?:create!?|new|build))
  /x

  # `command:` as a whole key — `sub_command:` must not match, or a site with
  # a decoy key ahead of the real one classifies on the decoy and silently
  # drops out of scope.
  COMMAND_KEY = /(?<![A-Za-z0-9_])command:\s*/

  # Fallback extent when the construction is not followed by `(` — e.g.
  # `tasks.create key: value`. Rare, but it must not scan to end-of-file.
  UNPARENTHESIZED_EXTENT = 400

  Site = Struct.new(:path, :method_name, :command, :shape, :offset, keyword_init: true) do
    # Keyed by method, NOT by line: line numbers move with every edit above
    # them (two commits shifted these very sites on the day this was written),
    # and a census whose keys churn gets relaxed rather than maintained.
    #
    # A method can hold more than one site, so the key is NOT unique — the
    # census pins a per-key COUNT for exactly that reason. Without it, adding
    # a second ungated create! to an already-censused method is invisible.
    def key
      "#{path}##{method_name}"
    end

    def in_scope?
      shape == :unresolvable || (shape == :literal && ON_NODE_COMMANDS.include?(command))
    end
  end

  class << self
    # @param path [String] repo-relative, used only to build the key
    # @param source [String] the file's bytes
    # @return [Array<Site>]
    def scan(path, source)
      src = blank_comments(source)
      sites = []

      src.to_enum(:scan, CALL_FORMS).each do
        m = Regexp.last_match
        next if inside_string_literal?(src, m.begin(0))

        sites << classify(path, src, m.begin(0), m.end(0))
      end

      sites
    end

    # The real census input. Takes the roots explicitly so the census spec
    # states its own path boundary rather than inheriting a hidden one.
    def scan_roots(*roots)
      roots.flat_map do |root|
        root = Pathname.new(root)
        next [] unless root.directory?

        Pathname.glob(root.join("**", "*.rb")).sort.flat_map do |file|
          scan(file.relative_path_from(root.parent).to_s, file.read)
        end
      end
    end

    def in_scope(sites)
      sites.select(&:in_scope?)
    end

    # The text between the enclosing `def` and this site, comments blanked.
    #
    # This is what a :gated census entry is checked against, and the reason it
    # is a SPAN rather than the whole file: system_fleet_tool.rb holds two
    # censused producers and mentions `on_node_dispatch_refusal` four times,
    # twice in comments. A file-level `include?` let either gate be deleted
    # while the other method's live call — or a comment — kept the census
    # green. "A guard runs BEFORE this construction, in THIS method" is the
    # property; nothing weaker is worth asserting.
    def guard_span(source, site)
      src = blank_comments(source)
      head = src[0...site.offset]
      def_at = head.rindex(/^\s*def\s/)
      return head if def_at.nil?

      head[def_at..]
    end

    private

    # Blank full-line comments IN PLACE (same byte length) so offsets stay
    # valid. Without this the scanner reported a site in
    # governance/policy_declarations.rb, where the string appears inside prose
    # about which producers bypass the gate. Only whole-line comments: a
    # trailing `#` cannot be told from a `#` inside a string without parsing,
    # and blanking too much would hide a real call site — the dangerous
    # direction. The census self-tests both halves of that trade.
    def blank_comments(source)
      source.gsub(/^[ \t]*#.*$/) { |m| " " * m.length }
    end

    # A match sitting INSIDE a double-quoted string is not a call site. The
    # tree really contains these: `authorize_worker_permission!(
    # "system.tasks.create")` matches `.tasks.create` textually, and censusing
    # a permission string as a task producer would be noise that makes the
    # census read as untrustworthy — the state in which guards get relaxed.
    #
    # Heuristic, deliberately: an odd number of unescaped double quotes before
    # the match ON ITS OWN LINE means it is inside one. That is exact for the
    # single-line case, which is every occurrence in this tree, and it fails in
    # the SAFE direction for a multi-line string (the match is kept and must be
    # censused). Strings are not blanked wholesale because the literal this
    # scanner exists to read — command: "sync_modules" — is itself a string.
    def inside_string_literal?(src, idx)
      line_start = (src.rindex("\n", idx) || -1) + 1
      before = src[line_start...idx].to_s

      before.scan(/(?<!\\)"/).length.odd?
    end

    def classify(path, src, begin_idx, end_idx)
      name = enclosing_method(src, begin_idx)
      arg  = read_command(call_extent(src, end_idx))

      # No readable `command:` inside this call's OWN extent — a splat, a
      # prebuilt hash, a shape nobody has written yet. Fail closed.
      return site(path, name, nil, :unresolvable, begin_idx) if arg.nil?

      literal = arg[/\A"([a-z_.0-9]+)"\z/, 1]
      return site(path, name, literal, :literal, begin_idx) if literal

      site(path, name, arg, :unresolvable, begin_idx)
    end

    def site(path, name, command, shape, offset)
      Site.new(path: path, method_name: name, command: command, shape: shape, offset: offset)
    end

    # The construction call's own text: from its `(` to the matching `)`, so a
    # neighbouring call's `command:` can never be read as this one's.
    def call_extent(src, end_idx)
      rest = src[end_idx..].to_s
      lead = rest[/\A[ \t]*/].to_s
      return rest[0, UNPARENTHESIZED_EXTENT].to_s unless rest[lead.length] == "("

      depth = 0
      i = lead.length
      while i < rest.length
        case rest[i]
        when "(" then depth += 1
        when ")"
          depth -= 1
          return rest[lead.length..i].to_s if depth.zero?
        end
        i += 1
      end

      # Unbalanced (not valid Ruby) — return nothing, which classifies the
      # site UNRESOLVABLE. Fail closed.
      ""
    end

    # Stops at a comma, a newline, OR a closing paren. The paren matters: a
    # single-line construction ends `command: "sync_modules")`, and capturing
    # the `)` made the value fail the string-literal test, so a perfectly
    # readable literal was misclassified UNRESOLVABLE. That is the safe
    # direction — it becomes a census obligation rather than a silent drop —
    # but it made every single-line site unresolvable, which would have buried
    # the literal arm under noise. Caught by this file's own self-tests.
    def read_command(body)
      return nil if body !~ COMMAND_KEY

      body[Regexp.last_match.end(0)..][/\A[^,\n)]+/]&.strip
    end

    # The nearest `def` above the call site.
    def enclosing_method(src, idx)
      head = src[0...idx]
      at = head.rindex(/^\s*def\s/)
      return "(toplevel)" if at.nil?

      head[at..][/def\s+(?:self\.)?([a-z_][a-z_0-9]*[?!=]?)/, 1] || "(toplevel)"
    end
  end
end
