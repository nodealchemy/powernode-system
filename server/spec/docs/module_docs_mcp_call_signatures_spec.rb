# frozen_string_literal: true

require "rails_helper"

# IMP-2dd87ade5010 — a worked example that calls an MCP verb with parameters
# the tool does not accept fails at the moment an operator is trusting it most,
# and teaches a wrong mental model of the API surface before it fails.
#
# module-authoring.md and 02-first-module.md documented
# system_promote_module_version as ({ id:, to: }) and
# system_list_module_versions as ({ module_name: }); the declared parameters are
# module_version_id/target_state and module_id. The name form is worse than a
# rejected key: list_module_versions' executor calls account_modules.find, so a
# module NAME raises RecordNotFound rather than returning the documented list.
#
# The pin is mechanical, not a spelling test: it parses every
# `platform.<verb>({ ... })` example in the covered files and checks the
# top-level keys against that verb's OWN action_definitions, resolved through
# PlatformApiToolRegistry::TOOLS. It therefore keeps working when a parameter
# is renamed in the tool, which is the drift that produced this finding.
#
# What it does NOT cover:
#   * RESPONSE shape. The `// → { ... }` comments beside these calls are a
#     separate claim with its own drift (02-first-module.md and
#     module-authoring.md both document version fields the serializer does not
#     emit); filed separately rather than rewritten here.
#   * Whether the values are meaningful — only that the KEYS are accepted and
#     that every required parameter is supplied.
#   * Prose mentions of a verb with no call site, and docs outside COVERED_DOCS.

# Namespaced rather than left on Object: these are generic names, and a bare
# COVERED_DOCS/KNOWN_BROKEN inside a describe block lands as a top-level
# constant that another spec can clobber (an order-dependent "already
# initialized constant" flake).
module ModuleDocsMcpCallSignatures
  # Every doc whose `platform.<verb>({ ... })` examples are known to match the
  # verbs' declared parameters. Widening this list is the acceptance signal for
  # IMP-84c318bf31f9: a file enters only once every call site in it passes.
  #
  # Scope note (IMP-84c318bf31f9, measured 2026-08-30): 31 docs under
  # extensions/system/docs contain a platform call. Pointing this same parser at
  # all 31 reports 207 failing examples in 24 of them; 3 of those failures are
  # the two KNOWN_BROKEN sites below, so 204 across 23 files remain to drain.
  # It is drained in reviewable batches rather than one mass edit — 31 operator
  # docs changed in a single unreviewed commit is the bulk-change hazard the
  # repo's own guardrails call out. Add files here as batches land.
  #
  # BATCH 0 — files that already passed the tree-wide sweep with no edit. They
  # are listed to stop a future edit regressing them, not because anything was
  # fixed in them.
  COVERED_DOCS = [
    "docs/CLAUDE_TMUX_MODULE.md",
    "docs/SDWAN_ARCHITECTURE.md",
    "docs/runbooks/acme-issuance.md",
    "docs/runbooks/module-authoring.md",
    "docs/runbooks/template-authoring.md",
    "docs/runbooks/vault-credential-restoration.md",
    "docs/tutorials/02-first-module.md",
    "docs/tutorials/06-rolling-upgrade.md",
    # BATCH 3 — no doc edit: its only failure was a `// ...same inputs...`
    # elision, which the required-parameter check now correctly exempts. It is
    # here so the exemption itself has live coverage in this spec.
    "docs/runbooks/expose-service.md",
    # BATCH 1 — the bare `id:` rename family. 24 call sites across 14 files
    # passed a resource id under the key `id` where the verb declares
    # `<resource>_id`; the values were already ids, so it was a pure key
    # rename. Only these two files became fully clean as a result.
    "docs/runbooks/storage-migration.md",
    "docs/tutorials/13-expose-service-tls.md"
  ].freeze

  # Call sites left BROKEN on purpose, each tracked by a filed finding, because
  # the verb cannot do what the surrounding prose says it does — correcting the
  # parameter names would make a fictional example look verified.
  #
  # Asserted STILL BROKEN rather than skipped, so the exclusion retires itself:
  # fixing the underlying finding reddens the example and forces its removal.
  KNOWN_BROKEN = {
    # 01a05174-974f-7968-9cf3-e665f42fdf17 — recent_events declares only
    # source_type/status/limit, emits no `kind` field, and NOTHING in the repo
    # emits the module.upgrade.* events this step tells an operator to poll for
    # (RollingModuleUpgradeExecutor is plan-only and has no emitter).
    ["docs/tutorials/06-rolling-upgrade.md", "recent_events"] => %w[kind_prefix],
    # 01a05174-e4c3-71c2-b89d-111ef3328576 — system_drift_report is per-instance
    # only. system_platform_maintenance({ op: "drift_check" }) is template-scoped
    # but its detector is a hardcoded `return false` stub, so there is no working
    # fleet-wide drift answer; renaming this key would quietly downgrade a
    # fleet-wide claim to a single-instance spot check.
    ["docs/tutorials/06-rolling-upgrade.md", "system_drift_report"] => %w[template_id]
  }.freeze
end

RSpec.describe "module docs: MCP worked examples vs. declared tool parameters" do
  ext_root = File.expand_path("../../..", __dir__)
  covered_docs = ModuleDocsMcpCallSignatures::COVERED_DOCS

  # Extract `platform.<verb>({ ... })` calls, returning [verb, top_level_keys,
  # line_number]. Brace/bracket depth aware, string aware, and skips `//`
  # comments INSIDE an argument literal, so a nested `options: { ... }`
  # contributes only `options` and a `// → { ... }` response comment is not
  # mistaken for an argument.
  #
  # A call written on a `//` comment LINE is still extracted and checked. That
  # is deliberate: a commented-out example is one an operator copies just the
  # same, so it should be as correct as a live one. It also means commenting a
  # call out does not silence this spec — the `documents at least one MCP call`
  # guard below is what catches a doc edit that drops every call and would
  # otherwise make this whole file pass vacuously.
  def self.extract_calls(text)
    calls = []
    text.to_enum(:scan, /platform\.([a-z0-9_]+)\(\s*\{/).each do
      verb = Regexp.last_match(1)
      open_brace = Regexp.last_match.end(0) - 1
      line = text[0...Regexp.last_match.begin(0)].count("\n") + 1
      body = balanced_body(text, open_brace)
      next if body.nil?

      calls << [verb, top_level_keys(body), line, elides_arguments?(body)]
    end
    calls
  end

  # Given the index of an opening `{`, return the text strictly inside its
  # matching `}`, or nil when the literal never closes (a truncated example).
  def self.balanced_body(text, open_index)
    depth = 0
    i = open_index
    in_string = nil
    while i < text.length
      ch = text[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && text[i + 1] == "/"
        i = text.index("\n", i) || text.length
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
        return text[(open_index + 1)...i] if depth.zero?
      end
      i += 1
    end
    nil
  end

  # Top-level keys of a JS object-literal body: identifiers at depth 0 that
  # start a `key:` pair or stand alone as ES6 shorthand.
  def self.top_level_keys(body)
    keys = []
    depth = 0
    i = 0
    at_key_position = true
    in_string = nil
    while i < body.length
      ch = body[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && body[i + 1] == "/"
        i = body.index("\n", i) || body.length
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
      elsif depth.zero? && ch == ","
        at_key_position = true
      elsif depth.zero? && at_key_position && ch.match?(/[A-Za-z_]/)
        ident = body[i..].match(/\A[A-Za-z_][A-Za-z0-9_]*/)[0]
        keys << ident
        at_key_position = false
        i += ident.length
        next
      elsif depth.zero? && !ch.match?(/\s/)
        at_key_position = false
      end
      i += 1
    end
    keys
  end

  # True when the example deliberately ELIDES arguments: a bare `...`, or a `//`
  # comment containing `...`, standing where a KEY would go. Such an example
  # makes no claim about completeness, so the required-parameter check is not
  # applied to it — every key it DOES show is still checked.
  #
  # Measured for IMP-84c318bf31f9: 15 of the tree's call sites are elided this
  # way, and each was producing a "missing required" failure that is a parser
  # artefact rather than a doc defect. Nothing goes stale: the exemption is read
  # out of the file, so deleting the `...` restores the check on the next run.
  #
  # `{ node_id: ... }` is deliberately NOT this case. There the ellipsis is a
  # VALUE, and the example still asserts that node_id is the whole argument
  # list — which for system_provision_instance is false and does not work.
  def self.elides_arguments?(body)
    depth = 0
    i = 0
    at_key_position = true
    in_string = nil
    while i < body.length
      ch = body[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && body[i + 1] == "/"
        line_end = body.index("\n", i) || body.length
        return true if depth.zero? && at_key_position && body[i...line_end].include?("...")

        i = line_end
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
      elsif depth.zero? && ch == ","
        at_key_position = true
      elsif depth.zero? && at_key_position && body[i, 3] == "..."
        return true
      elsif depth.zero? && !ch.match?(/\s/)
        at_key_position = false
      end
      i += 1
    end
    false
  end

  # verb => { name => required? }, from the verb's OWN declaration.
  #
  # Two registries, because MCP has two. PlatformApiToolRegistry::TOOLS maps a
  # verb to a tool class exposing action_definitions; the introspection verbs
  # (platform.health, platform.recent_events, ...) are declared instead as JSON
  # Schema in McpToolRegistrar::INTROSPECTION_TOOLS and appear in NEITHER the
  # registry nor any action_definitions. Consulting only the first reports a
  # real verb as unregistered, which is how a genuinely wrong call
  # (recent_events with a kind_prefix it does not accept) gets misdiagnosed as
  # a spec gap and waved through.
  def self.declared_parameters(verb)
    from_tool_registry(verb) || from_introspection_registry(verb)
  end

  def self.from_tool_registry(verb)
    klass_name = Ai::Tools::PlatformApiToolRegistry::TOOLS[verb]
    return nil if klass_name.nil?

    definition = klass_name.constantize.action_definitions[verb]
    return nil if definition.nil?

    (definition[:parameters] || {}).transform_keys(&:to_s)
                                   .transform_values { |spec| spec[:required] == true }
  end

  def self.from_introspection_registry(verb)
    tool = Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS
           .find { |t| t[:id] == "platform.#{verb}" }
    return nil if tool.nil?

    schema   = tool[:input_schema] || {}
    required = (schema[:required] || []).map(&:to_s)
    (schema[:properties] || {}).keys.map(&:to_s)
                               .index_with { |name| required.include?(name) }
  end

  # Call sites left BROKEN on purpose, each tracked by a filed finding, because
  # the verb cannot do what the surrounding prose says it does — correcting the
  # parameter names would make a fictional example look verified.
  #
  # These are asserted STILL BROKEN rather than skipped. A silent exclusion rots
  # into permanent suppression; this one retires itself, because fixing the
  # underlying finding reddens the example below and forces its removal.
  known_broken = ModuleDocsMcpCallSignatures::KNOWN_BROKEN
  exercised_exclusions = []

  covered_docs.each do |relative_path|
    describe relative_path do
      path = File.join(ext_root, relative_path)
      calls = extract_calls(File.read(path))

      it "documents at least one MCP call (the parser still matches this file)" do
        expect(calls).not_to be_empty
      end

      calls.each do |verb, keys, line, elided|
        declared = declared_parameters(verb)

        it "#{verb} at line #{line} is a registered MCP verb" do
          expect(declared).not_to(be_nil, "platform.#{verb} is not in PlatformApiToolRegistry::TOOLS")
        end

        next if declared.nil?

        tracked = known_broken[[relative_path, verb]]

        if tracked
          exercised_exclusions << [relative_path, verb]

          it "#{verb} at line #{line} is still the known-broken call its finding describes" do
            expect(keys & tracked).to(
              eq(tracked),
              "#{relative_path}:#{line} no longer calls #{verb} with #{tracked.inspect}. " \
              "If the tracked finding was fixed, delete this KNOWN_BROKEN entry so the " \
              "normal parameter checks apply to this call site."
            )
            expect(tracked - declared.keys).to(
              eq(tracked),
              "#{verb} now declares #{(tracked & declared.keys).inspect}. The finding this " \
              "exclusion tracks is resolved on the TOOL side — delete the KNOWN_BROKEN entry."
            )
          end
          next
        end

        it "#{verb} at line #{line} passes only parameters the tool declares" do
          unknown = keys - declared.keys
          expect(unknown).to(
            be_empty,
            "#{relative_path}:#{line} calls #{verb} with #{unknown.inspect}, " \
            "which #{verb} does not accept. Declared: #{declared.keys.sort.inspect}"
          )
        end

        # An explicitly elided example (`{ node_id: "...", ... }`) claims nothing
        # about completeness, so no required-parameter example is generated for
        # it. Its unknown-key example above still runs.
        next if elided

        it "#{verb} at line #{line} supplies every required parameter" do
          missing = declared.select { |_, required| required }.keys - keys
          expect(missing).to(
            be_empty,
            "#{relative_path}:#{line} calls #{verb} without required #{missing.inspect}. " \
            "Passed: #{keys.inspect}"
          )
        end
      end
    end
  end

  # Without this, a KNOWN_BROKEN entry can rot silently. Deleting the offending
  # example outright is a legitimate fix for both tracked findings, and it makes
  # extract_calls yield nothing for that verb — so no `it` block is generated,
  # the self-retiring assertion above never runs, and the stale exclusion (plus
  # the finding id it points at) survives forever with nothing to flag it. The
  # per-file "documents at least one MCP call" guard does not catch this: it
  # only fires when EVERY call in the file is gone.
  it "exercises every KNOWN_BROKEN exclusion (none has gone stale)" do
    expected = known_broken.keys.select { |path, _| covered_docs.include?(path) }
    expect(exercised_exclusions.uniq).to(
      match_array(expected),
      "KNOWN_BROKEN entries that matched no call site: "       "#{(expected - exercised_exclusions.uniq).inspect}. The example was probably "       "removed or reworded — delete the entry and its finding reference."
    )
  end
end
