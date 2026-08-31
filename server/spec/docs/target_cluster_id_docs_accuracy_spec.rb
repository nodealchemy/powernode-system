# frozen_string_literal: true

require "spec_helper"

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
# What this does NOT catch: the same belief restated in wording none of these
# regexes match, or in a doc not listed here. THREE other files under
# extensions/system/docs carry the same fabricated fallback and are out of this
# task's scope — reported, not pinned:
#
#   * docs/CONTAINER_RUNTIMES.md:96 — "the agent silently joins the
#     most-recently-created" (also :73, :101-103, :283)
#   * docs/USE_CASE_MATRIX.md:108 — "auto-select most recent active cluster"
#     (also :15, :105, :111, :218)
#   * docs/tutorials/04-k3s-cluster.md:72 — "the agent picks the first cluster
#     it finds". Different WORDING for the same falsehood, which is why a
#     phrase sweep for "most recent active" would miss it.
#
# docs/SMOKE_TEST.md was initially listed here and does NOT belong: its four
# mentions describe smoke-test coverage, and db/seeds/smoke_test_k3s_agent_join.rb
# really does pass target_cluster_id — at the SERVICE layer, bypassing the agent.
# It is a scope over-claim ("2 k3s-agents join via target_cluster_id"), not this
# fabrication.
#
# It is a regression pin on known statements, not a semantic check.
RSpec.describe "target_cluster_id docs vs. what the agent actually sends" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
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
    it "names the ambiguity candidate statuses that the model actually defines" do
      model = self.class.read(
        File.expand_path("../../../../..", __dir__),
        "server/app/models/devops/kubernetes_cluster.rb"
      )
      statuses = model[/STATUSES\s*=\s*%w\[([^\]]+)\]/, 1].split
      expect(statuses).to include("error")

      counting = statuses - %w[error active]
      counting.each do |status|
        expect(doc).to match(/`#{Regexp.escape(status)}`/),
                       "withdrawal table omits `#{status}`, which counts toward the ambiguity"
      end

      invented = doc.scan(/a cluster (?:still )?`(\w+)`/).flatten.uniq - statuses
      expect(invented).to be_empty, "doc names cluster status(es) the model does not define: #{invented}"
    end

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
end
