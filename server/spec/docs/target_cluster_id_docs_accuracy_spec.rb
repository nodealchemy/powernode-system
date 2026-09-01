# frozen_string_literal: true

require "spec_helper"
require "rack/utils"

# IMP-c43c4829fe11 — three documents told an operator that `target_cluster_id`
# is a working knob with a forgiving fallback. It is neither.
#
# The field is wired on the PLATFORM side and unreachable from the AGENT:
#
#   * The server reads it — `runtime_handshake_handlers.rb` passes
#     `params[:target_cluster_id].presence` into `join_request!`, so a value
#     that arrived would be honoured.
#   * Nothing on the agent produces one. `k3sd.AgentManager.TargetClusterID` is
#     declared (agent_manager.go) and consumed (`JoinRequest(ctx,
#     m.TargetClusterID)`), but NEVER ASSIGNED: `NewAgentManager` takes five
#     arguments, none of them a cluster, and its struct literal does not set the
#     field. `k3sd.ModulesAPI` is `AssignedModules(ctx) ([]string, error)` —
#     module NAMES only — so assignment config never reaches the K3s
#     reconcilers at all.
#   * So the worker's join always carries an empty target, and with more than
#     one active cluster `resolve_membership_cluster!` raises
#     `AmbiguousClusterError` and emits `system.k3s_ambiguous_cluster_join_refused`
#     at severity `high`. It REFUSES. It does not auto-select, and it produces
#     no misplaced node — it produces no node.
#
# The declared-and-consumed-but-never-written shape is why a reference count is
# useless here: `TargetClusterID` has six hits in the agent tree and works in
# none of them. The CODE half below pins the missing WRITE positively — it
# enumerates what `NewAgentManager` actually sets, rather than asserting an
# absence a rename would satisfy.
#
# This guard has two halves and needs both:
#
#   1. The CODE half pins the premise. If someone implements the producer
#     (IMP-a5f236e8cc56 gap 3), these examples redden and the withdrawal notices
#     corrected here are exactly the ones to restore.
#   2. The DOC half is a matched PAIR per file — the false promise ABSENT and a
#     truthful replacement PRESENT. Absence alone is vacuous: deleting the
#     section outright would satisfy it, and leave an operator with a
#     multi-cluster account and no warning that their workers cannot join.
#
# The CODE half needs its CONTRAST or "no producer" is untethered from "broken":
# the SERVER half is pinned as working. That is the difference between "wired on
# one side only" and "unimplemented", and it is the difference the docs now
# state.
#
# WHY THIS FILE AND NOT THE SIGNATURE ENUMERATOR:
# docs/runbooks/multi-cluster-k3s.md is already listed in
# module_docs_mcp_call_signatures_spec.rb COVERED_DOCS and still carried this
# fabrication for its whole life. That enumerator parses TOP-LEVEL keys of
# `platform.<verb>({ ... })` calls; `target_cluster_id` is nested inside
# `config:`, so it is structurally invisible there. Extending that parser to
# nested values is real work with its own blast radius across 31 docs and is
# NOT done here — see the report on IMP-c43c4829fe11. This is a token-level
# regression pin on the known statements instead.
#
# db/seeds/system_kb_seed.rb is not reachable by that enumerator at ALL (it is
# Ruby, not Markdown, and contains no `platform.<verb>` call). It is covered
# here as TEXT, which is the only mechanism that would catch the claim
# regressing in a seed.
#
# IMP-f249d9d1af47 extended this guard to the remaining documents. The sweep
# that found them was built from the CLAIM, not the phrase: each of the five
# documents stated one falsehood in different words, and a phrase sweep for
# "most recent active" finds three of them and misses the rest.
#
#   * docs/tutorials/04-k3s-cluster.md — "the agent picks the first cluster it
#     finds", plus a Troubleshooting row promising a 404. The handlers map
#     AmbiguousClusterError to 409 and NoClusterAvailableError to 422
#     (runtime_handshake_handlers.rb:167-170); nothing there returns 404, so an
#     operator debugging by status code was looking for the wrong response
#     entirely. Both codes are pinned below.
#   * docs/CONTAINER_RUNTIMES.md — "the agent silently joins the
#     most-recently-created", and a stale "Known gap (2026-06-03)" claiming the
#     server-side ambiguity guard had not shipped. It had; the omitted-ID case
#     is the guarded one.
#   * docs/USE_CASE_MATRIX.md — "auto-select most recent active cluster (legacy
#     single-cluster contract preserved)", with use case 3 marked "Works".
#   * docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md — a SIXTH wording the filed task
#     did not name: the k3s-server example "joins clusters by target_cluster_id
#     metadata" (k3s-server has no join path at all), and a claim that the field
#     "lives on the NodeInstance.metadata JSONB". Nothing reads it from there,
#     or from assignment config; the only source consumed is the handshake
#     request parameter.
#   * docs/SMOKE_TEST.md carries a different defect in kind, not this
#     fabrication: db/seeds/smoke_test_k3s_agent_join.rb:90 really does pass
#     target_cluster_id — at the SERVICE layer, bypassing the agent — so a green
#     run evidences the wired platform half only. Pinned as a scope clarifier.
#
# GUARD SHAPE for a keep-it-visible withdrawal: absence is unusable, because the
# false text is deliberately retained. Every live claim needs CONTAINMENT (it
# appears only inside that file's marked withdrawal region, as a two-cell row)
# PLUS PRESENCE (it is still carried, so deleting the table fails too), and the
# truthful replacement must be present. Exemptions are scoped to the REGION,
# never document-wide — a false claim parked in a Troubleshooting section would
# otherwise be silently exempt. Every pattern below matches at least once today;
# a pattern that matches nothing is an absence assertion wearing a containment
# costume, which is how three of the previous iteration's eight patterns came to
# be vacuous.
#
# It is a regression pin on known statements, not a semantic check.
RSpec.describe "target_cluster_id docs vs. what the agent actually sends" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # Whitespace-normalised view, for TRUTH assertions only. The corrected prose
  # is hard-wrapped, so a byte-exact match would redden on a reflow that changed
  # nothing an operator reads.
  #
  # The per-line blockquote marker is stripped first, and that is load-bearing,
  # not tidiness: several of these corrections live inside `>` callouts, so
  # collapsing whitespace alone leaves a stray ">" in the middle of every
  # sentence that wraps — a truth pattern spanning the wrap then matches
  # nothing and the assertion silently becomes a check on the wrap point. That
  # is the same shape as the regex-across-a-wrapped-line that made the previous
  # iteration's baseline red without anyone noticing. Containment checks are
  # line-based and do NOT use this, so nothing here can exempt a false claim.
  def self.squish(text)
    text.lines.map { |line| line.sub(/\A\s*>\s?/, "") }.join(" ").gsub(/\s+/, " ")
  end

  # PRESENCE, reported compactly. A bare `expect(doc).to match(...)` on a whole
  # document dumps the entire file into the failure output and buries the
  # reason; the previous iteration's failures were unreadable for exactly that.
  # Returns the patterns that are absent, so a failure names them and nothing
  # else. Matching is done on the squished text, so a reflow that changed
  # nothing an operator reads cannot redden it.
  def self.absent(text, patterns)
    squished = squish(text)
    patterns.reject { |pattern| squished.match?(pattern) }.map(&:inspect)
  end

  # ABSENCE, reported compactly and by line, for wording that was rewritten
  # outright rather than withdrawn (so it has no row to live in). Same reason
  # as `absent`: a bare `not_to match` on a whole document prints the document.
  def self.present_sites(doc, patterns)
    doc.lines.each_with_index.flat_map do |line, i|
      patterns.select { |pattern| line.match?(pattern) }
              .map { |pattern| "#{i + 1}: #{pattern.inspect} :: #{line.strip[0, 80]}" }
    end
  end

  # CONTAINMENT. A withdrawn claim may appear only inside `region` — this
  # file's marked withdrawal block, never the whole document — and only as a
  # two-cell table row whose first cell opens with a quote or a backtick.
  # `row_prefix` carries the blockquote marker where the table is nested in one.
  # Returns the offending "line-number: text" sites, so a failure names them.
  #
  # The exemption is keyed to the region's LINE RANGE, not to whether the region
  # text happens to contain the line. A review caught the content-keyed version:
  # `region.include?(line)` is a substring test, so a byte-identical copy of a
  # withdrawal row pasted anywhere in the document — the realistic markdown
  # copy-paste regression — was silently exempt, in exactly the Troubleshooting
  # section this helper's comment claimed to have closed off.
  def self.claims_outside_withdrawal(doc, region, pattern, row_prefix: "")
    raise "withdrawal region not found — the containment check would be vacuous" if region.to_s.strip.empty?

    start_char = doc.index(region)
    raise "withdrawal region is not a slice of this document" if start_char.nil?

    first_line = doc[0...start_char].count("\n")
    last_line = first_line + region.count("\n")

    # Exactly two cells: three pipes, neither cell containing one. The looser
    # `.+ \| .+` this replaced admitted a three-cell row, so the "two cells"
    # the comment pins was not in fact pinned.
    row_shape = /\A#{Regexp.escape(row_prefix)}\| ["`][^|]*\| [^|]*\|\s*\z/
    doc.lines.each_with_index.filter_map do |line, i|
      next unless line.match?(pattern)
      next if i.between?(first_line, last_line) && line.match?(row_shape)

      "#{i + 1}: #{line.strip[0, 100]}"
    end
  end

  REFUSAL_EVENT = "system.k3s_ambiguous_cluster_join_refused"

  # Every mention of the refusal event that states a severity at all must say
  # `high`. A doc-wide `to match(/severity `high`/)` is satisfied by any single
  # site and cannot see one mention drifting to "medium" or "warning" — an
  # operator filtering their event stream on the wrong severity is exactly the
  # mis-diagnosis these pages exist to stop.
  #
  # WINDOWED over the squished text, not line-based. The prose is hard-wrapped,
  # so the event name and its severity routinely land on different lines: a
  # line-based version of this check let a `high` -> `medium` mutant through in
  # USE_CASE_MATRIX.md, because that site's event name is on the line above its
  # severity and the OTHER mention kept the presence assertion green.
  # Windows are CLAMPED so one mention cannot borrow the next mention's
  # severity: two events within ~90 squished characters would otherwise let the
  # first window absorb the second's `high` and mask a drift in the first.
  def self.severity_windows(text)
    squished = squish(text)
    starts = []
    offset = 0
    while (i = squished.index(REFUSAL_EVENT, offset))
      starts << i
      offset = i + REFUSAL_EVENT.length
    end

    starts.each_with_index.map do |i, n|
      lo = [i - 60, n.zero? ? 0 : starts[n - 1] + REFUSAL_EVENT.length, 0].max
      hi = [i + REFUSAL_EVENT.length + 90, starts[n + 1] || squished.length].min
      squished[lo...hi]
    end
  end

  def self.severity_stating_windows(text)
    severity_windows(text).select { |w| w.match?(/severity/i) }
  end

  def self.softened_severity_sites(text)
    severity_stating_windows(text).reject { |w| w.match?(/severity `high`/) }
  end

  # The set of cluster statuses that count toward the ambiguity, cross-checked
  # against the model rather than spell-checked. Five documents now state this
  # sentence; a per-document copy is how `provisioning` — a NodeInstance status,
  # not a KubernetesCluster one — survived in tutorial 05 while the runbook's
  # own guard sat one directory away. Phrasing-independent: it anchors on the
  # scope expression and reads whatever backticked tokens the sentence names.
  def self.ambiguity_sentence(text)
    squish(text)[/`where\.not\(status: "error"\)`.{0,400}?counts toward the ambiguity[^.]*\./]
  end

  def self.cluster_statuses
    model = File.read(File.expand_path("../../../../../server/app/models/devops/kubernetes_cluster.rb", __dir__))
    model[/STATUSES\s*=\s*%w\[([^\]]+)\]/, 1].split
  end

  RSpec.shared_examples "an ambiguity-status sentence" do
    it "names only cluster statuses the model defines, and every one that counts" do
      statuses = self.class.cluster_statuses
      sentence = self.class.ambiguity_sentence(doc)
      expect(sentence).not_to be_nil, "no ambiguity-scope sentence found to check"

      named = sentence.scan(/`(\w+)`/).flatten.uniq
      expect(named - statuses).to be_empty
      expect((statuses - %w[error active]) - named).to be_empty
    end
  end

  # --- code: the premise the docs must be written to ----------------------

  describe "k3sd.AgentManager (the agent half — no producer)" do
    let(:agent_manager) { self.class.read(ext_root, "agent/internal/k3sd/agent_manager.go") }

    it "declares TargetClusterID and consumes it in the join request" do
      expect(agent_manager).to match(/^\tTargetClusterID string$/)
      expect(agent_manager).to match(/m\.Client\.JoinRequest\(ctx, m\.TargetClusterID\)/)
    end

    # POSITIVE enumeration, not an absence assertion: list what the constructor
    # actually sets. A rename of the field would not silently satisfy this.
    it "NewAgentManager sets six fields and TargetClusterID is not one of them" do
      literal = agent_manager[/m := &AgentManager\{(.*?)\n\t\}/m, 1]
      expect(literal).not_to be_nil, "expected a &AgentManager{...} literal in NewAgentManager"

      keys = literal.scan(/^\t\t(\w+):/).flatten
      expect(keys).to contain_exactly(
        "Client", "Modules", "Applier", "NodeID", "StatePath", "OnError"
      )
    end

    # Semantic, not byte-exact: the invariant is "no argument is a cluster",
    # so renaming nodeID or rewrapping the signature must not redden a
    # doc-accuracy spec.
    it "NewAgentManager's signature carries no cluster argument" do
      signature = agent_manager[/func NewAgentManager\((.*?)\) \*AgentManager/m, 1]
      expect(signature).not_to be_nil

      expect(signature).not_to match(/cluster/i)

      # Split on commas at paren-depth 0 — a naive split shears
      # `func(string, error)` in half.
      params = []
      depth = 0
      buf = +""
      signature.each_char do |ch|
        case ch
        when "(" then depth += 1; buf << ch
        when ")" then depth -= 1; buf << ch
        when "," then depth.zero? ? (params << buf; buf = +"") : buf << ch
        else buf << ch
        end
      end
      params << buf

      expect(params.map(&:strip)).to contain_exactly(
        a_string_matching(/\*Client\z/),
        a_string_matching(/ModulesAPI\z/),
        a_string_matching(/AgentApplier\z/),
        a_string_matching(/\Anode\w* string\z/i),
        a_string_matching(/\Aon\w* func\(string, error\)\z/i)
      )
    end
  end

  describe "the agent tree as a whole" do
    let(:go_sources) do
      Dir[File.join(ext_root, "agent", "**", "*.go")].sort.to_h do |path|
        [path.sub("#{ext_root}/", ""), File.read(path)]
      end
    end

    # The one place anything is ever written INTO a TargetClusterID is the
    # outbound handshake struct, from JoinRequest's own parameter — which the
    # sole production caller supplies as the never-written field above. So the
    # value on the wire is always "".
    # Keyed by file and CONTENT rather than line number: an unrelated insertion
    # higher up a Go file must not redden a docs guard with a message that says
    # nothing about the invariant.
    it "has exactly one TargetClusterID write site, and it is the outbound payload" do
      writes = go_sources.flat_map do |rel, src|
        src.lines.filter_map do |line|
          next unless line.match?(/TargetClusterID\s*(:|=)\s*\S/)

          "#{rel}: #{line.strip}"
        end
      end

      expect(writes).to eq(["agent/internal/k3sd/handshake.go: TargetClusterID: targetClusterID,"])
    end

    it "has exactly one production caller of JoinRequest, passing the unwritten field" do
      callers = go_sources.reject { |rel, _| rel.end_with?("_test.go") }.flat_map do |rel, src|
        src.lines.filter_map do |line|
          next unless line.match?(/\.JoinRequest\(ctx/)

          "#{rel}: #{line.strip}"
        end
      end

      expect(callers).to eq(
        ["agent/internal/k3sd/agent_manager.go: payload, err := m.Client.JoinRequest(ctx, m.TargetClusterID)"]
      )
    end

    it "ModulesAPI hands the K3s reconcilers module NAMES only — no config channel" do
      applier = self.class.read(ext_root, "agent/internal/k3sd/applier.go")
      body = applier[/type ModulesAPI interface \{(.*?)\}/m, 1]

      expect(body.strip).to eq("AssignedModules(ctx context.Context) ([]string, error)")
    end

    it "the k3s-server reconciler has no join path at all" do
      server_manager = self.class.read(ext_root, "agent/internal/k3sd/server_manager.go")

      expect(server_manager).not_to match(/JoinRequest/)
      expect(server_manager).not_to match(/TargetClusterID/)
      # It bootstraps and reports ready against its OWN bootstrapped cluster.
      expect(server_manager).to match(/m\.Client\.Bootstrap\(ctx/)
      expect(server_manager).to match(/RuntimeK3sServer, RoleServer, version, m\.state\.bootstrappedFor/)
    end
  end

  # --- the CONTRAST: the platform half IS wired -----------------------------

  describe "the platform half (the discriminator)" do
    it "the handshake handler forwards a supplied target_cluster_id to join_request!" do
      handlers = self.class.read(
        ext_root, "server/app/controllers/concerns/system/runtime_handshake_handlers.rb"
      )

      expect(handlers).to match(/target_cluster_id: params\[:target_cluster_id\]\.presence/)
      expect(handlers).to match(/rescue ::System::KubernetesClusterProvisionerService::AmbiguousClusterError/)
    end

    it "the provisioner refuses an ambiguous join and emits a HIGH event" do
      service = self.class.read(
        ext_root, "server/app/services/system/kubernetes_cluster_provisioner_service.rb"
      )

      expect(service).to match(/class AmbiguousClusterError < ProvisionError/)
      expect(service).to match(/kind: "system\.k3s_ambiguous_cluster_join_refused"/)
      expect(service).to match(/severity: :high/)
    end

    # The docs corrected here tell an operator to debug by HTTP status. A
    # tutorial previously promised a 404 for a bad target, which is a different
    # failure from the auto-select fabrication and would survive correcting only
    # the fallback prose. Pin the mapping END TO END — the rescue's symbol AND
    # the number that symbol resolves to — because either half can move
    # independently: `:unprocessable_content` is itself a rename of
    # `:unprocessable_entity` (see the DEPRECATED_STATUS_ALIASES table in
    # api_response.rb), so pinning only the symbol would let the wire code drift.
    it "maps the two join failures to the 422 and 409 the docs now quote" do
      handlers = self.class.read(
        ext_root, "server/app/controllers/concerns/system/runtime_handshake_handlers.rb"
      )
      join = handlers[/def handle_join_request.*?(?=^    # Generic K3s ready handler)/m]
      expect(join).not_to be_nil, "expected a handle_join_request method to slice"

      expect(join).to match(
        /rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e\n\s*render_error\(e\.message, :unprocessable_content\)/
      )
      expect(join).to match(
        /rescue ::System::KubernetesClusterProvisionerService::AmbiguousClusterError => e\n\s*render_error\(e\.message, :conflict\)/
      )

      expect(Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(:unprocessable_content)).to eq(422)
      expect(Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(:conflict)).to eq(409)

      # And nothing on this path returns the 404 the tutorial promised.
      expect(join).not_to match(/:not_found/)
    end

    # IMP-d231ab902879 — the eighth surface. Seven documents and a seeded KB
    # article withdrew the auto-select fabrication; it survived in the one
    # place an operator reads mid-failure while looking for the remedy: the
    # rendered 422 body. `render_error(e.message, ...)` above ships this
    # literal verbatim over HTTP, so it is operator documentation with no doc
    # guard over it — hence the assertion lives here beside the premise it
    # depends on rather than in a second file with its own copy of it.
    #
    # Reassembled from source rather than line-matched: the literal is a
    # multi-line `\`-continued concatenation, so a line-based check cannot see
    # a clause that wraps, and a whole-file match would be satisfied by any of
    # the surrounding comments that legitimately discuss auto-select.
    # A review caught the hole this now closes: keying on the FIRST
    # `raise NoClusterAvailableError,` in the method is not the same as keying
    # on the target-not-found one. `resolve_membership_cluster!` raises that
    # class TWICE — the second for the error-state case — so collapsing the
    # target-not-found raise to a single line silently re-aimed the helper at
    # the error-state message, and the assertion that names the withdrawn
    # fabrication then passed VACUOUSLY on a mutant that reintroduced it.
    # Slice the `unless c` block itself, and prove the literal is the one
    # meant before returning it, so a miss raises instead of passing.
    def self.target_not_found_message(service)
      body = service[/^    def resolve_membership_cluster!\(.*?^    end$/m]
      raise "resolve_membership_cluster! did not slice — this guard would be vacuous" if body.nil?

      block = body[/^        unless c$.*?^        end$/m]
      raise "the `unless c` (target-not-found) block did not slice" if block.nil?

      lines = block.lines.map(&:rstrip)
      at = lines.index { |l| l.strip == "raise NoClusterAvailableError," }
      raise "no multi-line `raise NoClusterAvailableError,` in the `unless c` block" if at.nil?

      literal = lines[(at + 1)..].take_while { |l| l.strip.start_with?('"') }
      raise "the raise in the `unless c` block carries no string literal" if literal.empty?

      message = literal.map { |l| l.strip.sub(/\s*\\\z/, "").sub(/\A"/, "").sub(/"\z/, "") }.join

      # Identity check: a truncated reassembly (a continuation line opening
      # with an interpolation or a different quote style) would otherwise make
      # every negative assertion below pass on a fragment.
      unless message.start_with?("target cluster ") && message.include?("not found in account")
        raise "sliced the wrong raise, or reassembled a fragment: #{message.inspect}"
      end

      message
    end

    # The anchor the message points at. Kept as one constant so the assertion
    # that the message cites it and the assertion that it RESOLVES cannot
    # drift apart into two different anchors.
    CLUSTER_ROUTING_ANCHOR = "multi-cluster-routing-via-target_cluster_id--not-implemented"

    let(:service) do
      self.class.read(ext_root, "server/app/services/system/kubernetes_cluster_provisioner_service.rb")
    end
    let(:message) { self.class.target_not_found_message(service) }

    it "the unknown-target 422 body no longer advises omitting the field to auto-select" do
      # The withdrawn advice, and why it is worse than the docs it matched:
      # taken literally in the multi-cluster account this error is most likely
      # to fire in, omitting the target turns this 422 into a 409.
      expect(message).not_to match(/auto-select/i),
                             "the 422 body still advises auto-select: #{message.inspect}"
      expect(message).not_to match(/most[- ]recent/i),
                             "the 422 body still promises a most-recent fallback: #{message.inspect}"
    end

    it "the unknown-target 422 body states both arms of what omitting it actually does" do
      # Both arms, because this message IS reachable on a path where omitting
      # the field would have worked: an account with exactly one non-error
      # cluster resolves without a target. A flat "you cannot omit it" would be
      # a new inaccuracy in the other direction.
      expect(message).to match(/exactly one non-error cluster/),
                         "the 422 body does not state the single-cluster arm: #{message.inspect}"
      expect(message).to match(/AmbiguousClusterError/),
                         "the 422 body does not name the refusal error: #{message.inspect}"
      expect(message).to match(/#{Regexp.escape(REFUSAL_EVENT)}/),
                         "the 422 body does not name the refusal event: #{message.inspect}"
      expect(message).to match(/409/),
                         "the 422 body does not state the refusal status: #{message.inspect}"
      # The third arm. A review caught this missing: with NO non-error cluster
      # omitting the field falls through to `candidates.first == nil` and
      # fails 422, not 409 — and a deleted sole cluster is the likeliest
      # reason the reader is seeing this message at all. Stating only the 409
      # arm was a fresh inaccuracy of the same shape as the withdrawn one.
      expect(message).to match(/with none it fails as this request did \(422\)/),
                         "the 422 body does not state the zero-cluster arm: #{message.inspect}"

      # It must still say what actually failed, and what to check first — an
      # accurate message that drops the remedy is useless at the moment it is
      # read.
      expect(message).to match(/not found in account/)
      expect(message).to match(/verify the cluster_id/)
    end

    it "the unknown-target 422 body cites the canonical anchor, exactly once" do
      cites = message.scan(/CONTAINER_RUNTIMES\.md##{Regexp.escape(CLUSTER_ROUTING_ANCHOR)}/)
      expect(cites.size).to eq(1),
                            "expected exactly one citation of the canonical anchor, got #{cites.size}: #{message.inspect}"
    end

    # A dead link in an error message is a fresh fabrication of the same shape
    # as the one being withdrawn — it sends the operator somewhere that does
    # not answer them. Resolve the anchor against the document's own headings
    # by GitHub's slug rule rather than trusting the string.
    it "the anchor the 422 body cites resolves to a heading in CONTAINER_RUNTIMES.md" do
      doc = self.class.read(ext_root, "docs/CONTAINER_RUNTIMES.md")
      slugs = doc.lines.grep(/\A#{'#'}{1,6} /).map do |heading|
        heading.sub(/\A#+\s*/, "").strip.downcase
               .gsub(/[^a-z0-9 _-]/, "")
               .tr(" ", "-")
      end

      expect(slugs).to include(CLUSTER_ROUTING_ANCHOR),
                       "no heading in CONTAINER_RUNTIMES.md slugifies to #{CLUSTER_ROUTING_ANCHOR.inspect}"
    end
  end

  # --- docs: matched pairs -------------------------------------------------

  describe "docs/runbooks/multi-cluster-k3s.md" do
    let(:doc) { self.class.read(ext_root, "docs/runbooks/multi-cluster-k3s.md") }

    # The withdrawn wording is deliberately kept VISIBLE (the
    # instance-pool-tuning.md / 06-rolling-upgrade.md precedent) so an operator
    # who already followed it recognises what they ran. So absence is the wrong
    # assertion: what must hold is that each false claim survives ONLY as a
    # quoted withdrawal-table row, never as prose an operator could act on.
    # That is strictly stronger than absence — deleting the table fails it too.
    # The exemption is scoped to the Phase 3 withdrawal table, NOT applied
    # document-wide. A review caught the wider version: the Troubleshooting
    # table also has rows opening with a quote or a backtick, so a restored
    # false claim placed in a Fix column would have been silently exempt.
    # The shape is pinned too — `| "<claim>" | <what is true> |`, two cells —
    # so a single-cell row cannot pose as a withdrawal.
    def self.only_in_withdrawal_rows(doc, pattern)
      phase3 = doc[/^## Phase 3 .*?(?=^## Phase 4 )/m].to_s
      raise "expected a Phase 3 section delimited by Phase 4" if phase3.empty?

      doc.lines.each_with_index.filter_map do |line, i|
        next unless line.match?(pattern)
        next if phase3.include?(line) && line.match?(/\A\| ["`].+["`] \| .+ \|\s*\z/)

        "#{i + 1}: #{line.strip[0, 90]}"
      end
    end

    # Patterns split by role, because a review found the two were conflated:
    # three of the original eight matched NOTHING in the file, so they were
    # absence assertions on historical strings dressed up as containment
    # checks — and the header's "matched PAIR" claim did not hold for them.
    # LIVE patterns must be present-and-contained; HISTORICAL ones are plain
    # absence and are labelled as such.
    LIVE_FALSE_CLAIMS = {
      "auto-select fallback" => /auto-select the \*\*most recent active cluster\*\*/,
      "wrong-cluster outcome" => /join the wrong cluster if you have multiples/,
      "REQUIRED annotation" => /←\s*REQUIRED for multi-cluster/,
      "agent-reads-it mechanism" =>
        /The agent reads `target_cluster_id` from its module assignment metadata at boot/,
      # Un-bolded in the withdrawal row. The original pattern required
      # `restart\*\*` and so could never fire — the row's own wording would
      # have passed straight back in as prose.
      "restart-to-pick-up advice" => /Agent must restart to pick up changes to `target_cluster_id`/
    }.freeze

    HISTORICAL_FALSE_CLAIMS = [
      /falls back to "join most recent active cluster"/,
      /the most-recent-active fallback still applies/,
      /silently joins whichever cluster was created most recently/,
      # Rewritten outright rather than withdrawn, so it has no row.
      /emphasize that `target_cluster_id` is required for workers/
    ].freeze

    it "states each live false claim only inside the Phase 3 withdrawal table" do
      LIVE_FALSE_CLAIMS.each do |label, pattern|
        expect(self.class.only_in_withdrawal_rows(doc, pattern))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    # Containment is vacuous if the claim is simply absent — deleting the table
    # would satisfy it. Every LIVE pattern must actually appear.
    it "carries every withdrawn claim as a labelled row" do
      LIVE_FALSE_CLAIMS.each do |label, pattern|
        expect(doc).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    it "does not reintroduce wording from earlier revisions" do
      HISTORICAL_FALSE_CLAIMS.each { |pattern| expect(doc).not_to match(pattern) }
    end

    it "states the refusal, in the sibling tutorial's wording" do
      expect(doc).to match(/AmbiguousClusterError/)
      expect(doc).to match(/system\.k3s_ambiguous_cluster_join_refused/)
      expect(doc).to match(/severity `high`/)
      # The consequence an operator will otherwise mis-diagnose: they go looking
      # for a misplaced node, and there is no node.
      expect(doc).to match(/no node/i)
    end

    # The event is named in three places. A doc-wide `to match` on the kind is
    # satisfied by any one of them, so a single site could degrade the severity
    # to "warning" and still pass — an operator filtering their event stream on
    # the wrong severity is exactly the mis-diagnosis this page exists to stop.
    # Pin every site that states a severity at all.
    it "never states the refusal at anything but severity high" do
      offenders = doc.lines.each_with_index.filter_map do |line, i|
        next unless line.include?("k3s_ambiguous_cluster_join_refused")
        next unless line.match?(/severity/i)
        next if line.match?(/severity `high`/)

        "#{i + 1}: #{line.strip[0, 90]}"
      end

      expect(offenders).to be_empty

      # ...and the check is not vacuous. A doc-wide `to match` is satisfied by
      # any single site, so it cannot see one site drifting: a mutant that
      # rewrote the BANNER's mention to "a warning emitted at severity `low`"
      # survived the assertions above, because the other two sites still
      # carried the right string. Each of the three sites is pinned by name.
      # "A low-severity warning" is precisely the reassuring misreading this
      # page exists to prevent, so the drift is not cosmetic.
      banner, body = doc.split("## When to use multi-cluster", 2)
      phase3, troubleshooting = body.split("## Troubleshooting", 2)

      { "banner" => banner, "Phase 3" => phase3, "troubleshooting" => troubleshooting }
        .each do |where, section|
          expect(section).to match(/system\.k3s_ambiguous_cluster_join_refused/),
                             "#{where} no longer names the refusal event"
        end

      # No site may soften THIS event into a warning or a lower severity. Scoped
      # to lines naming the event: a document-wide ban would forbid stating
      # another event's true severity (`pod_subnet_prefix_ignored` really is
      # `:medium`, provisioner:208).
      softened = doc.lines.each_with_index.filter_map do |line, i|
        next unless line.include?("k3s_ambiguous_cluster_join_refused")
        next unless line.match?(/severity `(low|medium|info|warning)`/)

        "#{i + 1}: #{line.strip[0, 90]}"
      end
      expect(softened).to be_empty
    end

    # The withdrawal table explains WHICH clusters count toward the ambiguity.
    # A review caught the first draft naming `provisioning`, which is not a
    # status this model has — an invented state name inside the one table whose
    # purpose is factual precision. Cross-checked against the model rather than
    # spell-checked, so a real status rename redirects the doc instead of
    # silently passing.
    # Was a per-document copy of this check, with a scan regex (`a cluster
    # still \`x\`) keyed to one phrasing. Four more documents now state the same
    # sentence in their own words, and the copy could not see any of them —
    # which is how `provisioning`, a NodeInstance status the cluster model does
    # not define, survived in tutorial 05. One implementation, five documents.
    it_behaves_like "an ambiguity-status sentence"

    it "keeps the withdrawn instruction visible and marked NOT IMPLEMENTED" do
      expect(doc).to match(/NOT IMPLEMENTED/)
      expect(doc).to match(/`k3sd\.AgentManager\.TargetClusterID`/)
      expect(doc).to match(/AssignedModules/)
      # Wired on one side only — not "does not exist".
      expect(doc).to match(/runtime_handshake_handlers\.rb/)
    end

    it "corrects the troubleshooting row that predicted a misplaced worker" do
      expect(doc).not_to match(/New worker joins the wrong cluster/)
      expect(doc).to match(/Worker does not join at all/)
    end

    # ── Phase 4 (HA control plane) — IMP-2a3ff83c1955 ─────────────────────
    #
    # The banner already suspected this and said so; verification at HEAD
    # confirmed it, so the page must stop advertising Phase 4 as working.
    # The mechanism: `ServerManager` never calls `JoinRequest` and the only
    # writer of K3S_URL/K3S_TOKEN (`WriteJoinConfig`) is defined on
    # `ShellAgentApplier`; `BootstrapConfig.InstallArgs` emits CNI args only
    # and its `default:` arm returns `nil, false`, so no `--server`,
    # `--token` or `--cluster-init` can reach the install. A second
    # k3s-server therefore runs `bootstrap!`, whose idempotency check keys on
    # `node_instance_id`, and a NEW cluster row is created.
    #
    # REGION ANCHOR is heading-to-heading (Phase 4 → Phase 5), deliberately
    # NOT the `| Withdrawn claim |` table header. This file already carries
    # one such table (Phase 3) and Phase 4 adds a second; IMP-35ad52dcfefd
    # broke a sibling guard in exactly that way, by anchoring a region on a
    # header that stopped being unique. A heading delimiter is unaffected by
    # how many tables the section grows.
    #
    # WHAT THIS CAN SEE: every line of the document, exempting only two-cell
    # withdrawal rows whose LINE NUMBER falls inside the Phase 4 heading range.
    # So a byte-identical row pasted anywhere outside Phase 4 reddens it, as
    # does a restored claim in the Anti-pattern section (the only other section
    # that stated wording these four patterns match).
    #
    # WHAT THIS CANNOT SEE — corrected after review found the first draft of
    # this comment overclaiming on both counts:
    # (a) It does NOT give containment coverage to the Troubleshooting or
    #     Concierge sections. Their falsehoods ("Token mismatch or etcd quorum
    #     issue", "For HA, propose Phase 4") match none of LIVE_HA_CLAIMS and
    #     are covered only by the plain `present_sites` ABSENCE tests below —
    #     which deletion satisfies. An earlier draft of this comment claimed
    #     all three sections were contained. They are not.
    # (b) Whether the "what is actually true" cell is true. It pins wording,
    #     not semantics; a confidently wrong correction passes.
    # (c) An HA falsehood phrased in words none of these patterns match.
    #     LIVE_HA_CLAIMS enumerates the claims this page actually made.
    # (d) Anything outside this file, and the fabrication is in at least eight
    #     others — `docs/USE_CASE_MATRIX.md` (which this spec DOES already have
    #     a describe block for, just not for this claim, so the guard there is
    #     a few lines rather than a new file), `docs/tutorials/04-k3s-cluster.md`,
    #     `docs/CONTAINER_RUNTIMES.md`, `docs/runbooks/sdwan-network-setup.md`,
    #     `docs/runbooks/k3s-smoke-full-lifecycle.md`, `docs/SMOKE_TEST.md`,
    #     and — the operator-facing one — the `k3s-server` module description
    #     in `server/db/seeds/k3s_modules.rb`. Tracked separately.
    def self.phase4_region(doc)
      doc[/^## Phase 4 .*?(?=^## Phase 5 )/m].to_s
    end

    LIVE_HA_CLAIMS = {
      "wait-for-etcd-join step" => /Wait ~120s for the second server to join etcd/,
      "VIP failover candidate" => /The second server is now a VIP failover candidate/,
      "online HA addition" => /the second server joins etcd; the existing cluster keeps running/,
      "replica growth" => /cluster goes from 1-replica to 3-replica/
    }.freeze

    it "no longer marks Phase 4 as supported in its heading" do
      heading = doc[/^## Phase 4 .*$/].to_s
      expect(heading).not_to be_empty, "Phase 4 heading not found"
      expect(heading).not_to include("✅"), "Phase 4 still advertised as supported: #{heading}"
      expect(heading).to include("NOT IMPLEMENTED"),
                         "Phase 4 heading does not state the withdrawal: #{heading}"
    end

    it "states each withdrawn HA claim only inside the Phase 4 withdrawal table" do
      region = self.class.phase4_region(doc)
      LIVE_HA_CLAIMS.each do |label, pattern|
        expect(self.class.claims_outside_withdrawal(doc, region, pattern))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    # Containment is vacuous if the claim is simply deleted — the
    # keep-it-visible idiom requires every withdrawn claim to survive as a row
    # an operator who already ran it can recognise.
    it "carries every withdrawn HA claim as a labelled row" do
      LIVE_HA_CLAIMS.each do |label, pattern|
        expect(doc).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    # Naming the missing piece is not enough. An operator who reads only "no
    # join path" still runs Phase 4 and gets a second cluster, which is what
    # refuses every later worker — so the CONSEQUENCE and the ordering hazard
    # have to be on the page too.
    it "names the mechanism and the second-cluster consequence" do
      region = self.class.phase4_region(doc)
      expect(region).not_to be_empty,
                            "Phase 4 section not found — its delimiter is the Phase 5 heading"

      { "the missing join writer" => /`WriteJoinConfig`/,
        "where that writer lives" => /`ShellAgentApplier`/,
        "the closed args seam" => /InstallArgs/,
        "the etcd prerequisite" => /--cluster-init/,
        "the second-cluster outcome" => /second cluster/i,
        "the platform-side citation" => /kubernetes_cluster_provisioner_service\.rb/ }
        .each do |label, pattern|
          expect(region).to match(pattern), "Phase 4 does not state #{label}"
        end
    end

    # The page orders Phase 3 (workers) before Phase 4 (HA); the causal
    # dependency runs the other way, so an operator reading top to bottom
    # manufactures the refusal Phase 3 warns about. Say so where they are.
    it "warns that running Phase 4 is what breaks later worker joins" do
      expect(self.class.phase4_region(doc)).to match(/Phase 3/)
    end

    # Operator ruling: K3s HA is PARKED with the docs honest, not queued. A
    # withdrawal worded as "not yet" / "pending" / "planned" is the
    # deferral-to-unbuilt-component shape — an open gap that reads as tracked
    # work, so nobody designs around it. Phase 3 is genuinely queued (it names
    # its producer improvement); Phase 4 must not borrow that framing.
    #
    # WHAT THIS CAN SEE: scheduling vocabulary inside the Phase 4 section, and
    # that the terminal disposition plus its reason are stated there.
    # WHAT IT CANNOT SEE: a deferral phrased in vocabulary not listed here
    # ("once the datastore work lands", say). The list is the phrasings that
    # actually invert this disposition, not a complete lexicon.
    it "states Phase 4 as parked, never as scheduled work" do
      region = self.class.phase4_region(doc)
      expect(self.class.present_sites(region, [
                                        /not yet implemented/i,
                                        /\bcoming soon\b/i,
                                        /\bwill be (implemented|supported|added)\b/i,
                                        /\b(is|are) planned\b/i,
                                        /\bon the roadmap\b/i,
                                        /\bawaiting implementation\b/i
                                      ])).to be_empty

      expect(region).to match(/parked/i), "Phase 4 does not state its terminal disposition"
      # Parked WITHOUT the reason is just an unexplained gap. The reason is the
      # part an operator can act on: HA would change how every cluster already
      # provisioned bootstraps.
      expect(region).to match(/already[- ]provisioned/i),
                        "Phase 4 states the disposition without the reason it is parked"
    end

    it "no longer describes the Phase 4 finding as unconfirmed" do
      banner = doc.split("## When to use multi-cluster", 2).first
      expect(self.class.present_sites(banner, [
                                        /unchanged and unconfirmed/,
                                        /should not be read as verified/,
                                        /NOT covered by this correction/,
                                        /filed and not yet remediated/
                                      ])).to be_empty
      expect(banner).to match(/Phase 4/), "the banner no longer mentions Phase 4 at all"
    end

    # A Concierge told to "propose Phase 4" proposes the thing that creates
    # the second cluster. The runbook is its instruction sheet, so this line
    # is an actuator, not prose.
    it "no longer instructs the Concierge to propose Phase 4" do
      expect(self.class.present_sites(doc, [/For HA, propose Phase 4/])).to be_empty
    end

    # Same root cause as the parked HA gap, surfacing as a PERSISTENCE claim
    # rather than a join claim: with no `--cluster-init` anywhere in the tree,
    # K3s runs SQLite via kine, so "etcd state survives reboot" and "take an
    # etcd snapshot" are both false. This runbook does not currently make
    # either claim; the sibling docs do (tracked separately), and the realistic
    # regression is someone importing the wording here while "fixing" a gap.
    #
    # WHAT THIS CAN SEE: a positive etcd persistence/snapshot/quorum assertion
    # anywhere in the file, plus the presence of the correcting fact so the
    # check is not pure absence.
    # WHAT IT CANNOT SEE: an etcd claim phrased without any of these nouns, and
    # anything outside this file. It is deliberately NOT a ban on the word
    # "etcd" — the withdrawal rows have to say it to withdraw it.
    it "makes no positive etcd persistence, snapshot or quorum claim" do
      expect(self.class.present_sites(doc, [
                                        /etcd (state|data|database|db) (survives|persists)/i,
                                        /etcd snapshot/i,
                                        /etcd (needs|requires) (a )?majority/i,
                                        /etcd quorum/i
                                      ])).to be_empty

      # Non-vacuity: the file must positively carry the fact that displaces
      # them, so deleting the etcd discussion outright does not pass.
      expect(doc).to match(/SQLite/),
                     "the runbook no longer states what the datastore actually is"
    end

    # The troubleshooting row diagnosed "token mismatch or etcd quorum issue"
    # — a diagnosis that sends the operator to `journalctl` on two servers
    # that were never trying to join each other.
    it "corrects the troubleshooting row that blamed etcd quorum" do
      expect(self.class.present_sites(doc, [/Token mismatch or etcd quorum issue/])).to be_empty
    end

    # Found by independent review of the first draft of this withdrawal, which
    # removed the capability and then offered a mitigation that does not exist.
    # `tmpfs_store` is a column on `System::Node`, not `NodeInstance`
    # (server/app/models/system/node.rb:67-98), and the /var -> /persist/var
    # bind it depended on has no production caller: `mount.EnsurePersistentVar`
    # is referenced only by its own definition and tests
    # (agent/internal/mount/bind.go:16). Withdrawing a false claim and
    # substituting a fresh one is the specific regression this file exists to
    # stop, so it is pinned rather than left to review.
    #
    # WHAT THIS CAN SEE: these three wordings. WHAT IT CANNOT SEE: any other
    # unsupported mitigation, and whether the replacement advice is sound.
    it "offers no mitigation the code does not implement" do
      expect(self.class.present_sites(doc, [
                                        /NodeInstance's `tmpfs_store`/,
                                        /`\/persist\/var\/lib\/rancher\/k3s\/` survives reboots/,
                                        /current_holder_peer_id/
                                      ])).to be_empty
    end

    # The "requires >=2 servers" framing is the exact wording the KB-seed
    # correction calls out as the earlier bad one: it reads as a prerequisite an
    # operator can satisfy by provisioning, when provisioning a second server is
    # what breaks the account. It survived the first draft in the Anti-pattern
    # heading, outside phase4_region and matching no LIVE_HA_CLAIMS pattern —
    # which is why it needs its own check rather than more region coverage.
    it "never frames HA as a prerequisite an operator can satisfy" do
      expect(self.class.present_sites(doc, [
                                        /HA requires \*\*.2 servers\*\*/,
                                        /only one candidate remains/,
                                        /one-shot multi-server cluster bootstrap/
                                      ])).to be_empty
    end
  end

  describe "server/db/seeds/system_kb_seed.rb (the seeded KB article)" do
    let(:seed) { self.class.read(ext_root, "server/db/seeds/system_kb_seed.rb") }

    it "no longer seeds the auto-select fallback as a critical rule" do
      expect(seed).not_to match(/agents auto-select the most recent active cluster/)
      expect(seed).not_to match(/workers join the wrong cluster silently/)
      expect(seed).not_to match(/MUST set `metadata\.target_cluster_id`/)
    end

    it "seeds the refusal instead" do
      expect(seed).to match(/system\.k3s_ambiguous_cluster_join_refused/)
      expect(seed).to match(/AmbiguousClusterError/)
    end

    # IMP-2a3ff83c1955. The Concierge reads this article, and the runbook's own
    # "how the Concierge should use this" section now tells it not to propose
    # HA. An article that still says HA "requires >=2 server NodeInstances"
    # would put the two sources of truth in direct contradiction, with the
    # article being the one the Concierge actually retrieves.
    #
    # WHAT THIS CAN SEE: the seed FILE's wording. WHAT IT CANNOT SEE: the
    # already-seeded row in a live database, which this file does not re-run to
    # correct (the file's own DOES-NOT-CORRECT warning covers that), nor
    # whether the correction is semantically right.
    it "no longer seeds an HA control plane as a supported flow" do
      expect(self.class.present_sites(seed, [
                                        /Requires .2 server NodeInstances/,
                                        /Slice 3 enables VIP-backed HA/
                                      ])).to be_empty
      ha = seed[/^\s*## HA control plane.*?(?=^\s*## Source)/m].to_s
      expect(ha).not_to be_empty, "HA section not found (its delimiter is the Source heading)"
      expect(ha).to match(/NOT IMPLEMENTED/)
      expect(ha).to match(/--cluster-init/)
      expect(ha).to match(/second cluster/i)
    end

    # Every clause is pinned separately: the warning is only useful if it says
    # what is stale (the live row), why (the file is not executed again), and
    # what to do about it. A vaguer note passes a single loose regex.
    it "warns that correcting this file does not correct an already-seeded deployment" do
      expect(seed).to match(/DOES NOT CORRECT AN ALREADY-SEEDED DEPLOYMENT/)
      # The comment wraps, so the sentence carries a "\n# " in the middle.
      expect(seed).to match(/does not re-run after first\n#\s*boot/)
      expect(seed).to match(/platform\.update_kb_article/)
    end
  end

  # ── IMP-f249d9d1af47: the remaining documents ───────────────────────────

  # The established wording, shared so a fifth phrasing cannot be invented for
  # a sixth document. Every corrected page must state all six.
  REFUSAL_WORDING = [
    /AmbiguousClusterError/,
    /system\.k3s_ambiguous_cluster_join_refused/,
    /severity `high`/,
    /no node is produced at all/,
    /NOT IMPLEMENTED/,
    /wired on the platform side and unreachable from the agent/
  ].freeze

  describe "docs/tutorials/04-k3s-cluster.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/04-k3s-cluster.md") }
    # The withdrawal table is nested inside a blockquote callout under Step 5,
    # bounded by the "Expected outcome" paragraph that follows it.
    let(:region) { doc[/^> ### ⚠️ Choosing a cluster with `target_cluster_id` is NOT IMPLEMENTED.*?(?=^\*\*Expected outcome:)/m].to_s }

    # This file is the reason the task exists: it stated the fabrication in
    # wording no phrase sweep for "most recent active" would find.
    LIVE_04 = {
      "mandatory-tag mechanism" => /is the mandatory tag on/,
      "picks-the-first fallback" => /first cluster it finds/,
      "404 troubleshooting" => /gets a 404/,
      "mandatory-when-multiple" => /is mandatory when more than one/
    }.freeze

    HISTORICAL_04 = [
      # Rewritten outright rather than withdrawn, so neither has a row.
      /joins workers with `target_cluster_id`/,
      /^## Step 5 — Assign `k3s-agent` with target_cluster_id$/
    ].freeze

    it "states each withdrawn claim only inside the Step 5 withdrawal table" do
      LIVE_04.each do |label, pattern|
        expect(self.class.claims_outside_withdrawal(doc, region, pattern, row_prefix: "> "))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    it "carries every withdrawn claim as a labelled row" do
      LIVE_04.each do |label, pattern|
        expect(doc).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    it "does not reintroduce wording from earlier revisions" do
      expect(self.class.present_sites(doc, HISTORICAL_04)).to be_empty
    end

    it "states the refusal in the sibling documents' wording" do
      expect(self.class.absent(doc, REFUSAL_WORDING)).to be_empty
    end

    # The 404 correction is useless if it does not name what an operator will
    # actually see, so pin both codes and the mapping site.
    it "gives the real status codes in place of the withdrawn 404" do
      expect(self.class.absent(doc, [
                                 /\*\*409\*\*/,
                                 /\*\*422\*\*/,
                                 /runtime_handshake_handlers\.rb:167-170/,
                                 /neither case returns a 404/
                               ])).to be_empty
    end

    # Presence alone does not see a code DRIFTING. Both real codes appear more
    # than once, so flipping one troubleshooting mention back to 404 left every
    # presence assertion satisfied — a mutant survived exactly that way. The
    # invariant is the SET: the only status codes this page emphasises are the
    # two the handlers actually return. Cross-checked against the handler rather
    # than hardcoded, so a change in the mapping redirects the doc instead of
    # quietly passing.
    it "emphasises no status code the handshake cannot return" do
      handlers = self.class.read(
        ext_root, "server/app/controllers/concerns/system/runtime_handshake_handlers.rb"
      )
      join = handlers[/def handle_join_request.*?(?=^    # Generic K3s ready handler)/m].to_s
      real = join.scan(/render_error\(e\.message, :(\w+)\)/).flatten.uniq
                 .map { |sym| Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(sym.to_sym).to_s }

      expect(real.sort).to eq(%w[409 422])
      expect(doc.scan(/\*\*(\d{3})\*\*/).flatten.uniq.sort).to eq(real.sort)
    end

    it "never states the refusal at anything but severity high" do
      # Non-vacuous first: a document that stopped naming a severity anywhere
      # would otherwise pass this by having nothing to check.
      expect(self.class.severity_stating_windows(doc)).not_to be_empty
      expect(self.class.softened_severity_sites(doc)).to be_empty
    end

    it_behaves_like "an ambiguity-status sentence"

    # The tutorial builds ONE cluster, which is the case that works. Correcting
    # it into "target_cluster_id is broken" without saying so would leave a
    # reader thinking the tutorial itself no longer works.
    it "keeps the single-cluster path stated as working" do
      expect(self.class.absent(doc, [
                                 /exactly one non-error cluster in the account a worker joins without a target/
                               ])).to be_empty
    end
  end

  describe "docs/CONTAINER_RUNTIMES.md" do
    let(:doc) { self.class.read(ext_root, "docs/CONTAINER_RUNTIMES.md") }
    let(:region) { doc[/^\| Withdrawn claim \| What is actually true \|.*?(?=^## Module Catalog)/m].to_s }

    LIVE_CR = {
      "must-carry mechanism" => /`k3s-agent` module assignments must/,
      "silent most-recent join" => /the agent silently joins the most-recently-created/,
      # The stale gap notice is its own falsehood: it told operators the
      # server-side ambiguity guard had NOT shipped, which inverts the truth
      # and is exactly the guard that now refuses the join.
      "stale known-gap notice" => /there is no server-side validation guard that/,
      "remove-the-metadata advice" => /remove the metadata to fall back to/
    }.freeze

    HISTORICAL_CR = [
      /^### Multi-cluster routing via `target_cluster_id`$/,
      /validation rejects join requests for any other cluster ID/
    ].freeze

    it "states each withdrawn claim only inside the withdrawal table" do
      LIVE_CR.each do |label, pattern|
        expect(self.class.claims_outside_withdrawal(doc, region, pattern))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    it "carries every withdrawn claim as a labelled row" do
      LIVE_CR.each do |label, pattern|
        expect(doc).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    it "does not reintroduce wording from earlier revisions" do
      expect(self.class.present_sites(doc, HISTORICAL_CR)).to be_empty
    end

    it "states the refusal in the sibling documents' wording" do
      expect(self.class.absent(doc, REFUSAL_WORDING)).to be_empty
    end

    it "never states the refusal at anything but severity high" do
      # Non-vacuous first: a document that stopped naming a severity anywhere
      # would otherwise pass this by having nothing to check.
      expect(self.class.severity_stating_windows(doc)).not_to be_empty
      expect(self.class.softened_severity_sites(doc)).to be_empty
    end

    it_behaves_like "an ambiguity-status sentence"

    # The routing diagram survives the withdrawal, so it must be labelled or it
    # reads as current behaviour on its own — a picture outlives the prose above
    # it in a reader's memory.
    it "labels the surviving routing diagram as intent, not behaviour" do
      expect(self.class.absent(doc, [
                                 /The diagram below is the intended design, not current behaviour/
                               ])).to be_empty
      diagram_at = doc.index("```mermaid\nflowchart TB\n    Op[Operator]")
      caveat_at = doc.index("The diagram below is the intended design")
      expect(diagram_at).not_to be_nil
      expect(caveat_at).not_to be_nil
      expect(caveat_at).to be < diagram_at
    end
  end

  describe "docs/USE_CASE_MATRIX.md" do
    let(:doc) { self.class.read(ext_root, "docs/USE_CASE_MATRIX.md") }
    # Scoped to Use Case 3's SECTION first, then to the withdrawal table inside
    # it, and bounded by the "What to watch" heading that follows that table.
    #
    # The section scope is load-bearing, not tidiness. This was
    # `doc[/^\| Withdrawn claim \| What is actually true \|.*?(?=^\*\*What to
    # watch\*\*)/m]`, which silently assumed the document contained exactly ONE
    # withdrawal table. IMP-35ad52dcfefd added a second one — for
    # lifecycle_class, deliberately copying this idiom — EARLIER in the file.
    # The non-greedy match then latched onto that table and ran to use case 1's
    # "What to watch", so the region no longer contained a single
    # target_cluster_id row and every one of them read as "stated outside the
    # withdrawal table". The idiom is meant to be reused, so its anchor cannot
    # assume uniqueness.
    let(:region) do
      section = doc[/^### Use Case 3 —.*?(?=^### Use Case 4 —)/m].to_s
      section[/^\| Withdrawn claim \| What is actually true \|.*?(?=^\*\*What to watch\*\*)/m].to_s
    end

    LIVE_UM = {
      "MUST-carry caveat" => /module assignment \*\*MUST\*\* carry `metadata\.target_cluster_id`/,
      "agent-reads-it mechanism" => /Agent reads `target_cluster_id` from module assignment metadata at boot/,
      "agent-passes-it-through" => /Agent passes through to `JoinRequest` HTTP body/,
      "auto-select fallback" => /auto-select most recent active cluster \(legacy single-cluster contract preserved\)/,
      "restart-to-pick-up advice" => /Agent must restart to pick up changes to `target_cluster_id`/
    }.freeze

    HISTORICAL_UM = [
      /Multi-cluster K3s ✅/,
      /k3s-agent joins the wrong cluster/
    ].freeze

    it "states each withdrawn claim only inside the withdrawal table" do
      LIVE_UM.each do |label, pattern|
        expect(self.class.claims_outside_withdrawal(doc, region, pattern))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    it "carries every withdrawn claim as a labelled row" do
      LIVE_UM.each do |label, pattern|
        expect(doc).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    it "does not reintroduce wording from earlier revisions" do
      expect(self.class.present_sites(doc, HISTORICAL_UM)).to be_empty
    end

    # This is the highest-traffic of the corrected files and its quick-reference
    # table is what most readers see. A corrected walkthrough under a row still
    # marked "Works" is worse than no correction: the row is the summary a
    # reader trusts.
    it "no longer marks use case 3 as working, in the quick-reference row too" do
      row = doc.lines.find { |l| l.start_with?("| 3 | Multi-cluster K3s in one account") }
      expect(row).not_to be_nil, "quick-reference row for use case 3 is gone"
      expect(row).to include("❌ Not implemented")
      expect(row).not_to include("✅")
    end

    it "states the refusal in the sibling documents' wording" do
      expect(self.class.absent(doc, REFUSAL_WORDING)).to be_empty
    end

    it "never states the refusal at anything but severity high" do
      # Non-vacuous first: a document that stopped naming a severity anywhere
      # would otherwise pass this by having nothing to check.
      expect(self.class.severity_stating_windows(doc)).not_to be_empty
      expect(self.class.softened_severity_sites(doc)).to be_empty
    end

    it_behaves_like "an ambiguity-status sentence"
  end

  # Corrected by an earlier iteration (eac22f66) and never pinned here — which
  # is how an invented cluster status survived in it while the runbook's own
  # copy of that check sat one directory away. Scoped to the claims this task
  # verified; its established wording predates this guard and is not restated.
  describe "docs/tutorials/05-multi-cluster-k3s.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/05-multi-cluster-k3s.md") }

    it_behaves_like "an ambiguity-status sentence"

    it "never states the refusal at anything but severity high" do
      expect(self.class.severity_stating_windows(doc)).not_to be_empty
      expect(self.class.softened_severity_sites(doc)).to be_empty
    end

    it "still names the refusal it was corrected to state" do
      expect(self.class.absent(doc, [
                                 /AmbiguousClusterError/,
                                 /system\.k3s_ambiguous_cluster_join_refused/,
                                 /severity `high`/
                               ])).to be_empty
    end
  end

  describe "docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md (a sixth wording)" do
    let(:doc) { self.class.read(ext_root, "docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md") }

    # Both were rewritten rather than kept as rows: neither was an instruction
    # an operator could have followed, so there is nothing to recognise.
    it "no longer claims k3s-server joins clusters by target_cluster_id" do
      expect(self.class.present_sites(doc, [/joins clusters by target_cluster_id metadata/]))
        .to be_empty
    end

    # The second error here is a LOCATION claim, and it is independently false:
    # nothing reads target_cluster_id from NodeInstance.metadata, from module
    # assignment config, or from anywhere but the handshake request parameter.
    it "no longer places the field on NodeInstance.metadata" do
      expect(self.class.present_sites(doc, [/lives on the `NodeInstance\.metadata` JSONB/]))
        .to be_empty
    end

    it "names the only source the platform actually consumes" do
      expect(self.class.absent(doc, [
                                 /module-assignment `config`/,
                                 /nothing reads it from either place/,
                                 /runtime_handshake_handlers\.rb:164/,
                                 /NOT IMPLEMENTED/,
                                 # A review caught the first draft claiming the
                                 # join_request parameter was the ONLY source
                                 # the platform consumes. `handle_k3s_ready`
                                 # forwards `params[:cluster_id]` into the same
                                 # kwarg (`:195`), and the agent really does
                                 # send that one — it just names the cluster the
                                 # node is already in. Both phases must be
                                 # stated, or the correction replaces one
                                 # over-claim with another.
                                 /`phase=join_request`/,
                                 /`phase=ready`/,
                                 /`:195`/
                               ])).to be_empty
    end
  end

  describe "docs/SMOKE_TEST.md (a scope over-claim, not the fabrication)" do
    let(:doc) { self.class.read(ext_root, "docs/SMOKE_TEST.md") }

    # Different in kind from the other five: the drill really does pass
    # target_cluster_id, at the SERVICE layer. The risk is that a green run gets
    # read as evidence the operator path works, so the fix is a clarifying
    # clause wherever the drill is described — not a withdrawal.
    it "never describes the drill's join without saying the agent is bypassed" do
      unqualified = doc.lines.each_with_index.filter_map do |line, i|
        next unless line.match?(/k3s-agents join via target_cluster_id/)
        next if line.match?(/bypassing the agent/)

        "#{i + 1}: #{line.strip[0, 100]}"
      end
      expect(unqualified).to be_empty
    end

    it "cites the service-layer call site and what a green run does not prove" do
      expect(self.class.absent(doc, [
                                 /smoke_test_k3s_agent_join\.rb:90/,
                                 /not the operator path/,
                                 # The run-order table names the same drill and
                                 # was reached by no pattern until a review
                                 # pointed it out.
                                 /target_cluster_id join \(service-layer, agent bypassed\)/
                               ])).to be_empty
    end

    # The clarifier is only true while the seed really does call the service
    # directly. If the drill is ever rewritten to drive a real agent, this
    # redirects to the doc instead of leaving a stale hedge in place.
    it "matches what the seed actually does" do
      seed = self.class.read(ext_root, "server/db/seeds/smoke_test_k3s_agent_join.rb")
      expect(self.class.absent(seed, [
                                 /::System::KubernetesClusterProvisionerService\.join_request!\( node_instance: inst, target_cluster_id: cluster\.id \)/
                               ])).to be_empty
    end
  end

end
