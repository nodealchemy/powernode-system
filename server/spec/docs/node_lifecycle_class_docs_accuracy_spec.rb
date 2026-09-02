# frozen_string_literal: true

require "rails_helper"
require "yaml"

# IMP-35ad52dcfefd — three documents told an operator that a System::Node's
# `lifecycle_class` is a knob they can set, read back, and filter on. It is
# none of those things.
#
# What 9c7f7c00 (IMP-17926b4740a8) established, re-pinned here as CODE:
#
#   * NOT SETTABLE. `system_create_node` declares eight parameters and
#     `system_update_node` nine (its eight mutable attributes plus the `node_id`
#     selector); `lifecycle_class` is not one of either. REST `node_params`
#     permits ten attributes and does not include it, and create and update
#     SHARE that one permit list. Undeclared MCP keys are dropped without an
#     error (BaseTool#validate_params! only checks for MISSING required params),
#     so the wrong call succeeds and teaches the wrong model.
#   * NOT READABLE. `serialize_node` emits eight keys and none is
#     `lifecycle_class`; no serializer under server/app/serializers/ mentions it.
#   * NOT FILTERABLE. `system_list_nodes` declares exactly one parameter,
#     `template_id`, and `list_nodes` has exactly one where-clause.
#   * AND, SINCE IMP-19843220ac68, NOT WRITTEN EITHER — but "nothing sets it"
#     is still a sentence to write carefully, because it was wrong twice
#     before. Until that change `InstancePoolService#provision_warming_member!`
#     created each pool member's Node with `lifecycle_class:
#     pool.lifecycle_class` (System::InstancePool being CHECK-constrained to
#     ephemeral|spot, so a pool member was never `persistent`) on an unattended
#     path — InstancePoolReplenisherJob, a 60s cron — and
#     PlatformDeploymentOrchestrator wrote the literal "persistent". The
#     wire-or-retire fork was settled as RETIRE: both writes are gone and the
#     column is nullable with a NULL default, so a Node created today carries
#     nil rather than a confident wrong answer. The examples below are the
#     ENUMERATION that keeps that sentence honest — they redden if ANY writer
#     reappears under server/app.
#   * ONE WRITER SURVIVES, out of scope on purpose: db/seeds/example_multi_tenant.rb
#     writes the column directly through find_or_initialize_by +
#     assign_attributes, defaulted to "persistent". It is a dev seed, not an
#     operator path, and it is swept by the column DROP (step 2) together with
#     the CHECK constraint and the index. Its shape has its own example below,
#     BECAUSE the create!-shaped scan cannot see it.
#
# GUARD SHAPE, and what it can and cannot see. Stated up front because the
# spec this one sits beside failed in exactly this way: docs/tutorials/
# 10-gitops-fleet.md is in module_docs_mcp_call_signatures_spec.rb COVERED_DOCS
# and carried a `lifecycle_class:` YAML block for its whole life, because that
# parser reads `platform.<verb>({ ... })` call sites and a YAML block is not
# one. The other two files here were in NO allowlist at all.
#
#   CAN SEE:
#     - a withdrawn instruction line losing its WITHDRAWN marker, or being
#       deleted outright (containment AND presence, so both directions redden);
#     - a MCP_API_REFERENCE.md table row promising a `(filter by ...)` list the
#       verb does not declare — mechanically, by reading action_definitions,
#       not by pinning the one row we know about;
#     - the tutorial's fleet.yaml drifting away from the schema note beside it,
#       in BOTH directions, because the note is compared against the real
#       DesiredStateValidator run over the doc's actual bytes;
#     - any of the code premises above changing.
#
#   CANNOT SEE:
#     - a PARAPHRASE. The containment checks are token-level regressions pins
#       on the statements these documents make today. "Set the node's lifecycle
#       to ephemeral" in fresh prose matches nothing here.
#     - a false lifecycle_class claim in a FOURTH document. The doc half is
#       scoped to the three files; only the MCP_API_REFERENCE row check is
#       table-driven, and only within that one file.
#     - a claim about lifecycle_class in a `platform.<verb>` argument hash —
#       that is the sibling spec's job, and the reason node-provisioning.md is
#       in its COVERED_CALLS rather than here.
#     - nested YAML keys anywhere but the tutorial's fleet.yaml block.
#     - a MCP_API_REFERENCE.md row that promises a filter WITHOUT the
#       parenthesised "(filter by ...)" form. Two rows use an unparenthesised
#       "filter by" (:130, :293) and are skipped; both are accurate today, but
#       the check would not have caught them if they were not.
#     - a GitOps dispatch written as `kind.to_s == "node"` rather than
#       `kind == "node"`. The apply_diff scan is literal on that shape, so such
#       a line would leave the six-kind equality intact and green while "there
#       is no `node` kind" quietly became false.
#     - a System::Node writer that does NOT go through `System::Node.create!`.
#       The server/app enumeration is paren-balanced over that constructor only,
#       so an `assign_attributes` / `update!` / mass-assignment writer is
#       invisible to it. One such writer exists — db/seeds/example_multi_tenant.rb
#       — and has its own example below BECAUSE the create!-shaped scan could not
#       see it. A writer of that shape appearing under server/app would not
#       redden anything here, nor would one in server/lib/ or db/migrate/
#       (a backfill migration), which neither glob covers.

# Namespaced rather than left on Object. A bare `MATRIX = ...` inside a
# describe block lands as a TOP-LEVEL constant, and these are generic names —
# exactly the shape that produces an order-dependent "already initialized
# constant" flake when another spec defines its own. The sibling
# target_cluster_id spec carries the same note for the same reason.
module NodeLifecycleClassDocs
  MATRIX = "docs/USE_CASE_MATRIX.md"
  MCP_REF = "docs/MCP_API_REFERENCE.md"
  GITOPS = "docs/tutorials/10-gitops-fleet.md"
  WITHDRAWAL_TABLE_HEADER = "| Withdrawn claim | What is actually true |"
end

RSpec.describe "System::Node lifecycle_class docs vs. what the code does" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # Whitespace-normalised view, for TRUTH (presence) assertions only. The
  # corrected prose is hard-wrapped, so a byte-exact match would redden on a
  # reflow that changed nothing an operator reads. Containment checks are
  # line-based and deliberately do NOT use this — nothing here can exempt a
  # false claim.
  def self.squish(text)
    text.lines.map { |line| line.sub(/\A\s*>\s?/, "") }.join(" ").gsub(/\s+/, " ")
  end

  # PRESENCE, reported compactly: returns the patterns that are ABSENT, so a
  # failure names them instead of dumping the whole document.
  def self.absent(text, patterns)
    squished = squish(text)
    patterns.reject { |pattern| squished.match?(pattern) }.map(&:inspect)
  end

  # CONTAINMENT for a keep-it-visible withdrawal. The false instruction is
  # deliberately RETAINED, so an absence assertion is unusable: it would be
  # satisfied by deleting the whole passage and leaving an operator with no
  # warning at all. Instead every line carrying the withdrawn token must be
  # MARKED as withdrawn. Returns the offending "line: text" sites.
  #
  # Two exemptions, and only two:
  #   1. a WITHDRAWN marker in the CONTIGUOUS COMMENT RUN ending at the site
  #      (the line itself, or the unbroken block of `#`/`//` lines above it);
  #   2. a two-cell row of the canonical withdrawal TABLE, scoped by walking UP
  #      to its header.
  #
  # Both walks are contiguity-bounded rather than windowed, and that is
  # load-bearing. The first draft used a +/-4 line window and a mutation
  # SURVIVED it: stripping the WITHDRAWN marker off the ephemeral-worker
  # assignment in Use Case 7 still passed, because the target_cluster_id
  # withdrawal three lines BELOW it was inside the window. A window lets a site
  # borrow its neighbour's marker; a contiguous comment run cannot, because the
  # intervening `Module: k3s-agent` line ends it.
  def self.unmarked_sites(doc, pattern)
    lines = doc.lines
    lines.each_with_index.filter_map do |line, i|
      next unless line.match?(pattern)
      next if marked_comment_run?(lines, i)
      next if withdrawal_table_row?(lines, i)

      "#{i + 1}: #{line.strip[0, 100]}"
    end
  end

  # The site's own line plus the unbroken run of comment lines directly above
  # it. Stops at the first line that is not a comment.
  def self.marked_comment_run?(lines, index)
    return true if lines[index].include?("WITHDRAWN")

    (index - 1).downto(0) do |j|
      stripped = lines[j].strip
      return false unless stripped.start_with?("#", "//")
      return true if stripped.include?("WITHDRAWN")
    end
    false
  end

  # Exactly two cells (three pipes, neither cell containing one), first cell
  # opening with a quote or backtick, and inside a table whose header is the
  # canonical one. Walking up stops at the first blank line, so the row must be
  # in that table's own contiguous block.
  def self.withdrawal_table_row?(lines, index)
    return false unless lines[index].match?(/\A\| ["`][^|]*\| [^|]*\|\s*\z/)

    index.downto(0) do |j|
      return false if lines[j].strip.empty?
      return true if lines[j].strip == NodeLifecycleClassDocs::WITHDRAWAL_TABLE_HEADER
    end
    false
  end

  # The parameter names a "(filter by ...)" clause actually CLAIMS. A clause is
  # a comma-separated list; an item is a claim if it is backticked, or if it is
  # a single bare word. Anything else is prose and is ignored.
  #
  # The bare-word rule is what makes `(filter by status, type)` a claim. The
  # prose rule is what stops `(filter by \`gpu_type\` + min count)` from being
  # read as a claim on a parameter named `count` — a naive \w+ scan over the
  # clause reported exactly that, and a guard that invents a defect is worse
  # than one that misses it.
  def self.claimed_params(clause)
    clause.split(",").flat_map do |item|
      backticked = item.scan(/`(\w+)`/).flatten
      next backticked if backticked.any?

      word = item.strip
      word.match?(/\A[a-z][a-z_]*\z/) && word != "etc" ? [ word ] : []
    end.uniq
  end

  # PRESENCE half of the same pair: a containment check over a pattern that
  # matches NOTHING is an absence assertion wearing a containment costume.
  def self.match_count(doc, pattern)
    doc.lines.count { |line| line.match?(pattern) }
  end

  # PRESENCE of the OPERATOR-FACING site specifically — the kept-visible code
  # block, not its summary row in the canonical table.
  #
  # A plain match_count could not tell the two apart, and a mutation SURVIVED
  # because of it: deleting the withdrawn `Node.update!` line from Use Case 4
  # entirely still passed, since the withdrawal table's own row for that same
  # claim kept the count above zero. Deleting the passage an operator actually
  # reads is precisely the regression the keep-it-visible idiom exists to stop.
  def self.code_site_count(doc, pattern)
    lines = doc.lines
    lines.each_with_index.count do |line, i|
      line.match?(pattern) && !withdrawal_table_row?(lines, i)
    end
  end

  # Every `System::Node.create!(...)` argument list in `src`, paren-balanced.
  # Co-occurrence of the constructor and the column name ANYWHERE in a file is
  # not evidence the constructor sets it; this reads the actual arguments.
  def self.node_create_arguments(src)
    src.enum_for(:scan, /System::Node\.create!\(/).map { Regexp.last_match.end(0) }.map do |start|
      depth = 1
      i = start
      i += 1 while i < src.length && (depth += (src[i] == "(" ? 1 : src[i] == ")" ? -1 : 0)) > 0
      src[start...i]
    end
  end

  # --- code: the premises the docs must be written to ---------------------

  describe "the MCP node surface (Ai::Tools::SystemFleetTool)" do
    let(:defs) { Ai::Tools::SystemFleetTool.action_definitions }

    it "declares exactly template_id on system_list_nodes — no status, no lifecycle_class" do
      params = defs.fetch("system_list_nodes").fetch(:parameters)
      expect(params.keys).to eq([ :template_id ])
    end

    # POSITIVE enumeration, not `not_to include(:lifecycle_class)`: a rename of
    # the column would satisfy an absence assertion while leaving the surface
    # exactly as unreachable as it is today.
    it "declares neither lifecycle_class on create nor on update" do
      expect(defs.fetch("system_create_node").fetch(:parameters).keys)
        .to eq(%i[name template_id description enabled worker_id public_address allocate_public_ip config])
      expect(defs.fetch("system_update_node").fetch(:parameters).keys)
        .to eq(%i[node_id name description enabled node_template_id worker_id public_address allocate_public_ip config])
    end

    it "has exactly one where-clause in list_nodes, on node_template_id" do
      src = self.class.read(ext_root, "server/app/services/ai/tools/system_fleet_tool.rb")
      body = src[/def list_nodes\(params\)(.*?)\n      end\n/m, 1]
      expect(body).not_to be_nil, "list_nodes not found — the filter claim below is unpinned"
      expect(body.scan(/\.where\(/).length).to eq(1)
      expect(body).to include("scope.where(node_template_id: params[:template_id])")
    end

    it "serializes eight node keys, none of them lifecycle_class" do
      src = self.class.read(ext_root, "server/app/services/ai/tools/system_fleet_tool.rb")
      body = src[/def serialize_node\(n\)(.*?)\n      end\n/m, 1]
      expect(body.scan(/^\s{10}(\w+):/).flatten)
        .to eq(%w[id name template_id worker_id ssh_key_fingerprint ssh_key_type enabled created_at])
    end

    # system_get_node is the read an operator would actually reach for, and it
    # uses the _full variant. Pinning only serialize_node would leave the four
    # keys that variant ADDS unchecked.
    it "adds four keys on the full serializer, none of them lifecycle_class" do
      src = self.class.read(ext_root, "server/app/services/ai/tools/system_fleet_tool.rb")
      body = src[/def serialize_node_full\(n\)(.*?)\n      end\n/m, 1]
      expect(body.scan(/^\s{10}(\w+):/).flatten)
        .to eq(%w[template_name instance_count module_count ssh_host_key_fingerprint])
    end
  end

  describe "the REST node surface" do
    it "permits ten attributes on the ONE list create and update share" do
      src = self.class.read(ext_root, "server/app/controllers/api/v1/system/nodes_controller.rb")
      permit = src[/def node_params(.*?)\n        end\n/m, 1]
      expect(permit.scan(/:(\w+)/).flatten)
        .to eq(%w[node name description enabled node_template_id worker_id public_address allocate_public_ip ssh_key ssh_host_key])
      # One permit list, two callers — so "not settable at create" and "not
      # changeable later" are the same fact, not two.
      expect(src.scan(/node_params/).length).to eq(3)
    end
  end

  describe "the writers (there are none left in server/app)" do
    # IMP-19843220ac68 retired the column: both application writers were
    # stopped in the same change that made it nullable with a NULL default.
    # This example is the inverse of the one it replaces, which asserted the
    # pool service created each member with `lifecycle_class:
    # pool.lifecycle_class`. The DB half — default gone, nil on create — is
    # pinned by spec/models/system/node_lifecycle_class_retirement_spec.rb.
    it "has the pool service creating each member Node without a lifecycle class" do
      src = self.class.read(ext_root, "server/app/services/system/instance_pool_service.rb")
      create = src[/::System::Node\.create!\((.*?)\n      \)/m, 1]
      expect(create).not_to be_nil, "member constructor not found — this check is vacuous"
      expect(create).not_to include("lifecycle_class")
      # PRESENCE half: the pool stays reachable from the member, which is what
      # makes dropping the copy safe rather than merely tidy.
      expect(create).to include('"instance_pool_id" => pool.id')
    end

    it "constrains a pool to ephemeral|spot, and a Node to those plus persistent" do
      pool = self.class.read(ext_root, "server/app/models/system/instance_pool.rb")
      node = self.class.read(ext_root, "server/app/models/system/node.rb")
      expect(pool[/LIFECYCLE_CLASSES = %w\[([^\]]+)\]/, 1].split).to eq(%w[ephemeral spot])
      expect(node[/LIFECYCLE_CLASSES = %w\[([^\]]+)\]/, 1].split).to eq(%w[persistent ephemeral spot])
    end

    # The enumeration that keeps the docs' "no path sets it" sentence honest. A
    # NEW writer reddens this and sends the author back to the prose.
    #
    # Balanced-paren over the ARGUMENT LIST, not a file-level co-occurrence
    # test: the first draft of this example was file-level and named
    # system_fleet_tool.rb, which contains a `System::Node.create!` and a
    # `lifecycle_class:` that are in different methods and have nothing to do
    # with each other. `create_node` merges a six-field `params.slice` and sets
    # the column on nothing. That parse is also why the RETIREMENT comments now
    # sitting above both former writers — which name the column in prose — do
    # not read as writes: they are outside the argument list.
    it "has no System::Node writer of the column left in server/app" do
      scanned = Dir.glob(File.join(ext_root, "server/app/**/*.rb")).sum do |f|
        self.class.node_create_arguments(File.read(f)).length
      end
      expect(scanned).to be > 0, "no System::Node.create! sites found — this check is vacuous"

      files = Dir.glob(File.join(ext_root, "server/app/**/*.rb")).select do |f|
        self.class.node_create_arguments(File.read(f)).any? { |a| a.include?("lifecycle_class:") }
      end
      expect(files.map { |f| f.sub("#{ext_root}/", "") }.sort).to eq([])

      # Named individually: the orchestrator wrote the literal "persistent" —
      # the old DB default, so it moved no observable — and a revert of that
      # one line specifically must be reported by name, not as a count.
      orch = self.class.read(ext_root, "server/app/services/system/platform_deployment_orchestrator.rb")
      orch_args = self.class.node_create_arguments(orch)
      expect(orch_args).not_to be_empty, "orchestrator constructor not found — this check is vacuous"
      expect(orch_args.select { |a| a.include?("lifecycle_class:") }).to be_empty
    end

    # The `create!` scan above cannot see an `assign_attributes` writer, and
    # there IS one: db/seeds/example_multi_tenant.rb builds Nodes through
    # find_or_initialize_by + assign_attributes. It is why the docs say no API
    # SURFACE sets the column rather than "only the pool service writes it" —
    # a seed writes it directly, and a coarser claim would have been false.
    #
    # Pinned as a value, not just a location: the helper defaults to the DB
    # default and both call sites take the default, so no seeded Node is
    # non-persistent. A caller passing ephemeral here would redden this.
    it "has one seed writer, defaulted to persistent, with no caller overriding it" do
      files = Dir.glob(File.join(ext_root, "server/db/seeds/**/*.rb")).select do |f|
        src = File.read(f)
        src.match?(/System::Node\.(create!|new|find_or_create_by!?|find_or_initialize_by)/) &&
          src.include?("lifecycle_class")
      end
      expect(files.map { |f| f.sub("#{ext_root}/", "") }).to eq(%w[server/db/seeds/example_multi_tenant.rb])

      seed = self.class.read(ext_root, "server/db/seeds/example_multi_tenant.rb")
      expect(seed).to include('def ensure_node!(account:, name:, node_template:, lifecycle_class: "persistent")')
      call_sites = seed.scan(/^\s*\w+ = ensure_node!\(([^)]*)\)/).flatten
      expect(call_sites.length).to eq(2)
      expect(call_sites.select { |a| a.include?("lifecycle_class") }).to be_empty
    end
  end

  # The premise under the withdrawn "right hint to the agent" sentence. If
  # someone implements the reconciler short-circuit, the agent tree gains the
  # token, this reddens, and the withdrawal notice is exactly what to revisit.
  # Positive-absence over the whole agent tree rather than a pinned filename,
  # because the producer could land anywhere in it.
  describe "the Go agent (why it is not a 'hint to the agent')" do
    it "never mentions lifecycle_class" do
      hits = Dir.glob(File.join(ext_root, "agent/**/*.go")).select do |f|
        File.read(f).match?(/lifecycle_class|LifecycleClass/)
      end
      expect(hits.map { |f| f.sub("#{ext_root}/", "") }).to be_empty
    end
  end

  describe "GitOps has no node kind" do
    it "rejects any kind but the six ApplyService dispatches" do
      src = self.class.read(ext_root, "server/app/services/system/gitops/apply_service.rb")
      body = src[/def apply_diff\(kind:, change:, diff:\)(.*?)\n      end\n/m, 1]
      expect(body.scan(/kind == "(\w+)"/).flatten)
        .to eq(%w[template module assignment pool platform provider_config])
      expect(body).to include("raise UnsupportedDiffError")
    end

    it "does not allow a `nodes:` top-level key in fleet.yaml" do
      expect(System::Gitops::DesiredStateValidator::ALLOWED_TOP_LEVEL)
        .to eq(%w[templates assignments modules provider_configs pools platforms fleet])
    end
  end

  # --- docs -----------------------------------------------------------------

  describe NodeLifecycleClassDocs::MATRIX do
    let(:doc) { self.class.read(ext_root, NodeLifecycleClassDocs::MATRIX) }

    it "carries the canonical account of how lifecycle_class is actually set" do
      # Line-anchored on the HEADING, because the squished-text form of this
      # pattern survived a mutation: renaming the section still passed, since
      # the four cross-references elsewhere in the file quote the same phrase.
      # A pointer is not the thing it points at.
      expect(doc.lines.grep(/\A### How `lifecycle_class` is actually set\s*\z/).length).to eq(1)
      expect(self.class.absent(doc, [
        /nullable with no default/,
        /`System::InstancePool`/,
        /provision_warming_member!/,
        /InstancePoolReplenisherJob/,
        /Nothing reads it/,
        # The pairing is the whole point of the change: a reader who takes
        # "stop the writes" without "remove the default" reintroduces the bug.
        /removing the default in the same change/
      ])).to be_empty
    end

    # A3 from review: the brief called this line an accurate caveat and it was
    # not — "the right hint to the agent" claims a delivery channel that does
    # not exist. Its replacement survived a mutation until this pin was added.
    it "withdraws the 'right hint to the agent' claim rather than softening it" do
      expect(self.class.absent(doc, [ /It is not a hint to anything/ ])).to be_empty
      expect(self.class.unmarked_sites(doc, /is the right hint to the agent/)).to be_empty
    end

    # Each pair is CONTAINMENT + PRESENCE. Containment alone passes if the
    # passage is deleted; presence alone passes if the marker is dropped.
    {
      "the console update! recipe" => /Node\.update!\(lifecycle_class/,
      "the 'set it via UI or MCP' bullet" => /Set Node\.lifecycle_class/,
      "the ephemeral-worker assignment" => /Node\.lifecycle_class = "ephemeral"/
    }.each do |label, pattern|
      it "keeps #{label} visible but marked WITHDRAWN" do
        expect(self.class.code_site_count(doc, pattern)).to be > 0,
                                                            "#{pattern.inspect} survives only as a withdrawal-table row — the passage an " \
                                                            "operator reads has been deleted, and this containment check is vacuous"
        expect(self.class.unmarked_sites(doc, pattern)).to be_empty
      end
    end

    # M1 from review. The three containment patterns above all name `ephemeral`
    # or an imperative; NONE matches `Node.lifecycle_class = "persistent"`. So
    # the two sites whose value was the old DB default carried nothing but a
    # parenthetical, and deleting that parenthetical reddened nothing — leaving
    # a bare `Node.lifecycle_class = "persistent"` under a **Setup** heading,
    # which is an instruction again. Classifying them as descriptions is what
    # left them unpinned, so the annotation itself is what gets pinned. The
    # annotation's WORDING moved with IMP-19843220ac68 — "DB default" became
    # "retired column", because there is no default any more and a pin that
    # keeps mandating the old phrasing would keep a false claim in the doc.
    {
      "the Use Case 7 persistent assignment" => [
        /^\s*Node\.lifecycle_class = "persistent"/, /retired column — nothing to set/
      ],
      "the Use Case 2 persistent bullet" => [
        /^\/\/\s*- lifecycle_class: persistent/, /retired column — not settable, nothing to do/
      ]
    }.each do |label, (site, annotation)|
      it "keeps #{label} annotated as a default, not a step" do
        offenders = doc.lines.each_with_index.filter_map do |line, i|
          next unless line.match?(site)

          line.match?(annotation) ? nil : "#{i + 1}: #{line.strip[0, 100]}"
        end
        expect(self.class.match_count(doc, site)).to be > 0,
                                                     "#{site.inspect} matches nothing — this check is vacuous"
        expect(offenders).to be_empty
      end
    end

    it "explains the decision tree as a map, not a set of settings" do
      expect(self.class.absent(doc, [
        /it maps a use case to a class, not a setting you apply/
      ])).to be_empty
    end
  end

  describe NodeLifecycleClassDocs::MCP_REF do
    let(:doc) { self.class.read(ext_root, NodeLifecycleClassDocs::MCP_REF) }

    # MECHANICAL, not a pin on the one row we know about: every catalog row
    # whose first cell is a `system_*` verb this tool declares and that promises
    # a "(filter by ...)" list must name only parameters the verb declares.
    #
    # Anchored on the PROMISE SHAPE, not on the mere appearance of a parameter
    # name. The first draft flagged any row mentioning lifecycle_class, which
    # made the CORRECTED row — the one that says there is no such filter — an
    # offender: a check that cannot tell a promise from its denial reddens on
    # its own fix. Limit, stated: it sees only this catalog's "(filter by ...)"
    # phrasing; a promise written as free prose is invisible to it, which is
    # what the targeted pin below covers for the one row we know regressed.
    it "promises only filters the verb actually declares" do
      defs = Ai::Tools::SystemFleetTool.action_definitions
      offenders = doc.lines.each_with_index.flat_map do |line, i|
        verb = line[/\A\|\s*`(system_\w+)`\s*\|/, 1]
        next [] unless verb && defs.key?(verb)

        claimed = line[/\(filter by ([^)]*)\)/, 1]
        next [] unless claimed

        declared = defs.fetch(verb).fetch(:parameters).keys.map(&:to_s)
        self.class.claimed_params(claimed).reject { |t| declared.include?(t) }
            .map { |t| "#{i + 1}: #{verb} promises a `#{t}` filter; declares #{declared.inspect}" }
      end
      expect(offenders).to be_empty
    end

    it "names template_id as the only system_list_nodes filter" do
      row = doc.lines.find { |l| l.start_with?("| `system_list_nodes`") }
      expect(row).not_to be_nil
      expect(row).to include("template_id")
      expect(row).to match(/only filter/i)
    end
  end

  describe NodeLifecycleClassDocs::GITOPS do
    let(:doc) { self.class.read(ext_root, NodeLifecycleClassDocs::GITOPS) }

    # The strongest oracle available here: run the REAL validator over the
    # doc's ACTUAL bytes, and require the note beside the block to name
    # exactly the keys it rejects. Equality, not containment — a note that
    # over-claims is as wrong as one that under-claims, and either direction
    # reddens when the example or the schema moves.
    it "names exactly the top-level keys the real validator rejects" do
      block = doc[/^```yaml\n(.*?)^```/m, 1]
      expect(block).not_to be_nil, "no fleet.yaml block found — this check would be vacuous"

      raw = YAML.safe_load(block, permitted_classes: [ Symbol, Date, Time ], aliases: true)
      result = System::Gitops::DesiredStateValidator.call(raw)
      rejected = result.errors.select { |_k, v| v.any? { |m| m.include?("unknown top-level key") } }.keys.sort

      note = doc[/> \*\*Schema note.*?\n(?:>.*\n)*/]
      expect(note).not_to be_nil, "no schema note beside the fleet.yaml block; the validator rejects #{rejected.inspect}"

      named = note.scan(/`(\w+):`/).flatten.sort
      expect(named).to eq(rejected)
    end

    it "marks the nodes block's lifecycle_class as unsupported rather than teaching it" do
      pattern = /^\s+lifecycle_class: \w+$/
      expect(self.class.match_count(doc, pattern)).to be > 0,
                                                      "no YAML lifecycle_class line — this containment check is vacuous"
      expect(self.class.absent(doc, [
        /there is no `node` kind/,
        /Node's `lifecycle_class` is not GitOps-declarable/
      ])).to be_empty
    end
  end
end
