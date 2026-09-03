# frozen_string_literal: true

require "spec_helper"

# IMP-d21a5d321a1f — docs/USE_CASE_MATRIX.md carried two false-claim families
# about a K3s cluster's control plane, and the worst instance was RECOVERY
# advice: the Anti-pattern row for "terminate the only K3s server" told the
# operator to "Add a 2nd k3s-server first; VIP failover handles transition".
#
# (1) THE SECOND-SERVER FABRICATION. There is no path by which a second
#     `k3s-server` NodeInstance joins an existing cluster:
#       * `ShellServerApplier.InstallK3sServer` runs a bare
#         `INSTALL_K3S_EXEC=server` install — no `--server`, no `--token`,
#         no `--cluster-init` (shell_applier.go:121);
#       * `BootstrapConfig.InstallArgs` emits CNI args only and its `default:`
#         arm returns `nil, false`, so nothing else can reach the install;
#       * the only K3S_URL/K3S_TOKEN writer, `WriteJoinConfig`, is defined on
#         `ShellAgentApplier` — the worker side;
#       * `server_manager.go` never calls `JoinRequest`.
#     So a second server runs `bootstrap!`, whose idempotency check keys on
#     `node_instance_id`, and a NEW `Devops::KubernetesCluster` is created —
#     and that second cluster is what makes every later `k3s-agent` join
#     refuse with `AmbiguousClusterError`. The advice manufactures the outage.
#     On the VIP side, `allocate_api_vip!` sets `failover_holder_peer_ids = []`
#     and nothing on the server path adds to it, so `sdwan_vip_failover` has
#     nothing to promote.
#
# (2) THE DATASTORE CLAIM. "etcd state survives reboot in /persist/var/lib/
#     rancher/k3s/" and "run an etcd snapshot before terminating" — K3s uses
#     embedded etcd only with `--cluster-init` (or an external
#     `--datastore-endpoint`); with neither it runs SQLite via kine. No Go or
#     Ruby source supplies either flag, so the path holds a SQLite database
#     and an "etcd snapshot" backs up nothing.
#
# (3) THE PERSISTENCE CARRIER. Both files also said k3s state under
#     `/var/lib/rancher/k3s/` "resolves into `/persist/var/lib/rancher/k3s/`
#     via the agent's EnsurePersistentVar bind mount" and survives reboots.
#     `mount.EnsurePersistentVar` has no production caller — its only callers
#     are its own test — and `agent/internal/runtime/softreboot.go:143-148`
#     records exactly that, adding that "the durable /var bind" as written
#     elsewhere in this tree describes an unused code path. Correcting the
#     datastore's IDENTITY while leaving "survives reboot" resting on a dead
#     carrier would have shipped a fresh unverified claim inside a
#     doc-accuracy commit, so the carrier is withdrawn too.
#
# Operator ruling 2026-09-01: K3s HA is PARKED with the docs honest, not
# queued. The corrected prose must not read as a deferral ("not yet", "coming
# soon") — that shape makes an open gap read as tracked work.
#
# GUARD SHAPE. The withdrawn claims stay VISIBLE, as rows of a withdrawal
# table inside Use Case 2 (the keep-it-visible idiom this file already uses
# twice). Region anchors are heading-to-heading (`### Use Case 2` → `### Use
# Case 3`) and the table is found INSIDE that section and bounded by
# contiguity — never by the `| Withdrawn claim |` header alone, which stopped
# being unique in this file the first time the idiom was reused and broke a
# sibling guard exactly that way.
#
#   CAN SEE:
#     - any of the seven withdrawn wordings restated anywhere in the file
#       outside a two-cell row of Use Case 2's own withdrawal table (containment),
#       and any of them deleted outright (presence) — both directions redden;
#     - the two rows most readers actually consult (quick-reference row 2 and
#       the Anti-pattern "terminate the only server" row) losing the
#       correcting facts;
#     - deferral vocabulary inside Use Case 2 or the Anti-pattern sheet;
#     - the k3s-server module DESCRIPTION (operator-facing via
#       `system_get_module`) re-acquiring the etcd / multi-server-HA wording;
#     - any of the code premises above changing: a join flag reaching the
#       server install, the VIP allocator seeding failover candidates, the
#       stop handler starting to write cluster status, the decommission verb
#       ceasing to be a hard delete.
#
#   CANNOT SEE:
#     - a PARAPHRASE. The containment patterns are the wordings this document
#       made; "spin up another control-plane node" in fresh prose matches
#       nothing here.
#     - the same fabrication in OTHER files. The list below is a SWEEP
#       RESULT, not an anecdote — produced from the extension root with
#         command grep -rn -iE 'etcd|EnsurePersistentVar|durable /var|HA control plane|2\+ .k3s-server|second .k3s-server' \
#           --include='*.md' --include='*.rb' --include='*.go' .
#       then read per FILE. Every hit below is a live copy of one of the three
#       families and is NOT filed as of this commit:
#         * docs/runbooks/node-provisioning.md — "Add a second `k3s-server`
#           first, or accept the outage" (the recovery advice this task
#           removed from the matrix, still standing in a runbook);
#         * docs/tutorials/04-k3s-cluster.md — "for production HA you want ≥2
#           servers", "HA control plane (≥3 servers)";
#         * docs/SMOKE_TEST.md and docs/runbooks/k3s-smoke-full-lifecycle.md —
#           "3-server HA cluster";
#         * docs/runbooks/sdwan-network-setup.md — k3s-server-2/-3 as failover
#           candidates;
#         * docs/CONTAINER_RUNTIMES.md, README.md:165,257, CLAUDE.md:144,
#           docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md:516;
#         * agent/internal/mount/runner.go:5 and bind.go:10-14 — the package
#           and function prose for the /var → /persist/var bind, written as if
#           it were how a node works. softreboot.go:143-148 is the copy that
#           already got this right.
#       Also stale BECAUSE of this commit and not editable from this lane:
#       server/spec/docs/target_cluster_id_docs_accuracy_spec.rb:1238-1250
#       enumerates the remaining copies and names "the `k3s-server` module
#       description in server/db/seeds/k3s_modules.rb:14,78-81" among them,
#       then says "NOTHING IS FILED for any of these". That copy is fixed
#       here and is now covered by this file; the enumeration needs updating.
#       agent/internal/k3sd/doc.go WAS on this list ("kubectl + worker K3S_URL
#       survive control-plane node failures via VIP holder promotion") and is
#       corrected in this commit instead, pinned below.
#       agent/internal/k3sd/applier.go:41,148 WAS on this list too — "embedded
#       etcd" in the two Go comments that were the ORIGIN of the datastore
#       family — and is corrected by IMP-c4fac10a72b6, pinned below, together
#       with the two copies that went stale the moment those comments changed:
#       the runbook sentence that cited them BY LINE as wrong, and the
#       seed_manifest_coverage_spec.rb description string that copied
#       "scheduler, etcd".
#     - whether the "what is actually true" cells are true. This pins wording,
#       not semantics; the code half pins the premises those cells rest on.
#     - a deferral phrased outside the listed vocabulary.
#     - an etcd claim that avoids the nouns state/data/database/snapshot.
#     - whether `/persist/var` actually backs `/var` on a booted node. That is
#       a boot-image property, not something this spec (or any source in this
#       tree) can settle. Which is precisely why neither document asserts it
#       any more: the guard pins the WITHDRAWAL of the carrier, not a
#       replacement mechanism.

# Namespaced rather than left on Object: a bare `MATRIX = ...` inside a
# describe block lands as a TOP-LEVEL constant, and generic names are exactly
# the shape that produces an order-dependent "already initialized constant"
# flake when another spec defines its own.
module K3sSingleServerDocs
  MATRIX = "docs/USE_CASE_MATRIX.md"
  SEED = "server/db/seeds/k3s_modules.rb"
  SHELL_APPLIER = "agent/internal/k3sd/shell_applier.go"
  APPLIER = "agent/internal/k3sd/applier.go"
  PROVISIONER = "server/app/services/system/kubernetes_cluster_provisioner_service.rb"
  CORE_K8S_TOOL = "server/app/services/ai/tools/kubernetes_provisioning_tool.rb"
  WITHDRAWAL_TABLE_HEADER = "| Withdrawn claim | What is actually true |"

  # The wordings this document actually made. Each must survive as a
  # withdrawal row (presence) and nowhere else (containment).
  LIVE_CLAIMS = {
    "quick-reference VIP failover to a next holder" => /VIP failover to next k3s-server holder/,
    "HA joiners become failover candidates" =>
      /subsequent `k3s-server` joiners \(HA control plane\) get added as `failover_holder_peer_ids` candidates/,
    "2+ servers make the VIP fallback work" => /the VIP fallback only works if you have 2\+ `k3s-server` NodeInstances/,
    "add a 2nd server as recovery advice" => /Add a 2nd k3s-server first; VIP failover handles transition/,
    "etcd state survives reboot" => /etcd state survives reboot/,
    "etcd state under /persist" => %r{etcd state in `/persist},
    "etcd snapshot as backup" => /etcd snapshot/,
    "the /persist bind mount as the persistence carrier" => /EnsurePersistentVar bind mount/
  }.freeze

  # A dead carrier must not be re-asserted as live prose anywhere in either
  # file. Absence alone is a hole (deleting the subject passes), so each site
  # pairs this with presence of the correcting facts.
  DEAD_CARRIER_ASSERTIONS = [
    %r{resolves into `?/persist/var/lib/rancher/k3s},
    /EnsurePersistentVar bind mount/,
    /all survive reboots/,
    /survives reboot is/
  ].freeze

  # The phrasings that invert a PARKED disposition into scheduled work.
  DEFERRAL_VOCABULARY = [
    /not yet implemented/i,
    /\bcoming soon\b/i,
    /\bwill be (implemented|supported|added)\b/i,
    /\b(is|are) planned\b/i,
    /\bon the roadmap\b/i,
    /\bawaiting implementation\b/i,
    /\bpending implementation\b/i
  ].freeze
end

RSpec.describe "K3s single-server control plane docs vs. what the code does" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  def self.core_read(ext_root, rel)
    read(File.expand_path("../..", ext_root), rel)
  end

  # Whitespace-normalised view, for PRESENCE assertions only — the corrected
  # prose is hard-wrapped. Containment is line-based and never uses this.
  def self.squish(text)
    text.lines.map { |line| line.sub(/\A\s*>\s?/, "") }.join(" ").gsub(/\s+/, " ")
  end

  # Go doc comments are `//`-prefixed and hard-wrapped, so a claim spanning two
  # lines survives `squish` as "... production // caller" and no contiguous
  # pattern matches it. Strip the markers before squishing.
  def self.go_prose(text)
    squish(text.lines.map { |line| line.sub(%r{\A\s*//\t?\s?}, "") }.join("\n"))
  end

  def self.absent(text, patterns)
    squished = squish(text)
    patterns.reject { |pattern| squished.match?(pattern) }.map(&:inspect)
  end

  def self.present_sites(doc, patterns)
    doc.lines.each_with_index.flat_map do |line, i|
      patterns.select { |pattern| line.match?(pattern) }
              .map { |pattern| "#{i + 1}: #{pattern.inspect} :: #{line.strip[0, 80]}" }
    end
  end

  def self.use_case_2_section(doc)
    doc[/^### Use Case 2 —.*?(?=^### Use Case 3 —)/m].to_s
  end

  def self.use_case_7_section(doc)
    doc[/^### Use Case 7 —.*?(?=^### Use Case 8 —)/m].to_s
  end

  def self.anti_pattern_section(doc)
    doc[/^## Anti-pattern Cheat Sheet.*?(?=^## Lifecycle Class Decision Tree)/m].to_s
  end

  # The withdrawal table INSIDE Use Case 2: header line plus the contiguous
  # run of pipe rows under it. Contiguity, not the header's uniqueness, is
  # what bounds it.
  def self.withdrawal_table(doc)
    section = use_case_2_section(doc)
    section[/^#{Regexp.escape(K3sSingleServerDocs::WITHDRAWAL_TABLE_HEADER)}\n(?:\|.*\n)+/].to_s
  end

  # CONTAINMENT keyed to the region's LINE RANGE: a withdrawn claim may appear
  # only as a two-cell row (first cell opening with a quote or backtick) whose
  # line number falls inside Use Case 2's withdrawal table.
  def self.claims_outside_withdrawal(doc, region, pattern)
    raise "withdrawal region not found — the containment check would be vacuous" if region.to_s.strip.empty?

    start_char = doc.index(region)
    raise "withdrawal region is not a slice of this document" if start_char.nil?

    first_line = doc[0...start_char].count("\n")
    last_line = first_line + region.count("\n")
    row_shape = /\A\| ["`][^|]*\| [^|]*\|\s*\z/

    doc.lines.each_with_index.filter_map do |line, i|
      next unless line.match?(pattern)
      next if i.between?(first_line, last_line) && line.match?(row_shape)

      "#{i + 1}: #{line.strip[0, 100]}"
    end
  end

  # ── code half: the premises the corrected prose rests on ──────────────

  describe "the k3s-server install (agent/internal/k3sd)" do
    it "runs a bare INSTALL_K3S_EXEC=server install — no --server, --token or --cluster-init" do
      src = self.class.read(ext_root, K3sSingleServerDocs::SHELL_APPLIER)
      body = src[/func \(s \*ShellServerApplier\) InstallK3sServer\(.*?\n\}/m]
      expect(body).not_to be_nil, "InstallK3sServer not found — the install premise is unpinned"
      expect(body).to include('script := `curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s -`')
      expect(body).not_to match(/--cluster-init|--datastore-endpoint|--server[= ]|--token[= ]/)
    end

    # POSITIVE enumeration of the switch arms, so a new arm that emitted a
    # join or datastore flag reddens this rather than slipping past an
    # absence check.
    it "InstallArgs emits CNI args only, and its default arm returns nil, false" do
      src = self.class.read(ext_root, K3sSingleServerDocs::APPLIER)
      body = src[/func \(c BootstrapConfig\) InstallArgs\(\).*?\n\}/m]
      expect(body).not_to be_nil, "InstallArgs not found"
      expect(body.scan(/^\tcase (.+):$/).flatten).to eq([ '"", CniPluginFlannel', "CniPluginOvnKubernetes" ])
      expect(body).to include("default:\n\t\treturn nil, false")
      expect(body).not_to match(/--cluster-init|--datastore-endpoint|--server|--token/)
    end

    # IMP-c4fac10a72b6 — the ORIGIN of family (2). The BootstrapConfig type
    # doc and the ServerApplier.InstallK3sServer interface doc both described
    # the zero-value config as "embedded etcd", and every document above
    # inherited its confidence from those two sentences. The exec-string
    # oracle lives beside the code (agent/internal/k3sd/datastore_default_test.go
    # runs InstallK3sServer through the recording exec and pins the bare
    # upstream line); this half keeps the prose in step with it. Absence of
    # "embedded etcd" is paired with presence of the datastore facts at both
    # sites so a deleted comment cannot pass.
    it "documents the zero-value BootstrapConfig datastore as SQLite via kine, never embedded etcd" do
      files = Dir[File.join(ext_root, "agent/internal/k3sd/*.go")].reject { |f| f.end_with?("_test.go") }
      expect(files).not_to be_empty, "k3sd sources not found — this check is vacuous"
      hits = files.flat_map do |path|
        self.class.present_sites(File.read(path), [ /embedded etcd/ ]).map { |site| "#{path.sub(ext_root, '')}:#{site}" }
      end
      expect(hits).to be_empty

      src = self.class.read(ext_root, K3sSingleServerDocs::APPLIER)
      type_doc = src[%r{((?:^//.*\n)+)type BootstrapConfig struct}, 1]
      expect(type_doc).not_to be_nil, "BootstrapConfig doc comment not found"
      expect(self.class.absent(self.class.go_prose(type_doc), [
        /SQLite/, /kine/, /--cluster-init/, /--datastore-endpoint/, /PARKED/
      ])).to be_empty
      expect(self.class.present_sites(type_doc, K3sSingleServerDocs::DEFERRAL_VOCABULARY)).to be_empty

      iface_doc = src[%r{((?:^\t//.*\n)+)\tInstallK3sServer\(ctx context\.Context, cfg BootstrapConfig\) error}, 1]
      expect(iface_doc).not_to be_nil, "ServerApplier.InstallK3sServer doc comment not found"
      expect(self.class.absent(self.class.go_prose(iface_doc), [ /SQLite/, /kine/, /--cluster-init/ ])).to be_empty
      expect(self.class.present_sites(iface_doc, K3sSingleServerDocs::DEFERRAL_VOCABULARY)).to be_empty
    end

    it "supplies --cluster-init / --datastore-endpoint nowhere in the k3sd reconcilers or the provisioner" do
      files = Dir[File.join(ext_root, "agent/internal/k3sd/*.go")].reject { |f| f.end_with?("_test.go") }
      files << File.join(ext_root, K3sSingleServerDocs::PROVISIONER)
      expect(files.length).to be > 1, "k3sd sources not found — this absence check is vacuous"

      hits = files.flat_map do |path|
        File.read(path).lines.each_with_index
            .reject { |line, _| line.lstrip.start_with?("//") }
            .select { |line, _| line.match?(/cluster-init|datastore-endpoint|cluster_init/) }
            .map { |line, i| "#{path.sub(ext_root, "")}:#{i + 1}: #{line.strip[0, 80]}" }
      end
      expect(hits).to be_empty

      # Comment lines are skipped above (the corrected prose in doc.go NAMES
      # the flags to say they are absent), so keep the check honest about
      # what it can still see: a flag in code, not in prose.
      code_lines = files.sum { |path| File.read(path).lines.count { |l| !l.lstrip.start_with?("//") && !l.strip.empty? } }
      expect(code_lines).to be > 100, "almost everything was skipped as comment — this check is vacuous"
    end
  end

  describe "the persistence carrier the docs used to name" do
    # The premise behind family (3). Counted by parsing CALL SITES — a bare
    # token grep would count the definition, the doc comments and the
    # softreboot.go comment that says it has no caller, and report the claim
    # as live. If a production caller ever appears, the withdrawal in both
    # documents becomes wrong and this reddens first.
    it "mount.EnsurePersistentVar is called only from its own test" do
      callers = Dir[File.join(ext_root, "agent/**/*.go")].flat_map do |path|
        File.read(path).lines.each_with_index
            .select { |line, _| line.match?(/\bEnsurePersistentVar\(/) && !line.lstrip.start_with?("//") }
            .reject { |line, _| line.match?(/^func /) }
            .map { |_, i| "#{path.sub(ext_root, "")}:#{i + 1}" }
      end
      expect(callers.reject { |site| site.include?("_test.go") }).to be_empty
      expect(callers).not_to be_empty, "no call site at all — this guard would be vacuous"
    end

    it "softreboot.go still records that /var is not a bind mount on a current node" do
      src = self.class.go_prose(self.class.read(ext_root, "agent/internal/runtime/softreboot.go"))
      expect(self.class.absent(src, [
        %r{/var itself is NOT a bind mount on a current node},
        /mount\.EnsurePersistentVar has no production caller/
      ])).to be_empty
    end
  end

  describe "the k3sd package doc (operator-facing Go prose)" do
    let(:src) { self.class.read(ext_root, "agent/internal/k3sd/doc.go") }

    it "no longer claims K3S_URL survives control-plane node failures via VIP promotion" do
      expect(self.class.present_sites(src, [
        /via VIP holder promotion/,
        /Slice 3 VIP failover/
      ])).to be_empty

      # Reflow-proof: the claim is hard-wrapped across two comment lines, so
      # a line-based check alone would miss it rejoined onto one.
      expect(self.class.go_prose(src)).not_to match(/survive control-plane node failures/)
    end

    it "states the single-server truth and the parked disposition" do
      expect(self.class.absent(self.class.go_prose(src), [
        /no promotion target/,
        /failover_holder_peer_ids empty/,
        /SEPARATE cluster/,
        /PARKED, not queued/
      ])).to be_empty
      expect(self.class.present_sites(src, K3sSingleServerDocs::DEFERRAL_VOCABULARY)).to be_empty
    end
  end

  describe "the platform half (KubernetesClusterProvisionerService)" do
    let(:src) { self.class.read(ext_root, K3sSingleServerDocs::PROVISIONER) }

    it "allocates the api VIP with the bootstrap peer as sole holder and no failover candidates" do
      body = src[/def allocate_api_vip!\(.*?\n    end\n/m]
      expect(body).not_to be_nil, "allocate_api_vip! not found"
      expect(body).to include("vip.holder_peer_ids = [ bootstrap_peer.id ]")
      expect(body).to include("vip.failover_holder_peer_ids = []")
    end

    # The recovery row says the dead cluster's row keeps counting as a join
    # candidate. That is true only while the stop handler leaves the CLUSTER
    # status alone and the candidate query excludes only `error`.
    it "marks a stopped server's node disconnected without touching the cluster row" do
      body = src[/def mark_node_stopped!(.*?)\n    end\n/m, 1]
      expect(body).not_to be_nil, "mark_node_stopped! not found"
      expect(body).to include('node.update!(status: "disconnected"')
      expect(body).not_to match(/cluster\.update!|kubernetes_cluster\.update!|status: "error"/)

      candidates = src[/candidates = ::Devops::KubernetesCluster.*?\.to_a$/m]
      expect(candidates).not_to be_nil, "the candidates query did not slice"
      expect(candidates).to match(/\.where\.not\(status: "error"\)/)
    end

    # The corrected Use Case 2 sentence NAMES the two writers rather than
    # claiming none exists — a review found the absolute false. Pinned so the
    # narrower claim (neither is reachable from a second server joining THIS
    # cluster) keeps a subject.
    it "has exactly two writers of failover_holder_peer_ids, both named in the doc" do
      writers = src.lines.each_with_index
                   .select { |line, _| line.match?(/failover_holder_peer_ids:/) }
                   .map { |line, i| "#{i + 1}: #{line.strip[0, 60]}" }
      expect(writers.length).to eq(2), "writer count changed — Use Case 2 names two: #{writers.inspect}"
      expect(src).to match(/def add_to_vip_failover_candidates!/)
      expect(src).to match(/def refresh_vip_holder!/)
    end

    it "short-circuits bootstrap! on the SAME node_instance only, so a second server creates a new cluster" do
      body = src[/def bootstrap!(.*?)\n    end\n/m, 1]
      expect(body).not_to be_nil, "bootstrap! not found"
      expect(body).to include("::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)")
      expect(body).to include("::Devops::KubernetesCluster.create!(")
    end
  end

  describe "the core decommission verb the recovery row names" do
    it "kubernetes_decommission_cluster is a hard delete of the cluster row" do
      src = self.class.core_read(ext_root, K3sSingleServerDocs::CORE_K8S_TOOL)
      expect(src).to include('declare_action "kubernetes_decommission_cluster"')
      body = src[/def decommission_cluster\(params\)(.*?)\n      end\n/m, 1]
      expect(body).not_to be_nil, "decommission_cluster not found"
      expect(body).to include("cluster.destroy!")
    end
  end

  # IMP-c4fac10a72b6 — two copies that became stale the moment the Go
  # comments were corrected: the runbook cited them BY LINE as wrong, and a
  # sibling spec's description string copied "scheduler, etcd" for the seed.
  # The runbook keeps its (true) datastore paragraph; only the citation of
  # the wrong comments is replaced with a citation of the corrected one.
  describe "the copies that cited or restated the Go comments" do
    it "docs/runbooks/multi-cluster-k3s.md cites the corrected BootstrapConfig comment, not two wrong ones" do
      doc = self.class.read(ext_root, "docs/runbooks/multi-cluster-k3s.md")
      expect(self.class.present_sites(doc, [
        /applier\.go:41\b/, /applier\.go:148\b/, /They are wrong about upstream k3s/
      ])).to be_empty
      expect(self.class.absent(doc, [
        /BootstrapConfig.{0,200}SQLite via kine/,
        /--cluster-init/
      ])).to be_empty
    end

    it "no k3s document, seed or spec restates the control plane as 'scheduler, etcd'" do
      globs = %w[docs/**/*.md server/db/seeds/**/*.rb server/spec/**/*.rb agent/**/*.go]
      files = globs.flat_map { |g| Dir[File.join(ext_root, g)] }
      expect(files.length).to be > 50, "sweep scope collapsed — this check is vacuous"
      hits = files.flat_map do |path|
        rel = path.sub(ext_root, "")
        # The schema doc's k3s-server EXAMPLE manifest starts k3s with
        # `--cluster-init` (:541), so "etcd" is true of that example. It is
        # not the shipped module; a reader who conflates the two is misled,
        # but the sentence itself is not the fabrication this guard pins.
        next [] if rel.end_with?("docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md")
        next [] if File.expand_path(path) == File.expand_path(__FILE__) # the pattern's own literal

        self.class.present_sites(File.read(path), [ /scheduler, etcd/ ]).map { |site| "#{rel}:#{site}" }
      end
      expect(hits).to be_empty
    end
  end

  # ── doc half ───────────────────────────────────────────────────────────

  describe K3sSingleServerDocs::MATRIX do
    let(:doc) { self.class.read(ext_root, K3sSingleServerDocs::MATRIX) }
    let(:table) { self.class.withdrawal_table(doc) }

    it "carries a withdrawal table inside Use Case 2" do
      expect(self.class.use_case_2_section(doc)).not_to be_empty, "Use Case 2 section not found"
      expect(table).not_to be_empty, "no withdrawal table inside Use Case 2 — containment below would be vacuous"
    end

    it "states each withdrawn claim only as a row of Use Case 2's withdrawal table" do
      K3sSingleServerDocs::LIVE_CLAIMS.each do |label, pattern|
        expect(self.class.claims_outside_withdrawal(doc, table, pattern))
          .to be_empty, "#{label} still stated as instruction, not withdrawal"
      end
    end

    # Containment is vacuous if the claim is simply deleted.
    it "carries every withdrawn claim as a labelled row" do
      K3sSingleServerDocs::LIVE_CLAIMS.each do |label, pattern|
        expect(table).to match(pattern), "#{label} is not carried in the withdrawal table at all"
      end
    end

    it "names the mechanism, the datastore and the second-cluster consequence in Use Case 2" do
      section = self.class.use_case_2_section(doc)
      expect(self.class.absent(section, [
        /SQLite/,
        /kine/,
        /--cluster-init/,
        /shell_applier\.go/,
        /InstallArgs/,
        /allocate_api_vip!/,
        /second cluster/i,
        /AmbiguousClusterError/,
        /kubernetes_cluster_provisioner_service\.rb/,
        /parked/i,
        /already[- ]provisioned/i
      ])).to be_empty
    end

    # Family (3): the dead carrier must be withdrawn, not restated, and the
    # replacement prose must say what is actually known.
    it "withdraws the /persist bind mount as the persistence carrier" do
      section = self.class.use_case_2_section(doc)
      expect(self.class.present_sites(
        section.sub(self.class.withdrawal_table(doc), ""),
        K3sSingleServerDocs::DEAD_CARRIER_ASSERTIONS
      )).to be_empty
      expect(self.class.absent(section, [
        /EnsurePersistentVar/,
        /no production caller/,
        /softreboot\.go/,
        /boot-image property|property of the node|boot image/i
      ])).to be_empty
    end

    it "states the disposition as parked, never as scheduled work" do
      region = self.class.use_case_2_section(doc) + self.class.anti_pattern_section(doc)
      expect(region).not_to be_empty
      expect(self.class.present_sites(region, K3sSingleServerDocs::DEFERRAL_VOCABULARY)).to be_empty
    end

    # The quick-reference row is what most readers see; a corrected
    # walkthrough under a row that still promises failover is worse than none.
    it "tells the truth in the quick-reference row for use case 2" do
      row = doc.lines.find { |l| l.start_with?("| 2 | Single-cluster K3s") }
      expect(row).not_to be_nil, "quick-reference row for use case 2 is gone"
      expect(row).to match(/parked/i)
      expect(row).to match(/SQLite/)
      expect(row).to match(/second cluster|separate cluster/i)
    end

    # The RECOVERY row — the priority of this task. An operator reads it while
    # already in trouble, so it must say what to do (restore the bootstrap
    # node; hard-delete a dead cluster's row before re-bootstrapping) and what
    # NOT to do, with the consequence.
    it "replaces the second-server recovery advice with the real remedy" do
      row = doc.lines.find { |l| l.start_with?("| Terminate the *only* K3s server") }
      expect(row).not_to be_nil, "the terminate-the-only-server row is gone"
      expect(row).not_to match(/Add a 2nd k3s-server first/)
      expect(row).to match(/second cluster|separate cluster/i)
      expect(row).to match(/refuse/i)
      expect(row).to match(/restore/i)
      expect(row).to match(/parked/i)
      expect(row).to match(/kubernetes_decommission_cluster/)
    end

    it "replaces the etcd-snapshot backup advice with the SQLite datastore path" do
      row = doc.lines.find { |l| l.start_with?("| Backup `/persist` before terminating") }
      expect(row).not_to be_nil, "the backup row is gone"
      expect(row).to match(/SQLite/)
      expect(row).to match(%r{/var/lib/rancher/k3s/server/})
      expect(row).to match(/docker save/)
    end

    it "corrects the Use Case 7 control-plane persistence bullet" do
      section = self.class.use_case_7_section(doc)
      bullet = section.lines.find { |l| l.start_with?("- Control plane") }
      expect(bullet).not_to be_nil, "the Use Case 7 control-plane bullet is gone"
      expect(bullet).to match(/SQLite/)
      expect(bullet).not_to match(/etcd state/)
    end
  end

  # The k3s-server module DESCRIPTION is operator-facing through
  # `system_get_module`, and it made both claims: "embedded etcd" and
  # "multi-server HA joins additional k3s-server NodeInstances". A catalog
  # blurb is not an instruction sheet an operator has already followed, so it
  # is rewritten outright rather than withdrawn; the absence checks are paired
  # with presence of the correcting facts so a deleted description cannot pass.
  describe K3sSingleServerDocs::SEED do
    let(:src) { self.class.read(ext_root, K3sSingleServerDocs::SEED) }

    it "describes the k3s-server datastore as SQLite and one server per cluster" do
      description = src[/server_description = <<~DESC\.strip\n(.*?)\nDESC\n/m, 1]
      expect(description).not_to be_nil, "server_description heredoc not found"
      expect(self.class.absent(description, [
        /SQLite/,
        /kine/,
        /--cluster-init/,
        /separate cluster|second cluster/i,
        /parked/i
      ])).to be_empty
    end

    it "no longer asserts the /persist bind mount as the persistence carrier" do
      expect(self.class.present_sites(src, K3sSingleServerDocs::DEAD_CARRIER_ASSERTIONS)).to be_empty
      description = src[/server_description = <<~DESC\.strip\n(.*?)\nDESC\n/m, 1]
      expect(self.class.absent(description, [
        /no production caller/,
        /softreboot\.go/,
        /boot\s*image/i
      ])).to be_empty
    end

    it "no longer claims embedded etcd or a multi-server HA join anywhere in the seed" do
      expect(self.class.present_sites(src, [
        /embedded etcd/,
        /external etcd/,
        /etcd database/,
        /etcd data\b/,
        /multi-server HA joins/
      ])).to be_empty
    end
  end
end
