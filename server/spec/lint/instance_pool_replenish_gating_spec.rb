# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-714ab7da6b9c — the instance-pool GATING ASYMMETRY, made executable.
#
# WHAT THE FINDING WAS. `System::Executors::InstancePool::ReplenishPool` is a
# complete, tested deferred-operation executor that nothing constructs: no
# source site anywhere sets `executor_class` to it. Its siblings CreatePool and
# DeletePool DO have producers, in the same controller. So the two cheap
# instance-pool verbs route through the human-approval gate and the expensive
# one — replenish, which provisions VMs and mints `ephemeral`/`spot` Nodes —
# does not, and is additionally driven unattended by
# `System::InstancePoolReplenisherJob`, a 60 s Sidekiq cron
# (worker/config/sidekiq.yml) that POSTs the replenish route for every
# active/draining pool.
#
# WHAT THE ANSWER IS. Ungated is the DECISION, not the defect, and the decision
# was already recorded one file away:
# System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES maps
# "system.instance_pool_replenish" => "auto_approve" ("tops up to target —
# routine"). A replenish tick is idempotent and bounded twice — by `target_size`
# and again by the `max_size` headroom cap — so it cannot exceed the capacity
# ceiling standing on the pool, and a require_approval gate on a 60 s unattended
# cron would park one approval per pool per minute and stall replenishment for
# every active pool: an availability decision wearing a control's clothes.
#
# WHAT THAT ARGUMENT DOES *NOT* SAY, because an earlier draft of this very file
# said it and it is false. It does NOT say "the ceiling was already approved at
# pool-create time". Two things break that:
#   * InstancePoolsController#update is ungated and its update_params permit
#     :target_size, :max_size AND :status — so the ceiling can be raised with no
#     approval, and PATCH status:"archived" reproduces the GATED destroy.
#   * #create is gated on the REST route ONLY. SystemFleetTool's sole
#     declaration carrying action_category/executor_class/gate_context/on_proceed
#     is system_terminate_instance, so BaseTool#gated_action? is false for every
#     pool verb: a pool minted through system_create_instance_pool never passed
#     an approval at all.
# The honest form of the reason is bounded-and-unattended, not already-approved.
# If instance-pool spend is to be gated, #update is the verb worth gating.
#
# WHY A GUARD AND NOT JUST A COMMENT. The rationale above is a MATCHED PAIR:
# prose in three files that is true only while the mechanism underneath it
# holds. This platform has already been bitten by the truthful half of such a
# pair expiring silently. So the mechanism is pinned here as equalities, and
# the prose is pinned as region-scoped PRESENCE. If someone wires a producer
# for ReplenishPool, or gates the replenish action, or adds a fourth surface
# that reaches InstancePoolService.replenish!, this file reds and the prose has
# to be revisited in the same change rather than rotting into a lie.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO. It does not assert that replenish
# SHOULD stay ungated — that is an operator decision, recorded, not derived. It
# asserts only that the code and the written reason still describe each other.
#
# KNOWN LIMITS, recorded rather than pretended away:
#   * The worker's cron reaches replenish over HTTP, not by a Ruby call. No
#     source scan can see that edge; it is named in the prose the presence
#     examples require, which is the only enforcement available here.
#   * SCAN SCOPE is every Rails root in this checkout that exists — core
#     server/, worker/, and each extensions/*/server (private ones included) —
#     so a producer added in a sibling tree reds this too. A checkout that does
#     not contain a given root simply has nothing scanned there; the
#     non-vacuity example below asserts the roots actually resolved.
#   * A producer that composes the executor name at runtime
#     (`"System::Executors::InstancePool::#{verb}"`) is caught by the mention
#     census below (the literal PREFIX still appears) but one assembled from
#     fragments, or read from a database row, is not. The migration precedent
#     for a DB-side rewrite is
#     db/migrate/20260819120000_rewrite_device_scoped_grant_revoke_operations.rb,
#     which does exactly that for the SDWAN executors — so this is a real
#     mechanism in this tree, not a hypothetical.
#   * The replenish census matches a RECEIVER-AGNOSTIC `.replenish!`, not a
#     literal `InstancePoolService.replenish!`, because a variable receiver
#     (`replenisher = InstancePoolService.new(...); replenisher.replenish!`) is
#     invisible to the constant form — db/seeds/example_instance_pool.rb is
#     exactly that shape and was missed by the first draft of this guard.
#   * Comment lines are skipped by every scanner here on purpose: this file and
#     the three files it pins all quote the forbidden shapes while explaining
#     them, and a guard that trips on its own documentation is a guard someone
#     deletes.
module InstancePoolReplenishGatingGuard
  # spec/lint/<this file> -> extensions/system/server
  EXT_ROOT = Pathname.new(File.expand_path("../..", __dir__))

  # extensions/system/server -> extensions/system -> extensions -> <checkout>
  WORK_ROOT = EXT_ROOT.parent.parent.parent

  # Every Rails root in this checkout, not just this extension's. The claim the
  # prose makes is "nothing ANYWHERE names ReplenishPool", and a guard that
  # reads one tree cannot pin that: a producer in core server/, in worker/, or
  # in a private extension would leave a single-tree scan green while the
  # comment says the opposite.
  SCAN_ROOTS = (
    [ WORK_ROOT.join("server"), WORK_ROOT.join("worker") ] +
    Dir.glob(WORK_ROOT.join("extensions", "*", "server").to_s).map { |d| Pathname.new(d) } +
    Dir.glob(WORK_ROOT.join("extensions", "private", "*", "server").to_s).map { |d| Pathname.new(d) } +
    [ EXT_ROOT ]
  ).select(&:directory?).map(&:cleanpath).uniq.freeze

  SCAN_GLOBS = %w[app/**/*.rb lib/**/*.rb db/**/*.rb].freeze

  # The two verbs that route through Ai::GatedActions, and the categories they
  # pass. Restated here independently of the controller so that changing either
  # side alone reds, rather than the guard following the code.
  GATED = {
    "CreatePool" => "system.instance_pool_create",
    "DeletePool" => "system.instance_pool_delete"
  }.freeze

  # The instance-pool categories that have a POLICY ROW an operator can edit
  # and NO gate site that reads it. ReplenishPool is the one this task is
  # about; the other three are named because a census that lists only the
  # finding's own subject re-confirms the belief that opened it.
  UNGATED_CATEGORIES = %w[
    system.instance_pool_acquire
    system.instance_pool_drain
    system.instance_pool_replenish
    system.instance_pool_update
  ].freeze

  # Every source site that reaches the replenish service entry point, with why.
  # Keyed by checkout-relative path; the value is the expected occurrence count,
  # so a second call added to a file already in the census still reds.
  REPLENISH_CALLERS = {
    "extensions/system/server/app/controllers/api/v1/system/instance_pools_controller.rb" => {
      count: 1,
      why: "InstancePoolsController#replenish — the REST surface, behind " \
           "authorize_write! only (and that short-circuits on " \
           "worker_authenticated?). This is also the site the worker cron " \
           "POSTs, so it carries BOTH the operator and the unattended path."
    },
    "extensions/system/server/app/services/ai/tools/system_fleet_tool.rb" => {
      count: 1,
      why: "MCP verb system_replenish_instance_pool — declared `mutating: true` " \
           "only, so BaseTool#gated_action? (base_tool.rb:325) is false for it: " \
           "a declaration is gated only when it carries action_category, " \
           "executor_class, gate_context AND on_proceed, and on this tool only " \
           "system_terminate_instance does."
    },
    "extensions/system/server/app/services/system/executors/instance_pool/replenish_pool.rb" => {
      count: 1,
      why: "The deferred-operation executor with NO PRODUCER — the would-be " \
           "gated path. Kept deliberately; see the rationale in that file."
    },
    "extensions/system/server/app/services/system/instance_pool_service.rb" => {
      count: 2,
      why: "The implementation itself, not a surface: `def self.replenish!` " \
           "and the one-line instance delegation beneath it. Censused so that " \
           "a receiver-agnostic scanner stays honest about what it matches."
    },
    "extensions/system/server/db/seeds/example_instance_pool.rb" => {
      count: 1,
      why: "The example seed provisions real pool members through a VARIABLE " \
           "receiver (`replenisher.replenish!`), which a literal " \
           "`InstancePoolService.replenish!` grep cannot see. It is the reason " \
           "this census matches `.replenish!` receiver-agnostically."
    }
  }.freeze

  MENTION_RE   = /Executors::InstancePool::(?<klass>[A-Za-z_]\w*)?/
  CATEGORY_RE  = /action_category:\s*(?<q>["'])(?<cat>system\.instance_pool_\w+)\k<q>/
  # Receiver-agnostic on purpose — see KNOWN LIMITS above.
  REPLENISH_RE = /\.replenish!/

  def self.source_lines(rel)
    File.readlines(EXT_ROOT.join(rel))
  end

  def self.each_code_line(path)
    File.readlines(path).each_with_index do |line, idx|
      next if line.strip.start_with?("#")

      yield line, idx + 1
    end
  end

  # [[relative-path, absolute-path], ...] across every scanned root, made
  # relative to `base` so one census spans several trees without collisions.
  def self.source_files(roots = SCAN_ROOTS, base = WORK_ROOT)
    base = Pathname.new(base)
    Array(roots).flat_map { |root|
      SCAN_GLOBS.flat_map { |g| Dir.glob(Pathname.new(root).join(g).to_s) }
    }.sort.uniq.map { |abs| [ Pathname.new(abs).relative_path_from(base).to_s, abs ] }
  end

  # Non-comment mentions of a System::Executors::InstancePool::* constant.
  def self.executor_mentions(roots = SCAN_ROOTS, base = WORK_ROOT)
    source_files(roots, base).flat_map do |rel, abs|
      hits = []
      each_code_line(abs) do |line, no|
        line.scan(MENTION_RE) do
          m = Regexp.last_match
          hits << { path: rel, line: no, klass: m[:klass], source: line.strip }
        end
      end
      hits
    end
  end

  def self.replenish_callers(roots = SCAN_ROOTS, base = WORK_ROOT)
    counts = Hash.new(0)
    source_files(roots, base).each do |rel, abs|
      each_code_line(abs) { |line, _no| counts[rel] += line.scan(REPLENISH_RE).length }
    end
    counts.reject { |_k, v| v.zero? }
  end

  def self.controller_categories
    rel = "app/controllers/api/v1/system/instance_pools_controller.rb"
    cats = []
    each_code_line(EXT_ROOT.join(rel).to_s) do |line, _no|
      m = line.match(CATEGORY_RE)
      cats << m[:cat] if m
    end
    cats
  end

  # The contiguous run of comment lines immediately above `def <name>`, as one
  # string. Region-scoped on purpose: a presence check over a WHOLE FILE passes
  # as soon as the words appear anywhere in it, including in a neighbouring
  # method's rationale, which is how a "documented" claim survives the
  # documentation moving away from what it documents.
  def self.comment_block_above(lines, name)
    idx = lines.index { |l| l.match?(/\A\s*def #{Regexp.escape(name)}\s*(?:\(|$)/) }
    return nil if idx.nil?

    block = []
    i = idx - 1
    while i >= 0 && lines[i].strip.start_with?("#")
      block.unshift(lines[i].strip.sub(/\A#\s?/, ""))
      i -= 1
    end
    block.join("\n")
  end
end

RSpec.describe "instance-pool replenish gating asymmetry", type: :lint do
  guard = InstancePoolReplenishGatingGuard

  # ── the mechanism, as equalities ──────────────────────────────────────────

  it "gives exactly CreatePool and DeletePool a deferred-operation producer" do
    producers = guard.executor_mentions.group_by { |h| h[:klass] }

    expect(producers.keys.compact.sort).to eq(guard::GATED.keys.sort), <<~MSG
      The set of instance-pool executors NAMED in source changed.

      Only CreatePool and DeletePool are supposed to be reachable through
      Ai::DeferredOperation. If ReplenishPool (or DrainPool / UpdatePool) has
      just acquired a producer, that is a governance change, not a refactor:
      the rationale recorded in
        app/services/system/executors/instance_pool/replenish_pool.rb
        app/controllers/api/v1/system/instance_pools_controller.rb (#replenish)
        docs/runbooks/instance-pool-tuning.md
      now says the opposite of what the code does. Update all three in the same
      change.

      #{guard.executor_mentions.map { |h| "  #{h[:path]}:#{h[:line]}  #{h[:source]}" }.join("\n")}
    MSG

    # And no interpolated / partial mention — a composed executor name is
    # invisible to a reference grep, which is precisely how a "no producer"
    # claim goes stale in this codebase.
    composed = guard.executor_mentions.select { |h| h[:klass].nil? }
    expect(composed).to be_empty, <<~MSG
      A System::Executors::InstancePool:: constant is being composed rather
      than written out. Producer counting above cannot see through it.

      #{composed.map { |h| "  #{h[:path]}:#{h[:line]}  #{h[:source]}" }.join("\n")}
    MSG
  end

  it "gates exactly the create and delete categories in the controller" do
    expect(guard.controller_categories.sort).to eq(guard::GATED.values.sort)
  end

  it "leaves the four remaining declared categories with no gate site" do
    declared = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.keys
    ungated  = declared - guard.controller_categories

    expect(ungated.sort).to eq(guard::UNGATED_CATEGORIES.sort), <<~MSG
      The set of instance-pool action categories that have a seeded policy row
      and NO gate site has changed.

      Each of these is a control an operator can edit in the autonomy UI that
      no code path reads — the same shape
      PolicyDeclarations::RUNTIME_OPERATOR_GATED_KEYS was introduced to avoid
      (IMP-9b9653e6514e). For replenish that is a recorded, deliberate state;
      for the others it is tracked separately. Either way, changing the set is
      a governance decision that has to move the prose with it.
    MSG
  end

  it "keeps replenish declared auto_approve, which is the recorded reason" do
    expect(System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES
             .fetch("system.instance_pool_replenish")).to eq("auto_approve")
  end

  it "reaches InstancePoolService.replenish! from exactly the censused sites" do
    expect(guard.replenish_callers).to eq(
      guard::REPLENISH_CALLERS.transform_values { |v| v[:count] }
    ), <<~MSG
      A surface that performs instance-pool replenish was added, removed or
      duplicated. Every entry in REPLENISH_CALLERS carries a :why saying what
      that surface is and what gates it; add yours there with the same, or
      route it through a gate and update the rationale prose.
    MSG
  end

  it "gives every censused replenish caller a real rationale" do
    guard::REPLENISH_CALLERS.each do |path, entry|
      expect(entry[:why].to_s.length).to be > 60, "#{path}: :why must explain, not label"
    end
  end

  # ── the prose, region-scoped ──────────────────────────────────────────────
  #
  # PRESENCE, not absence. The deliverable of IMP-714ab7da6b9c is that the
  # reason replenish is ungated is WRITTEN DOWN at the places a reader actually
  # lands: the dead-looking executor, the ungated call site, and the operator
  # runbook. Each check is scoped to the region that must carry it.

  it "records at the executor why it has no producer" do
    text = File.read(guard::EXT_ROOT.join(
                       "app/services/system/executors/instance_pool/replenish_pool.rb"
                     ))

    aggregate_failures do
      expect(text).to include("IMP-714ab7da6b9c")
      expect(text).to include("NO PRODUCER")
      expect(text).to include("InstancePoolReplenisherJob")
      expect(text).to include("system.instance_pool_replenish")
      expect(text).to include("auto_approve")
      # The correction that cost this task a review round: create is gated on
      # the REST route ONLY, so "already approved at pool-create time" is not
      # the reason. Pinned so the weaker claim cannot creep back.
      expect(text).to include("REST route ONLY")
    end
  end

  it "records at the ungated call site why it is ungated" do
    lines = guard.source_lines(
      "app/controllers/api/v1/system/instance_pools_controller.rb"
    )
    block = guard.comment_block_above(lines, "replenish")

    expect(block).not_to be_nil, "InstancePoolsController#replenish not found"

    aggregate_failures do
      expect(block).to include("IMP-714ab7da6b9c")
      expect(block).to include("system.instance_pool_replenish")
      expect(block).to include("InstancePoolReplenisherJob")
      expect(block).to include("ReplenishPool")
      expect(block).to include("gated on THIS route only")
    end
  end

  it "records the asymmetry in the operator runbook" do
    doc = guard::EXT_ROOT.join("..", "docs", "runbooks", "instance-pool-tuning.md")
    expect(File.exist?(doc)).to be(true), "instance-pool-tuning.md moved"

    text = File.read(doc)
    aggregate_failures do
      expect(text).to include("system.instance_pool_replenish")
      expect(text).to include("auto_approve")
      expect(text).to include("ReplenishPool")
      expect(text).to include("Gated on the REST route ONLY")
      expect(text).to include("system_create_instance_pool")
    end
  end

  # ── non-vacuity ───────────────────────────────────────────────────────────
  #
  # Every equality above is satisfied by a scanner that matches NOTHING. These
  # pin the discriminators separately, against synthetic sources and against
  # the real tree, so a glob that stops resolving or a regex broken by a
  # refactor fails HERE instead of reading as a clean tree.
  describe "the discriminators themselves" do
    it "reads the real tree, across every root it claims to cover" do
      roots = guard::SCAN_ROOTS.map(&:to_s)

      aggregate_failures do
        # The prose in replenish_pool.rb says the absence is pinned across
        # server/, worker/ and the extension trees. If a root stops resolving,
        # that claim quietly becomes single-tree — fail here instead.
        expect(roots).to include(a_string_ending_with("/extensions/system/server"))
        expect(roots.grep(%r{/server\z}).length).to be >= 1
        expect(guard.source_files.length).to be > 500
        expect(guard.executor_mentions).not_to be_empty
        expect(guard.controller_categories).not_to be_empty
        expect(guard.replenish_callers).not_to be_empty
      end
    end

    it "sees a composed executor name, and skips one that is only quoted" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "probe.rb"), <<~'RUBY')
          gate!(executor_class: "System::Executors::InstancePool::#{verb}")
          # executor_class: "System::Executors::InstancePool::ReplenishPool"
          gate!(executor_class: "System::Executors::InstancePool::DrainPool")
        RUBY

        hits = guard.executor_mentions([ dir ], dir)
        expect(hits.map { |h| h[:klass] }).to eq([ nil, "DrainPool" ])
      end
    end

    it "spans several roots in one census, keyed by base-relative path" do
      Dir.mktmpdir do |dir|
        %w[alpha beta].each do |r|
          FileUtils.mkdir_p(File.join(dir, r, "app"))
          File.write(File.join(dir, r, "app", "probe.rb"),
                     %(gate!(executor_class: "System::Executors::InstancePool::DrainPool")\n))
        end

        hits = guard.executor_mentions([ File.join(dir, "alpha"), File.join(dir, "beta") ], dir)
        expect(hits.map { |h| h[:path] }).to eq([ "alpha/app/probe.rb", "beta/app/probe.rb" ])
      end
    end

    it "counts replenish calls per file, through a variable receiver, ignoring comments" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "probe.rb"), <<~'RUBY')
          ::System::InstancePoolService.replenish!(pool: a)
          # ::System::InstancePoolService.replenish!(pool: b)
          replenisher = ::System::InstancePoolService.new(account: acct)
          replenisher.replenish!(pool: c)
        RUBY

        # 2, not 1: the variable-receiver call is exactly the shape the seed
        # uses and exactly what the literal-constant regex used to miss.
        expect(guard.replenish_callers([ dir ], dir)).to eq("app/probe.rb" => 2)
      end
    end

    it "scopes the comment block to the method immediately below it" do
      lines = <<~RUBY.lines
        # belongs to drain
        def drain
        end

        # belongs to replenish
        # second line
        def replenish
        end
      RUBY

      expect(guard.comment_block_above(lines, "replenish"))
        .to eq("belongs to replenish\nsecond line")
      expect(guard.comment_block_above(lines, "drain"))
        .to eq("belongs to drain")
      expect(guard.comment_block_above(lines, "nope")).to be_nil
    end
  end
end
