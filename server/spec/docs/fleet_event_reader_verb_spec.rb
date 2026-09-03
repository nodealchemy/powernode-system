# frozen_string_literal: true

require "rails_helper"

# IMP-72df91c7b9db — the fleet event reader is system_recent_signals, and no
# doc in this extension may send an operator to platform.recent_events for a
# FleetEvent.
#
# Seventeen docs prescribed `platform.recent_events(...)` as the way to watch a
# `System::FleetEvent` stream (honeypot, federation, disk-image, k3s, docker,
# pool and CVE kinds). The verb EXISTS — it is an introspection tool declared
# in Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS — which is
# exactly why the tree-wide verb-existence sweep in
# module_docs_mcp_call_signatures_spec.rb never reddened on it. But it reads
# Ai::ExecutionEvent (agent execution events: source_type / status / limit)
# and never returns a FleetEvent, so every one of those diagnostic steps was
# dead: an empty list with `success: true`, and no sign that the wrong table
# had been asked. The FleetEvent reader is `system_recent_signals`
# (Ai::Tools::SystemFleetTool), which filters by EXACT `kind` or by
# `correlation_id` — there is no prefix filter, no `source` filter and no
# `since`; the docs' `kind_prefix:` / `source:` / `since:` arguments were
# written for a verb that never had them.
#
# Three pins, each against the bytes on disk, so a keep-it-visible withdrawal
# ("not `recent_events`, which reads ...") cannot satisfy an absence check by
# accident and a moved docs/ tree cannot satisfy it vacuously:
#
#   1. CONTAINMENT — no doc under docs/ names `platform.recent_events` unless
#      EXECUTION_FEED_DOCS lists it with a rationale (empty today: nothing in
#      this extension documents the agent-execution feed).
#   2. CONTRAST — every paragraph that still names bare `recent_events` (a
#      withdrawal note, a corrections table) also names the real reader, so
#      the mention points an operator somewhere that works.
#   3. SIGNATURE — every `platform.system_recent_signals({ ... })` call site
#      tree-wide passes only keys the verb DECLARES, resolved from the live
#      action definition rather than spelled here. This is the check the
#      opt-in parameter families in module_docs_mcp_call_signatures_spec.rb
#      run only for COVERED_DOCS / COVERED_CALLS files; for this one verb it
#      is ungated, because reintroducing `kind_prefix:` on the real verb is
#      the exact regression this task closed.
#
#   4. KIND EXISTENCE — the `kind:` every call site passes is one the
#      extension actually emits. Checks 1-3 are about the VERB; this one is
#      about the argument, and without it the verb correction just relocates
#      the dead diagnostic: `system_recent_signals` answers an unemitted kind
#      with the same empty list and `success: true` that `recent_events`
#      returned. Found by review on this task's own diff — a rewritten
#      honeypot step counted `payload.node_instance_id` on
#      `system.honeypot_triggered`, a kind whose producer sets no instance
#      ref, so the escalation rule could never fire.
#
# Plus a PRESENCE floor: each file this task corrected must still name the
# reader. Deleting the corrected step outright would otherwise pass 1-3 while
# leaving the operator with no diagnostic at all.
module FleetEventReaderVerb
  FLEET_READER = "system_recent_signals"

  # [relative doc path] => why this doc legitimately means Ai::ExecutionEvent.
  # An entry here is a policy claim that the doc is about AGENT executions,
  # not fleet events; state the rationale.
  EXECUTION_FEED_DOCS = {}.freeze

  # Files IMP-72df91c7b9db corrected. A floor, not an equality — a new doc may
  # name the reader without being listed here.
  CORRECTED_DOCS = %w[
    docs/CONTAINER_RUNTIMES.md
    docs/DISK_IMAGE_MANAGER_AGENT.md
    docs/SDWAN_MANAGER_AGENT.md
    docs/runbooks/acme-issuance.md
    docs/runbooks/cve-response.md
    docs/runbooks/disk-image-ci.md
    docs/runbooks/federation-troubleshooting.md
    docs/runbooks/instance-pool-tuning.md
    docs/runbooks/node-provisioning.md
    docs/runbooks/sdwan-network-setup.md
    docs/tutorials/03-docker-runtime.md
    docs/tutorials/04-k3s-cluster.md
    docs/tutorials/05-multi-cluster-k3s.md
    docs/tutorials/06-rolling-upgrade.md
    docs/tutorials/07-cve-response.md
    docs/tutorials/09-honeypot-canary.md
    docs/tutorials/11-federation.md
    docs/tutorials/12-disk-image-ci.md
  ].freeze

  # Top-level keys of every `platform.system_recent_signals({ ... })` literal
  # in `text`, as [[line, [keys]], ...]. The verb's arguments are flat scalars,
  # so a non-nesting scan is sufficient; a nested literal would be a new
  # parameter shape and should red here as an unknown key rather than parse.
  def self.reader_call_keys(text)
    text.to_enum(:scan, /platform\.#{FLEET_READER}\(\s*\{([^{}]*)\}/m).map do
      body = Regexp.last_match(1)
      line = text[0...Regexp.last_match.begin(0)].count("\n") + 1
      keys = body.scan(/(?:\A|[,\n])\s*(?:\/\/[^\n]*\n\s*)*([a-z_][a-z0-9_]*)\s*:/).flatten
      [ line, keys ]
    end
  end

  # Paragraphs: runs of non-blank lines. A markdown table is one paragraph,
  # which is what makes a corrections-table row satisfy the contrast rule
  # within its own block.
  def self.paragraphs(text)
    text.split(/\n[ \t]*\n/)
  end

  # Kinds a producer builds by STRING COMPOSITION, so no literal exists to find.
  # An entry is a claim that the kind is really emitted; cite the producer.
  COMPOSED_KINDS = {
    "federation.peer.accepted" =>
      "TWO producers, both interpolating. System::Federation::" \
      "FederationAcceptanceService#emit_event! builds kind: " \
      "\"federation.peer.#{'#{action}'}\" (:512) and is called with action: \"accepted\" " \
      "(:170); System::FederationPeer#broadcast_status_transition! reaches the same " \
      "name through broadcast_peer_state!(kind: status) for the \"accepted\" member of " \
      "STATUSES (federation_peer.rb:32,:374,:400).",
    "federation.peer.degraded" =>
      "System::FederationPeer#broadcast_status_transition! is an after_update hook on " \
      "any status change; it emits kind: \"federation.peer.#{'#{kind}'}\" with kind = " \
      "status (federation_peer.rb:400), and \"degraded\" is both a STATUSES member " \
      "(:32) and a named severity branch in that hook (:368)."
  }.freeze

  # Every event kind the extension's server source EMITS, as literals.
  #
  # Derived rather than listed: a hand-kept list is a second place for the
  # truth to rot, and the defect this spec guards is docs naming a kind that
  # matches nothing. Two shapes are read — a `kind:` argument and a
  # `*_KIND*` constant — and QUERY call sites are excluded, because
  # `.where(kind: "system.honeypot_triggered")` is a READ of the log and
  # counting it would let a doc cite a kind only ever queried, never written.
  QUERY_CALLERS = /\A(where|find_by|exists|pluck|count|select|order|by_kind)\z/
  KIND_LITERAL = /"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/

  def self.emitted_kinds(ext_root)
    files = Dir[File.join(ext_root, "server", "app", "**", "*.rb")]
    raise "no extension server source found — the oracle would be vacuous" if files.empty?

    kinds = files.flat_map do |path|
      src = File.read(path)
      found = src.scan(/^\s*[A-Z][A-Z0-9_]*KIND[A-Z0-9_]*\s*=\s*#{KIND_LITERAL}/).flatten
      src.to_enum(:scan, /\bkind:\s*#{KIND_LITERAL}/).each do
        match = Regexp.last_match
        caller_name = src[[ match.begin(0) - 400, 0 ].max...match.begin(0)].scan(/\b([a-z_]+)\(/).last&.first
        next if caller_name&.match?(QUERY_CALLERS)

        found << match[1]
      end
      found
    end.uniq.sort

    # Non-vacuity floor: a parser that stops matching must red here rather
    # than declare every documented kind unknown (or, worse, go green because
    # nothing is left to check).
    raise "parsed only #{kinds.size} emitted kinds — the parser has stopped matching" if kinds.size < 40

    kinds
  end

  # The `kind:` literal at every `platform.system_recent_signals({ ... })` site.
  def self.reader_call_kinds(text)
    text.to_enum(:scan, /platform\.#{FLEET_READER}\(\s*\{([^{}]*)\}/m).flat_map do
      body = Regexp.last_match(1)
      line = text[0...Regexp.last_match.begin(0)].count("\n") + 1
      body.scan(/kind:\s*"([^"]+)"/).flatten.map { |kind| [ line, kind ] }
    end
  end
end

RSpec.describe "system docs: the fleet event reader is system_recent_signals" do
  ext_root = File.expand_path("../../..", __dir__)
  swept = Dir.glob(File.join(ext_root, "docs", "**", "*.md"), File::FNM_DOTMATCH).sort.map do |absolute|
    [ absolute.delete_prefix("#{ext_root}/"), File.read(absolute) ]
  end

  emitted_kinds = FleetEventReaderVerb.emitted_kinds(ext_root)

  declared_keys = Ai::Tools::SystemFleetTool.action_definitions
                                            .fetch(FleetEventReaderVerb::FLEET_READER)
                                            .fetch(:parameters).keys.map(&:to_s)

  it "resolves the reader's declared parameters from its live definition" do
    expect(declared_keys).not_to be_empty
  end

  it "keeps COMPOSED_KINDS entries pointing at kinds no literal scan can find" do
    redundant = FleetEventReaderVerb::COMPOSED_KINDS.keys & emitted_kinds
    expect(redundant).to(
      be_empty,
      "#{redundant.inspect} is now a literal in server/app — drop the COMPOSED_KINDS entry " \
      "rather than leave an exemption that no longer exempts anything."
    )
  end

  # Anti-vacuity: the glob must see the files this task corrected, or every
  # absence below is a statement about nothing.
  it "sweeps every corrected doc" do
    missing = FleetEventReaderVerb::CORRECTED_DOCS - swept.map(&:first)
    expect(missing).to be_empty, "not found by the docs glob: #{missing.inspect}"
  end

  it "keeps EXECUTION_FEED_DOCS entries pointing at docs that exist" do
    stale = FleetEventReaderVerb::EXECUTION_FEED_DOCS.keys - swept.map(&:first)
    expect(stale).to be_empty, "EXECUTION_FEED_DOCS names docs that are gone: #{stale.inspect}"
  end

  swept.each do |relative_path, text|
    corrected = FleetEventReaderVerb::CORRECTED_DOCS.include?(relative_path)
    allowed_execution_feed = FleetEventReaderVerb::EXECUTION_FEED_DOCS.key?(relative_path)
    prefixed_lines = text.lines.each_with_index.filter_map do |line, i|
      i + 1 if line.include?("platform.recent_events")
    end
    contrast_failures = FleetEventReaderVerb.paragraphs(text).select do |para|
      para.match?(/(?<![a-z_])recent_events\b/) && !para.include?(FleetEventReaderVerb::FLEET_READER)
    end
    reader_calls = FleetEventReaderVerb.reader_call_keys(text)
    reader_kinds = FleetEventReaderVerb.reader_call_kinds(text)

    next if prefixed_lines.empty? && contrast_failures.empty? && reader_calls.empty? && !corrected

    describe relative_path do
      unless allowed_execution_feed
        it "does not prescribe platform.recent_events (it reads Ai::ExecutionEvent, never a FleetEvent)" do
          expect(prefixed_lines).to(
            be_empty,
            "#{relative_path}:#{prefixed_lines.join(',')} names platform.recent_events. That verb " \
            "returns agent execution events (source_type/status/limit) and can never return the " \
            "FleetEvent kinds this extension emits; the fleet reader is " \
            "platform.#{FleetEventReaderVerb::FLEET_READER} (exact `kind` or `correlation_id`). " \
            "If this doc genuinely means the agent-execution feed, list it in " \
            "EXECUTION_FEED_DOCS with a rationale."
          )
        end
      end

      it "names #{FleetEventReaderVerb::FLEET_READER} in every paragraph that still mentions recent_events" do
        expect(contrast_failures).to(
          be_empty,
          "#{relative_path} mentions `recent_events` without naming the fleet reader in the " \
          "same paragraph:\n#{contrast_failures.map { |p| p.strip[0, 160] }.inspect}\n" \
          "A withdrawal note must point at #{FleetEventReaderVerb::FLEET_READER}, or an " \
          "operator is left with the dead verb and no replacement."
        )
      end

      reader_calls.each do |line, keys|
        it ":#{line} passes only parameters #{FleetEventReaderVerb::FLEET_READER} declares (#{keys.join(', ')})" do
          unknown = keys - declared_keys
          expect(unknown).to(
            be_empty,
            "#{relative_path}:#{line} passes #{unknown.inspect} to " \
            "platform.#{FleetEventReaderVerb::FLEET_READER}, which declares only " \
            "#{declared_keys.inspect}. BaseTool#validate_params! never rejects an extra key, so " \
            "the filter is silently dropped and the call returns the unfiltered feed. There is " \
            "no prefix, source or time filter on this verb — pass an exact `kind` or a " \
            "`correlation_id`."
          )
        end
      end

      reader_kinds.each do |line, kind|
        it ":#{line} filters on a kind the extension emits (#{kind})" do
          composed = FleetEventReaderVerb::COMPOSED_KINDS[kind]
          expect(composed.present? || emitted_kinds.include?(kind)).to(
            be(true),
            "#{relative_path}:#{line} polls platform.#{FleetEventReaderVerb::FLEET_READER} for " \
            "kind #{kind.inspect}, which no producer under server/app writes. " \
            "System::FleetEvent.by_kind is an exact `where(kind:)`, so the call returns an " \
            "empty list with `success: true` — the same dead-diagnostic shape this task " \
            "removed, just on the right verb. Point the step at an emitted kind, or add the " \
            "kind to COMPOSED_KINDS with the producer that builds it by interpolation."
          )
        end
      end

      if corrected
        it "still names #{FleetEventReaderVerb::FLEET_READER} (presence floor for a corrected doc)" do
          expect(text).to(
            include(FleetEventReaderVerb::FLEET_READER),
            "#{relative_path} was corrected by IMP-72df91c7b9db to point at " \
            "#{FleetEventReaderVerb::FLEET_READER} and no longer names it. If the diagnostic " \
            "step was withdrawn on purpose, remove the file from CORRECTED_DOCS in the same " \
            "commit and say in the doc what the operator should read instead."
          )
        end
      end
    end
  end
end
