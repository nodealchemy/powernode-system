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
#   * Prose mentions of a verb with no call site, and — for the PARAMETER
#     checks only — docs outside COVERED_DOCS/COVERED_CALLS. Verb EXISTENCE is
#     swept tree-wide and ungated; see the sweep at the bottom of this file for
#     why the two are deliberately asymmetric.

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
    # BATCH 4 — system_set_default_disk_image_publication declares only
    # publication_id; five sites also passed node_platform_id, which the
    # executor never reads (it derives the platform from the publication,
    # system_fleet_tool.rb:5446) and which nothing rejects. disk-image-ci.md
    # keeps one KNOWN_BROKEN recent_events call, below.
    "docs/DISK_IMAGE_MANAGER_AGENT.md",
    "docs/runbooks/disk-image-ci.md",
    # BATCH 3 — no doc edit: its only failure was a `// ...same inputs...`
    # elision, which the required-parameter check now correctly exempts. It is
    # here so the exemption itself has live coverage in this spec.
    "docs/runbooks/expose-service.md",
    # BATCH 1 — the bare `id:` rename family. 24 call sites across 14 files
    # passed a resource id under the key `id` where the verb declares
    # `<resource>_id`; the values were already ids, so it was a pure key
    # rename. Only these two files became fully clean as a result.
    "docs/runbooks/storage-migration.md",
    "docs/tutorials/13-expose-service-tls.md",
    # IMP-d40df31d9cef — the whole GitOps tutorial, every call site. Its
    # troubleshooting section prescribed platform.list_vault_credentials, a verb
    # in NEITHER registry, as the only diagnostic it offered for a failing sync;
    # a tree-wide sweep with this parser confirms it was the sole unlabelled
    # nonexistent verb under docs/. The others are the sensor-config pair in
    # FLEET_SENSORS.md, which the surrounding prose marks "aspirational" — both
    # of which this parser now extracts (see ASPIRATIONAL_VERBS).
    #
    # That gap is now closed at the root: IMP-2a5a9a0fed0a moved verb existence
    # OUT of this per-file allowlist and into the tree-wide sweep at the bottom
    # of this file, so a nonexistent verb reddens wherever it is written and
    # entering COVERED_DOCS is no longer what buys that check.
    "docs/tutorials/10-gitops-fleet.md",
    # IMP-ebc1d180dc10 — two silently-dropped keys, both withdrawn in the doc
    # rather than deleted. system_acquire_pooled_instance declares only
    # pool_name/pool_id/lifecycle_class; :72 also passed acquired_by and
    # acquired_for under a comment promising they were "stamped on the claim
    # record" (acquire! writes exactly pool_state + pool_acquired_at, and
    # there is no claim record other than the instance row). :107 passed
    # pool_id to system_return_pooled_instance, which declares only
    # instance_id. Those were the file's ONLY two failing sites — its other
    # six call sites already passed — so it graduates straight to COVERED_DOCS
    # and gets whole-file coverage rather than a per-verb COVERED_CALLS entry.
    # The withdrawal note added a 9th site: the system_lease_ci_runner call in
    # the Phase 2 blockquote, which the parser matches inside prose and which
    # this file therefore now checks too.
    #
    # Known gap, measured: COVERED_DOCS has no per-verb existence pin, so
    # DELETING the corrected acquire example passes green (346 -> 343 examples,
    # 0 failures) — only the example count moves. COVERED_CALLS' "documents at
    # least one platform.<verb> call" guard would catch that, but it checks
    # only its listed verbs and would drop the other seven sites here. Filed as
    # 01a05631-ce0d-7e7c-aa4c-6833fbc20291 rather than fixed in a docs task.
    "docs/runbooks/instance-pool-tuning.md",
    # IMP-1abe2148b0f3 — 8 failing call sites, 16 examples. Five were
    # mechanical (system_create_node declares name/template_id, not
    # hostname/node_template_id, and no metadata; system_provision_instance's
    # two required provider ids; system_create_template's required
    # node_platform_id; system_sdwan_create_firewall_rule's
    # firewall_action/src_selector/dst_selector/port_from/port_to/name, whose
    # `{ kind: "vip" }` selector is not one of the four
    # Sdwan::FirewallRule::SELECTOR_KINDS either). Three were not: Steps 3-4
    # were built on re-templating a PROVISIONED instance, which no MCP verb
    # does. system_update_node declares node_template_id and writes it, but the
    # only thing that materializes NodeModuleAssignment rows FROM A TEMPLATE'S
    # CLOSURE is System::TemplateApplyService (other services create assignment
    # rows directly — InferenceDeploymentService:114, FlowExporterDeployer:147,
    # ModuleCommitService:493 — none of them from a template). Its callers are
    # ProvisioningService#apply_node_template, FulfillmentAdvanceOrchestrator,
    # the autonomous Fleet::DecisionEngine arm and
    # POST /api/v1/system/nodes/:id/apply_template. Exactly one is MCP-reachable
    # — system_provision_instance, and only while provisioning — so no MCP verb
    # applies a template to an ALREADY-PROVISIONED node, and
    # Runtime::SyncModules reads node.node_module_assignments, not the
    # template. Those two calls are withdrawn in the doc (kept visible with a
    # what-is-actually-true table, per instance-pool-tuning.md) rather than
    # corrected, so the file is fully clean and takes whole-file coverage.
    # The fictional recent_events({ kind_prefix: "system.k3s" }) poll for a
    # cluster.bootstrapped event that nothing emits was replaced by prose
    # naming the real observable — the same treatment that RETIRED the
    # system_drift_report KNOWN_BROKEN entry below, and the reason this file
    # needs no new exclusion.
    "docs/tutorials/05-multi-cluster-k3s.md"
  ].freeze

  # Docs NOT in COVERED_DOCS, pinned one VERB at a time.
  #
  # COVERED_DOCS is all-or-nothing per file: a doc enters only once every call
  # site in it passes. That leaves a corrected call site in an otherwise-unclean
  # file with no coverage at all, so nothing reddens when a later edit
  # reintroduces the exact defect that was just fixed. This list closes that gap
  # without pretending the rest of the file is clean — the listed verbs get the
  # full unknown-key and required-parameter checks, every other call in the file
  # is still unchecked and still owed to IMP-84c318bf31f9's drain.
  #
  # A file must not appear in both lists (asserted below); when it graduates to
  # COVERED_DOCS, delete its entry here.
  COVERED_CALLS = {
    # IMP-17926b4740a8 — the Phase 1 create example passed seven keys
    # (account_id, hostname, node_template_id, node_platform_id,
    # node_architecture_id, lifecycle_class, metadata), NONE of which
    # system_create_node declares, and neither required parameter. The rest of
    # this runbook's call sites (system_get_task({ id: }), list_agents,
    # execute_agent, ...) are the rename family and stay uncovered for now.
    "docs/runbooks/node-provisioning.md" => %w[system_create_node]
  }.freeze

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
    # Same finding, second call site (IMP-84c318bf31f9 batch 4): the
    # troubleshooting table tells an operator to poll
    # system.disk_image_publish_failed through a `kind_prefix` recent_events
    # does not declare.
    ["docs/runbooks/disk-image-ci.md", "recent_events"] => %w[kind_prefix]
    # RETIRED by IMP-e8dc40813adb (this spec's own instruction: the entry
    # matched no call site once the example was removed).
    #
    # Was: 01a05174-e4c3-71c2-b89d-111ef3328576 —
    # ["docs/tutorials/06-rolling-upgrade.md", "system_drift_report"] => %w[template_id]
    #
    # system_drift_report is still per-instance only. What changed first is
    # that 06-rolling-upgrade.md's Verification section no longer MAKES the
    # template-scoped call — rewriting it (its premise, "after all batches
    # complete", was false) replaced the fictional call with prose stating the
    # per-instance limit outright. IMP-0d106a152c47 then closed the other half:
    # system_platform_maintenance({ op: "drift_check" }) was a hardcoded stub
    # and is now wired to NodeInstance#module_drift, so that section documents
    # it as the deployment-scoped answer. Other files may still carry the
    # template_id call shape (docs/runbooks/cve-response.md did).
  }.freeze

  # Call sites exempted from the TREE-WIDE verb-existence sweep below, keyed
  # [relative_path, verb]. Adding a line here is a POLICY CLAIM, not
  # housekeeping: it asserts that this doc names a verb the platform does not
  # implement, on purpose, and that the surrounding prose says so. State the
  # rationale, the way KNOWN_BROKEN and the writer-set ratchets do — an
  # unexplained exemption is indistinguishable from a defect six months on.
  #
  # Self-retiring, like KNOWN_BROKEN: each entry is asserted STILL
  # UNREGISTERED. Implementing the verb reddens its exemption and forces the
  # entry's removal, so the list cannot rot into permanent suppression.
  #
  # The exemption is per VERB, not per file: every OTHER call in an exempted
  # file is still swept. It buys silence for one named fiction, not a blanket
  # pass for the doc that carries it.
  #
  # Not the same register as docs/.verify/ASPIRATIONAL_MCP.md, and deliberately
  # not merged with it. That catalog serves check-mcp-actions.sh, which greps
  # only `system_`/`kubernetes_`/`docker_`-prefixed verbs and SKIPS any line
  # starting `//`, `#` or `>` — so it cannot see a commented-out call at all,
  # and reports "0 unknown" on both of the sites this list exempts.
  #
  # Neither checker contains the other, so do not treat one green as covering
  # the other's ground. This sweep reads bare verbs the script's prefix filter
  # drops (recent_events, execute_agent, list_agents) and does not accept a
  # comment marker as an exemption; the script in turn matches a call the same
  # way wherever it appears, so it is not bounded by this parser's brace
  # balancing. Keep both in step by hand when adding an entry to either — but
  # note that ASPIRATIONAL_MCP.md legitimately stays EMPTY while both entries
  # here are `//`-framed, because the script's comment filter cannot see them.
  # An entry there is owed only for a site the script CAN see, i.e. a live one.
  ASPIRATIONAL_VERBS = {
    # IMP-2a5a9a0fed0a. FLEET_SENSORS.md's "Configuring Sensor Thresholds"
    # section shows a sensor-config read/write pair that no MCP verb provides.
    # Both sites are commented out and carry an inline "aspirational" marker,
    # under a ⚠️ line naming the real path ("edit Fleet::SensorConfig via Rails
    # console or REST today"), and the prose below them says "Until those MCP
    # wrappers ship". So the doc is not wrong about the platform — it is
    # deliberately describing something that does not exist yet, which is the
    # one thing this exemption is for. Being commented out is NOT what exempts
    # it; a call on a `//` line is checked like any other (see extract_calls).
    #
    # These are the ONLY exemptions the tree-wide sweep needs. Measured
    # 2026-08-31 on extensions/system 4d286116: 31 docs under docs/ contain a
    # call this parser can extract, and across every verb they call, exactly
    # two resolve in neither Ai::Tools::PlatformApiToolRegistry::TOOLS nor
    # Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS — and both are
    # this one pair, in this one section.
    [ "docs/FLEET_SENSORS.md", "system_get_sensor_config" ] =>
      "no MCP read verb for Fleet::SensorConfig; the doc says so and names the Rails/REST path",
    # Its write sibling (FLEET_SENSORS.md:527), under the same ⚠️ line and the
    # same "Until those MCP wrappers ship" prose.
    #
    # It was NOT listed here until IMP-f97c629e59d7, and not because anyone
    # judged it differently: the parser could not yield it, so an entry would
    # have failed the staleness guard below. Its argument literal spans several
    # `//` comment lines, and balanced_body used to skip past the closing brace
    # on the LAST of them and drop the call. Fixing that surfaced this site,
    # which is what this entry is. The pair is now symmetric, as the prose
    # always was.
    [ "docs/FLEET_SENSORS.md", "system_update_sensor_config" ] =>
      "no MCP write verb for Fleet::SensorConfig; same section, same ⚠️ line, same Rails/REST path"
  }.freeze
end

RSpec.describe "module docs: MCP worked examples vs. declared tool parameters" do
  ext_root = File.expand_path("../../..", __dir__)
  covered_docs = ModuleDocsMcpCallSignatures::COVERED_DOCS
  covered_calls = ModuleDocsMcpCallSignatures::COVERED_CALLS

  # Extract `platform.<verb>({ ... })` calls, returning
  # [verb, top_level_keys, line_number, elides_arguments?]. Brace/bracket depth
  # aware, string aware, and skips `//`
  # comments INSIDE an argument literal, so a nested `options: { ... }`
  # contributes only `options` and a `// → { ... }` response comment is not
  # mistaken for an argument.
  #
  # A call written on a `//` comment LINE is still extracted and checked,
  # however many lines its argument literal spans — provided the `//` STARTS
  # each line, after whitespace only. A commented-out call framed some other
  # way (blockquoted `> //`, list-indented `- //`, or with a blank line
  # breaking the run) is still dropped; see comment_framed?. That is
  # deliberate: a
  # commented-out example is one an operator copies just the same, so it should
  # be as correct as a live one. It also means commenting a call out does not
  # silence this spec — the `documents at least one MCP call` guard below is
  # what catches a doc edit that drops every call and would otherwise make this
  # whole file pass vacuously.
  #
  # The multi-line half of that claim was FALSE until IMP-f97c629e59d7: a
  # closing brace on a subsequent `//` line was skipped as a comment, so the
  # literal never balanced and the call was dropped. See balanced_body.
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

  # Extract NO-ARGUMENT calls — `platform.<verb>()` — returning [verb, line].
  #
  # Kept separate from extract_calls, which requires an opening `{` because
  # everything it exists to check is a property of the argument literal. A
  # no-arg call has no keys to check and no required parameters to compare
  # against, so it is invisible to the parameter families by construction and
  # correctly so. But it still NAMES A VERB, and a fictional verb is just as
  # uncallable with no arguments as with some — so the tree-wide existence
  # sweep consumes this too. Measured 2026-08-31: 26 such sites across 12 docs,
  # 11 distinct verbs, every one of which resolves today; without this they
  # would be the one shape a "tree-wide" existence claim silently missed.
  #
  # Deliberately NOT folded into extract_calls: doing so would hand the
  # parameter checks a keyless call site in every COVERED_DOCS file, and the
  # required-parameter example would then fail on verbs that legitimately take
  # arguments the doc elided by writing `()`. That is the opt-in drain's
  # problem, not this sweep's.
  def self.extract_noarg_calls(text)
    calls = []
    text.to_enum(:scan, /platform\.([a-z0-9_]+)\(\s*\)/).each do
      verb = Regexp.last_match(1)
      line = text[0...Regexp.last_match.begin(0)].count("\n") + 1
      calls << [ verb, line ]
    end
    calls
  end

  # Given the index of an opening `{`, return the text strictly inside its
  # matching `}`, or nil when the literal never closes (a truncated example).
  #
  # Two passes, because a `//` means two different things (IMP-f97c629e59d7).
  # Inside a LIVE example it introduces a comment, and skipping to end-of-line
  # is right. But when the whole example is COMMENTED OUT, the leading `//` on
  # each line is framing rather than a comment, and skipping past it swallows
  # any closing brace that shares a line with it — the literal then never
  # balances and the call is dropped silently, costing no example anywhere.
  # That was live: FLEET_SENSORS.md's system_update_sensor_config was invisible
  # to every family in this file, including the tree-wide existence sweep.
  #
  # So: scan the text as written first, and only if that fails AND the call is
  # comment-framed, retry against the de-framed region. A live truncated
  # example is unaffected — it fails the first pass and is not framed, so it is
  # still dropped rather than stitched to whatever follows.
  def self.balanced_body(text, open_index)
    body = scan_balanced(text, open_index)
    return body unless body.nil? && comment_framed?(text, open_index)

    scan_balanced(comment_framed_region(text, open_index), 0)
  end

  def self.scan_balanced(text, open_index)
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

  # True when the call's own line is COMMENTED OUT — the line opens with `//`
  # before reaching the `{`. Deliberately anchored at the start of the line: a
  # `//` appearing mid-line (inside a URL string, say) is not framing, and
  # treating it as such would let the retry stitch a live truncated example to
  # unrelated comment lines below it.
  def self.comment_framed?(text, open_index)
    line_start = (text.rindex("\n", open_index) || -1) + 1
    text[line_start...open_index].match?(%r{\A[ \t]*//})
  end

  # The commented-out example, from its opening `{`, with the leading `//`
  # framing stripped from each continuation line.
  #
  # Bounded by the comment RUN: it ends at the first line that is not itself
  # framed, so the retry cannot reach past the block into prose, or into a
  # separate comment block further down, to manufacture a balance.
  #
  # Say what that does NOT buy, because the difference matters: prose written
  # INSIDE the same `//` run is de-framed along with everything else and then
  # parsed as code. A withdrawal note under a commented-out example — this
  # repo's keep-it-visible convention — carrying a stray `}` would close the
  # literal and contribute an English word as a key. Latent, not live: exactly
  # one `//` run in the tree contains a platform call (FLEET_SENSORS.md
  # 525-530) and it is clean. The raw scan must also have failed across the
  # whole rest of the file for it to be reachable at all.
  def self.comment_framed_region(text, open_index)
    line_end = text.index("\n", open_index) || text.length
    region = +text[open_index...line_end]
    (text[(line_end + 1)..] || "").each_line do |line|
      frame = line.match(%r{\A[ \t]*//[ \t]?})
      break if frame.nil?

      region << "\n" << line[frame.end(0)..].to_s.chomp
    end
    region
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
        # The `...` must LEAD the comment. Merely containing one matches an
        # ordinary English ellipsis in a comment that happens to follow a
        # comma ("// waits, then... retries"), which would silently switch the
        # required-parameter check off for that call with no signal. All 15 of
        # the tree's real elisions lead with it ("// ... usual args ...").
        return true if depth.zero? && at_key_position && body[i...line_end].match?(%r{\A//\s*\.\.\.})

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

  # A whole-file target carries no verb filter; a COVERED_CALLS target carries
  # the verbs it pins and ignores every other call in that file.
  targets = covered_docs.map { |path| [ path, nil ] } +
            covered_calls.map { |path, verbs| [ path, verbs ] }

  it "keeps COVERED_CALLS disjoint from COVERED_DOCS" do
    overlap = covered_calls.keys & covered_docs
    expect(overlap).to(
      be_empty,
      "#{overlap.inspect} is in BOTH lists. COVERED_DOCS already checks every call in the " \
      "file, so the COVERED_CALLS entry is redundant — delete it."
    )
  end

  # An empty verb list is truthy, so it would filter every call away AND generate
  # no per-verb guard — the describe block would emit zero examples and report
  # green, which is the exact vacuity this mechanism exists to prevent.
  it "pins at least one verb per COVERED_CALLS entry" do
    empty = covered_calls.select { |_, verbs| verbs.empty? }.keys
    expect(empty).to(
      be_empty,
      "#{empty.inspect} lists no verbs. An empty list checks nothing and passes silently — " \
      "name the verbs, or delete the entry."
    )
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Parser coverage (IMP-f97c629e59d7).
  #
  # Every family in this file consumes extract_calls, so a call the parser
  # DROPS is invisible to all of them AND costs no example — the failure mode
  # is a silent green, which no doc-level assertion can see. These examples pin
  # the drop rules directly, on fixture text rather than on whichever doc
  # happens to carry the shape today, so the guarantee survives a doc edit.
  describe "extract_calls" do
    # The shape that was silently dropped: the whole example is commented out,
    # and the closing brace lands on a LATER `//` line. Skipping to end-of-line
    # at each `//` swallowed that brace, so the literal never balanced.
    framed_multiline = <<~MD
      ```javascript
      // platform.system_update_sensor_config({                                // aspirational
      //   sensor: "instance_status",
      //   silent_threshold_minutes: 10  // default 5
      // })
      ```
    MD

    # Control: a commented-out call that closes on its own line always parsed.
    framed_single_line = <<~MD
      ```javascript
      // platform.system_get_sensor_config({ sensor: "instance_status" })      // aspirational
      ```
    MD

    # Control: a genuinely truncated LIVE example must still be dropped —
    # extracting it would invent keys the doc does not show.
    #
    # truncated_live, truncated_live_then_comment and framed_then_unframed
    # carry no ``` fences on purpose. A backtick opens a string for the
    # scanner, so a fence silently swallows everything after it and would make
    # a be_empty expectation pass for the wrong reason — which is exactly how
    # the first draft of these let two over-reach mutants live. (The two
    # positive fixtures above keep their fences: there the raw scan starts past
    # the opening fence and the closing fence is unframed, so it ends the
    # region before any backtick is read.)
    truncated_live = <<~MD
      platform.system_get_node({ node_id: "<id>",
    MD

    # Control: a LIVE call is never comment-framed, so the retry must not run
    # for it. Without that anchoring, the `}` on the note below would close the
    # literal and the parser would report a call the doc does not make, with a
    # key ("the") invented out of English prose.
    truncated_live_then_comment = <<~MD
      platform.system_get_node({ node_id: "<id>",
      // the rest of this example was trimmed }
    MD

    # Control on the other side: the comment-framed region ends where the
    # comment block ends. Prose breaks the run, so the brace in the LATER,
    # unrelated comment block must not close this literal — the call stays
    # dropped rather than being reported with keys read out of English.
    framed_then_unframed = <<~MD
      // platform.system_get_node({
      //   node_id: "<id>",

      Prose between the two.

      // an unrelated later comment: }
    MD

    # Control: framing is recognised only at the START of the line. A `//`
    # earlier in a LIVE line (inside a URL, here) is not framing, and treating
    # it as such would close this truncated call on the note below it and
    # report `trimmed` — an English word — as a documented parameter.
    live_call_after_a_url = <<~MD
      See http://ops/x — platform.system_get_node({ node_id: "<id>",
      // trimmed }
    MD

    # Control: the region is seeded with the tail of the call's OWN line, so
    # keys that sit beside the opening brace are read like any other. Nothing
    # in the docs tree has this shape today, which is why it needs a fixture.
    framed_key_on_opening_line = <<~MD
      // platform.system_update_sensor_config({ sensor: "instance_status",
      //   silent_threshold_minutes: 10
      // })
    MD

    # extract_calls is a class method on the group, so every fixture is parsed
    # HERE, at group-body scope, and the examples only assert on the results.
    framed_multiline_calls   = extract_calls(framed_multiline)
    framed_single_line_calls = extract_calls(framed_single_line)
    truncated_live_calls     = extract_calls(truncated_live)
    truncated_live_then_comment_calls = extract_calls(truncated_live_then_comment)
    framed_then_unframed_calls = extract_calls(framed_then_unframed)
    live_call_after_a_url_calls = extract_calls(live_call_after_a_url)
    framed_key_on_opening_line_calls = extract_calls(framed_key_on_opening_line)

    it "extracts a commented-out call whose closing brace is on a later // line" do
      expect(framed_multiline_calls.map(&:first)).to(
        eq(%w[system_update_sensor_config]),
        "the call was DROPPED. Nothing else in this file can see that: a dropped call " \
        "generates no example, so the drop reads as a pass everywhere downstream."
      )
    end

    it "reads a comment-framed call's keys through the // framing" do
      expect(framed_multiline_calls.first&.at(1)).to eq(%w[sensor silent_threshold_minutes])
    end

    it "still extracts a commented-out call that closes on its own line" do
      expect(framed_single_line_calls.map { |verb, keys, _, _| [ verb, keys ] }).to(
        eq([ [ "system_get_sensor_config", %w[sensor] ] ])
      )
    end

    it "drops a truncated LIVE call rather than inventing its arguments" do
      expect(truncated_live_calls).to be_empty
    end

    it "does not close a truncated LIVE call on a brace in the comment below it" do
      expect(truncated_live_then_comment_calls).to be_empty
    end

    it "does not stitch a comment-framed call across an unframed line" do
      expect(framed_then_unframed_calls).to be_empty
    end

    it "treats a mid-line // as a comment, not as framing" do
      expect(live_call_after_a_url_calls).to be_empty
    end

    it "reads a key written beside the opening brace of a framed call" do
      expect(framed_key_on_opening_line_calls.first&.at(1)).to(
        eq(%w[sensor silent_threshold_minutes])
      )
    end
  end

  targets.each do |relative_path, only_verbs|
    describe(only_verbs ? "#{relative_path} (#{only_verbs.join(', ')} only)" : relative_path) do
      path = File.join(ext_root, relative_path)
      all_calls = extract_calls(File.read(path))
      calls = only_verbs ? all_calls.select { |verb, _, _, _| only_verbs.include?(verb) } : all_calls

      if only_verbs
        # Per-verb analogue of the whole-file guard below: without it, deleting
        # the pinned example makes this describe block generate no examples at
        # all and pass vacuously, which is exactly how the defect gets back in.
        only_verbs.each do |pinned|
          it "documents at least one platform.#{pinned} call" do
            expect(calls.map(&:first)).to(
              include(pinned),
              "#{relative_path} no longer calls #{pinned}. If the example was removed on " \
              "purpose, drop it from COVERED_CALLS too."
            )
          end
        end
      else
        it "documents at least one MCP call (the parser still matches this file)" do
          expect(calls).not_to be_empty
        end
      end

      calls.each do |verb, keys, line, elided|
        declared = declared_parameters(verb)

        # Verb EXISTENCE is not asserted here. It runs tree-wide and ungated in
        # the sweep at the bottom of this file, which already covers every file
        # in COVERED_DOCS/COVERED_CALLS; repeating it here would only duplicate
        # examples. The parameter checks below still need `declared`, so an
        # unregistered verb drops out of THIS block with no example — the sweep
        # is what reddens for it.
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

  # ─────────────────────────────────────────────────────────────────────────
  # Verb EXISTENCE, tree-wide and UNGATED (IMP-2a5a9a0fed0a).
  #
  # The asymmetry with the parameter checks above is DELIBERATE, not an
  # oversight in one direction or the other:
  #
  #   * The unknown-key and required-parameter checks stay opt-in per file
  #     (COVERED_DOCS) or per verb (COVERED_CALLS), because they are noisy.
  #     Measured 2026-08-31 by pointing covered_docs at every doc with a
  #     parseable call: 1017 examples, 77 failures still open against
  #     IMP-84c318bf31f9's drain. A file enters the allowlist only once it is
  #     genuinely clean, and opting in is that drain's acceptance signal.
  #     Do NOT ungate them in passing.
  #
  #   * Verb existence is a lookup, not a judgement: a verb resolves in
  #     PlatformApiToolRegistry::TOOLS / McpToolRegistrar::INTROSPECTION_TOOLS
  #     or it does not, so there is no backlog to drain before turning it on.
  #     It is also the worst of the three failure modes: a wrong KEY is either
  #     rejected or silently dropped, but a fictional VERB cannot be called at
  #     all, so the doc is not merely imprecise — it is unusable at the moment
  #     an operator is trusting it most. IMP-d40df31d9cef was exactly that
  #     (platform.list_vault_credentials, the only diagnostic 10-gitops-fleet.md
  #     offered for a failing sync), and this check would have caught it years
  #     earlier had it not been gated behind a per-file allowlist it was never
  #     added to.
  #
  #     Not literally false-positive-free, though, and do not sell it as such:
  #     from_tool_registry reads TOOLS[verb] and then requires an
  #     action_definitions entry, so a verb registered only through the generic
  #     register_extension_tools seam, or reachable only as an ACTION_ALIASES
  #     key, would report as unregistered. Neither is live — 0 of the doc
  #     verbs are alias keys and all resolve statically as of 2026-08-31 — but
  #     an exemption granted for that reason would be a lie, so widen the
  #     resolver instead if one ever appears.
  #
  # So this sweep reads the docs tree directly rather than either list, and a
  # doc added tomorrow is covered the day it lands with no opt-in step. It sees
  # both `platform.verb({ ... })` and no-arg `platform.verb()` sites, whether
  # live or commented out and however many lines they span, and descends
  # dot-directories. What it still cannot see is a call whose argument literal
  # never balances even after the comment framing is removed: a genuinely
  # truncated example, or one framed some way other than a line-leading `//`
  # (blockquoted, list-indented, or a run broken by a blank line). Neither has
  # a live instance as of 2026-08-31 — measured over all 31 docs, the new
  # parser drops 0 of the 325 call sites the bare regex finds, against 1 for
  # the old one — and extract_calls' own examples above pin the rules rather
  # than leaving them to this paragraph. "Tree-wide" is a claim about the
  # FILES swept; within a file it is bounded by what extract_calls can parse.
  aspirational_verbs = ModuleDocsMcpCallSignatures::ASPIRATIONAL_VERBS
  exercised_aspirational = []

  # File::FNM_DOTMATCH so DOT-directories are swept too. Without it Dir.glob
  # skips docs/.verify/ silently, which is where the sibling shell checker
  # (check-mcp-actions.sh) and its ASPIRATIONAL_MCP.md catalog live — the one
  # directory whose own docs are most likely to contain example call syntax.
  swept = Dir.glob(File.join(ext_root, "docs", "**", "*.md"), File::FNM_DOTMATCH)
             .sort.filter_map do |absolute|
    relative = absolute.delete_prefix("#{ext_root}/")
    text = File.read(absolute)
    # [verb, line] for both call shapes. The parameter families still see only
    # extract_calls; this pair is what the EXISTENCE check consumes.
    sites = extract_calls(text).map { |verb, _keys, line, _elided| [ verb, line ] } +
            extract_noarg_calls(text)
    [ relative, sites.sort_by(&:last) ] unless sites.empty?
  end

  # Anti-vacuity, as an equality oracle rather than a "> 0" smoke test: a glob
  # that silently stops matching (a docs/ move, a renamed extension root) would
  # leave this sweep enumerating nothing and reporting green, which is the
  # failure mode the whole change exists to remove. Every file the opt-in lists
  # already name must appear here — if one does not, the sweep is not seeing
  # the tree it claims to.
  it "sweeps every doc the opt-in lists already name" do
    unswept = (covered_docs + covered_calls.keys) - swept.map(&:first)
    expect(unswept).to(
      be_empty,
      "#{unswept.inspect} is opted into the parameter checks but was not found by the " \
      "tree-wide sweep. The glob is not seeing the docs tree — fix it before trusting a " \
      "green run here."
    )
  end

  describe "verb existence (tree-wide, ungated by COVERED_DOCS)" do
    swept.each do |relative_path, sites|
      sites.each do |verb, line|
        # Resolved here, at example-GROUP scope: declared_parameters is a class
        # method on this group and is not callable from inside an `it` block.
        declared = declared_parameters(verb)

        if aspirational_verbs.key?([ relative_path, verb ])
          exercised_aspirational << [ relative_path, verb ]

          # Asserted STILL ABSENT, so the exemption retires itself.
          it "#{relative_path}:#{line} #{verb} is still unimplemented, as its exemption claims" do
            expect(declared).to(
              be_nil,
              "platform.#{verb} now resolves in a registry. ASPIRATIONAL_VERBS exempts it " \
              "on the claim that the platform does not implement it — that claim is now " \
              "false. Delete the entry so this call site is checked normally, and check " \
              "whether the surrounding prose still calls it aspirational."
            )
          end
          next
        end

        it "#{relative_path}:#{line} calls a registered MCP verb (#{verb})" do
          expect(declared).not_to(
            be_nil,
            "platform.#{verb} resolves in NEITHER Ai::Tools::PlatformApiToolRegistry::TOOLS " \
            "nor Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS, so an operator " \
            "copying #{relative_path}:#{line} cannot call it at all. Either the verb is " \
            "misspelled, or the doc describes a capability the platform does not have — in " \
            "which case say so in the prose and add it to ASPIRATIONAL_VERBS with a reason."
          )
        end
      end
    end
  end

  # Same staleness guard the KNOWN_BROKEN list gets below, and for the same
  # reason: deleting the exempted example leaves the entry matching no call
  # site, so its self-retiring assertion never runs and the exemption survives
  # forever with nothing to flag it.
  it "exercises every ASPIRATIONAL_VERBS exemption (none has gone stale)" do
    expect(exercised_aspirational.uniq).to(
      match_array(aspirational_verbs.keys),
      "ASPIRATIONAL_VERBS entries that matched no call site: " \
      "#{(aspirational_verbs.keys - exercised_aspirational.uniq).inspect}. The example was " \
      "probably removed or reworded — delete the entry."
    )
  end

  # Without this, a KNOWN_BROKEN entry can rot silently. Deleting the offending
  # example outright is a legitimate fix for both tracked findings, and it makes
  # extract_calls yield nothing for that verb — so no `it` block is generated,
  # the self-retiring assertion above never runs, and the stale exclusion (plus
  # the finding id it points at) survives forever with nothing to flag it. The
  # per-file "documents at least one MCP call" guard does not catch this: it
  # only fires when EVERY call in the file is gone.
  it "exercises every KNOWN_BROKEN exclusion (none has gone stale)" do
    expected = known_broken.keys.select do |path, verb|
      covered_docs.include?(path) || covered_calls[path]&.include?(verb)
    end
    expect(exercised_exclusions.uniq).to(
      match_array(expected),
      "KNOWN_BROKEN entries that matched no call site: "       "#{(expected - exercised_exclusions.uniq).inspect}. The example was probably "       "removed or reworded — delete the entry and its finding reference."
    )
  end
end
