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
# (worker/config/sidekiq.yml) that POSTs the replenish route for every ACTIVE
# pool. It lists active AND draining pools — draining ones for the recycle
# phase — but since IMP-cb2da06a384b it skips replenish for them, and
# InstancePoolService#replenish! refuses any non-active pool outright.
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
#   * InstancePoolsController#update USED to be ungated with update_params
#     permitting :target_size, :max_size AND :status — so the ceiling could be
#     raised with no approval, and PATCH status:"archived" reproduced the GATED
#     destroy. IMP-24daa05e7a22 gated those two transitions (a target_size or
#     max_size INCREASE under system.instance_pool_ceiling_raise, the archive
#     under system.instance_pool_archive) and left the rest of the PATCH —
#     decreases, min_size, description, regions, metadata, status
#     paused/draining — inline, by operator direction.
#   * #create was gated on the REST route ONLY, so a pool minted through
#     system_create_instance_pool never passed an approval at all.
#     IMP-067f39468350 closed that half: system_create_instance_pool and
#     system_update_instance_pool now carry the
#     action_category/executor_class/gate_context/on_proceed quartet
#     BaseTool#gated_action? reads, park under the SAME categories as the REST
#     twins, and replay through Ai::Executors::DeferredToolCall. The MCP verbs
#     that still meet no gate are delete/drain/recycle/replenish/acquire.
# The honest form of the reason is bounded-and-unattended, not already-approved,
# and IMP-067f39468350 did not change that: GitOps apply and the CI-runner
# lease still write the ceiling with no approval, so "the spend was approved
# when the pool was created" remains a claim about the OPERATOR doors rather
# than about the column. #update was the verb worth gating for spend, and both
# of its operator doors are gated now — which is still a smaller claim than
# "the ceiling is locked". CEILING_WRITERS below censuses every site that
# moves target_size/max_size/status, two of which meet no gate at all.
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

  # The verbs that route through Ai::GatedActions, and the categories they
  # pass. Restated here independently of the controller so that changing either
  # side alone reds, rather than the guard following the code.
  #
  # UpdatePool carries TWO categories because #update gates two distinct
  # transitions through one executor (IMP-24daa05e7a22): the ceiling raise and
  # the archive. A executor⇒category map with one value each could not express
  # that, and collapsing them to one category is exactly the change this guard
  # exists to make visible.
  GATED = {
    "CreatePool" => %w[system.instance_pool_create],
    "DeletePool" => %w[system.instance_pool_delete],
    "UpdatePool" => %w[system.instance_pool_ceiling_raise system.instance_pool_archive]
  }.freeze

  # The declared instance-pool categories with NO gate site that reads them.
  # ReplenishPool is the one this task is about; the other three are named
  # because a census that lists only the finding's own subject re-confirms the
  # belief that opened it.
  #
  # system.instance_pool_update is still here after IMP-24daa05e7a22: the two
  # gated PATCH transitions resolve their OWN categories, so nothing reads the
  # _update row. That is deliberate — the transitions it would have covered are
  # applied inline by operator direction.
  #
  # IMP-5a2b801f3386 took the second half of the defect off these four: they
  # are no longer SEEDED onto the operator path, so they are no longer controls
  # an operator can edit that change nothing (see
  # PolicyDeclarations::INSTANCE_POOL_OPERATOR_GATED_KEYS and
  # spec/db/seeds/system_instance_pool_operator_policies_spec.rb). They remain
  # declared, remain on Fleet Autonomy's agent-scoped set, and remain ungated —
  # which is what this census is about.
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
           "only, so BaseTool#gated_action? is false for it: a declaration is " \
           "gated only when it carries action_category, executor_class, " \
           "gate_context AND on_proceed, and on this tool only " \
           "system_terminate_instance and the two pool verbs gated by " \
           "IMP-067f39468350 (create/update) do. Replenish staying ungated is " \
           "the recorded decision this whole guard is about."
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

  # Every site in THIS extension that writes an InstancePool row, with why —
  # the ceiling half of IMP-24daa05e7a22, extended to the MCP door by
  # IMP-067f39468350. Both OPERATOR doors are gated now; the column still is
  # not immutable (GitOps apply and the CI-runner lease write it with no
  # approval), and the prose in three files says exactly that. This census is
  # what keeps that sentence honest: a further ungated writer reds here
  # instead of quietly widening the surface, the way REPLENISH_CALLERS does
  # for the actuator.
  #
  # Scoped to EXT_ROOT rather than SCAN_ROOTS on purpose: `pool.save!` in core
  # is Ai::Memory's memory POOL, a different concept, and a census that has to
  # explain its own false positives stops being read.
  CEILING_WRITERS = {
    "app/controllers/api/v1/system/instance_pools_controller.rb" => {
      count: 3,
      why: "The REST surface: gate_create!'s unsaved candidate (`InstancePool.new`), " \
           "#update's INLINE arm for everything the two gates do not cover, and " \
           "#destroy's on_proceed `update!(status: \"archived\")`. The two GATED " \
           "update transitions write through UpdatePool, not from here."
    },
    "app/services/ai/tools/system_fleet_tool.rb" => {
      count: 4,
      why: "The MCP twins, GATED since IMP-067f39468350: both declarations now " \
           "carry action_category/executor_class/gate_context/on_proceed, so " \
           "BaseTool#gated_action? is true and the write happens only on the " \
           "branch an operator decided. FOUR writes, not two — the two action " \
           "bodies (`InstancePool.create!`, `pool.update!`) plus the two " \
           "pre-park validations that mirror Ai::GatedActions: the unsaved " \
           "`InstancePool.new` candidate in create_instance_pool_gate_context " \
           "and the in-memory `pool.assign_attributes` in " \
           "instance_pool_validation_error, which reloads the row straight " \
           "back. Same shape as the controller entry above, which counts its " \
           "own gate_create! candidate."
    },
    "app/services/system/ci_runner_lease_service.rb" => {
      count: 1,
      why: "Sets target_size from configured CI-runner demand. Ungated by " \
           "design — it is a reconciler, not an operator decision — but it does " \
           "raise a ceiling the replenish tick then spends up to."
    },
    "app/services/system/executors/instance_pool/create_pool.rb" => {
      count: 1,
      why: "The GATED create's executor — the only writer on that path, and the " \
           "shape the ceiling raise now copies."
    },
    "app/services/system/executors/instance_pool/update_pool.rb" => {
      count: 1,
      why: "The GATED update's executor, live since IMP-24daa05e7a22. Its " \
           "replay_baseline_attributes refuse a raise whose premise expired " \
           "between park and approval."
    },
    "app/services/system/fleet/sensors/instance_status_sensor.rb" => {
      count: 1,
      why: "Merges region_health into metadata. Touches no size column, which " \
           "is exactly why UpdatePool leaves metadata unfingerprinted: a parked " \
           "ceiling raise must not be invalidated by a sensor tick."
    },
    "app/services/system/gitops/apply_service.rb" => {
      count: 2,
      why: "GitOps sync: `InstancePool.create!` and `pool.update!(updates)` over " \
           "POOL_SCALAR_KEYS, which include target_size, min_size, max_size, " \
           "lifecycle_class and status. The MCP door system_gitops_apply_proposal " \
           "now gates under system.gitops_apply_proposal (IMP-0b4f18ae4384); the " \
           "callers that still reach apply! with no approval are " \
           "System::Gitops::Reconciler#auto_apply_proposal (under the repository's " \
           "own auto_apply opt-in) and System::Fleet::DecisionEngine#apply_gitops_drift " \
           "(under system.gitops_drift_remediate, seeded notify_and_proceed) — so a " \
           "repo commit on an auto_apply repo still raises a ceiling with no approval."
    },
    "app/services/system/instance_pool_service.rb" => {
      count: 2,
      why: "The service's own bookkeeping: last_replenished_at after a tick and " \
           "status \"draining\" from drain!. Neither raises a ceiling; censused " \
           "so a receiver-agnostic scanner stays honest about what it matches."
    },
    "db/seeds/example_instance_pool.rb" => {
      count: 2,
      why: "The example seed's assign_attributes + save! pair. Seed-time, but it " \
           "is a real writer of the size columns and reaches the model validator."
    },
    "db/seeds/powernode_dev_cell.rb" => {
      count: 2,
      why: "The dev-cell seed's assign_attributes + save! pair, same shape."
    }
  }.freeze

  MENTION_RE   = /Executors::InstancePool::(?<klass>[A-Za-z_]\w*)?/
  # Deliberately NOT anchored to `action_category:`. #update resolves its
  # category through a constant map (GATED_UPDATE_CATEGORIES) and passes it as
  # a variable, so an `action_category:`-anchored scan would read the two gated
  # transitions as absent and this guard would go on asserting the pre-fix
  # world while the code did the opposite. Any quoted system.instance_pool_*
  # literal on a non-comment line of the controller counts.
  CATEGORY_RE  = /(?<q>["'])(?<cat>system\.instance_pool_\w+)\k<q>/
  # De-anchoring CATEGORY_RE cost the guard its gate-SITE discriminator: the
  # four literals it finds are the GATED_UPDATE_CATEGORIES constant's values
  # plus create/delete's inline ones, so reverting #update's body to a bare
  # `@pool.update!(update_params)` while leaving the frozen constant in place
  # kept the category equality green. GATE_SITE_RE is the missing half —
  # region-scoped to #update's body below, so the CALL has to be there too.
  GATE_SITE_RE = /gate_update!\(/
  # Receiver-agnostic write census for the ceiling columns; see CEILING_WRITERS.
  CEILING_WRITE_RE = /\bpool\.(?:update!|assign_attributes|save!)|::System::InstancePool\.(?:create!|new)\(/
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

  def self.ceiling_writers(root = EXT_ROOT)
    counts = Hash.new(0)
    source_files([ root ], root).each do |rel, abs|
      each_code_line(abs) { |line, _no| counts[rel] += line.scan(CEILING_WRITE_RE).length }
    end
    counts.reject { |_k, v| v.zero? }
  end

  # The BODY of `def <name>` up to the matching `end` at the same indentation,
  # comments stripped. Region-scoped for the reason comment_block_above is: a
  # whole-file presence check for "gate_update!" passes as soon as the words
  # appear anywhere, including in the rationale explaining what was gated.
  def self.method_body(lines, name)
    idx = lines.index { |l| l.match?(/\A\s*def #{Regexp.escape(name)}\s*(?:\(|$)/) }
    return nil if idx.nil?

    indent = lines[idx][/\A\s*/]
    body = []
    i = idx + 1
    while i < lines.length
      break if lines[i] == "#{indent}end\n" || lines[i].rstrip == "#{indent}end"

      body << lines[i] unless lines[i].strip.start_with?("#")
      i += 1
    end
    body.join
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

  it "gives exactly CreatePool, DeletePool and UpdatePool a deferred-operation producer" do
    producers = guard.executor_mentions.group_by { |h| h[:klass] }

    expect(producers.keys.compact.sort).to eq(guard::GATED.keys.sort), <<~MSG
      The set of instance-pool executors NAMED in source changed.

      Only CreatePool, DeletePool and UpdatePool are supposed to be reachable
      through Ai::DeferredOperation. If ReplenishPool or DrainPool has just
      acquired a producer, that is a governance change, not a refactor:
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

  it "gates exactly the create, delete, ceiling-raise and archive categories in the controller" do
    expect(guard.controller_categories.sort).to eq(guard::GATED.values.flatten.sort)
  end

  it "keeps the gate CALL in #update, not just the category constant" do
    lines = guard.source_lines(
      "app/controllers/api/v1/system/instance_pools_controller.rb"
    )
    body = guard.method_body(lines, "update")

    expect(body).not_to be_nil, "InstancePoolsController#update not found"

    aggregate_failures do
      expect(body).to match(guard::GATE_SITE_RE), <<~MSG
        InstancePoolsController#update no longer calls gate_update!.

        The category equality above cannot see this: it scans for quoted
        system.instance_pool_* literals, and GATED_UPDATE_CATEGORIES supplies
        two of them from a frozen constant whether or not anything reads it.
        So a revert of #update's body to a bare `@pool.update!(update_params)`
        leaves that example green and the ceiling ungated. This one is the
        presence half.
      MSG

      # And the call must take its category FROM that constant, not from a
      # freshly inlined literal that happens to match.
      expect(body).to include("action_category: categories.first"), <<~MSG
        #update's gate_update! no longer resolves its category through
        gated_update_categories/GATED_UPDATE_CATEGORIES. Two transitions gate
        under two categories precisely so relaxing one policy row does not
        carry the other through; a single inlined literal collapses that.
      MSG
    end
  end

  it "censuses every site that writes an instance-pool row" do
    expect(guard.ceiling_writers).to eq(
      guard::CEILING_WRITERS.transform_values { |v| v[:count] }
    ), <<~MSG
      A writer of System::InstancePool was added, removed or duplicated.

      IMP-24daa05e7a22 gated a ceiling raise on the REST route and
      IMP-067f39468350 gated the MCP twins. The prose in
        app/controllers/api/v1/system/instance_pools_controller.rb (#replenish)
        app/services/system/executors/instance_pool/replenish_pool.rb
        docs/runbooks/instance-pool-tuning.md
      says exactly that, and names the two writers that still move
      target_size/max_size/status with no gate (GitOps apply, the CI-runner
      lease). If this census changed, that list changed: add yours to
      CEILING_WRITERS with a :why, or gate it and correct all three files in
      the same change.
    MSG
  end

  it "gives every censused ceiling writer a real rationale" do
    guard::CEILING_WRITERS.each do |path, entry|
      expect(entry[:why].to_s.length).to be > 60, "#{path}: :why must explain, not label"
    end
  end

  it "leaves the same four declared categories with no gate site" do
    declared = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES.keys
    ungated  = declared - guard.controller_categories

    expect(ungated.sort).to eq(guard::UNGATED_CATEGORIES.sort), <<~MSG
      The set of DECLARED instance-pool action categories with NO gate site has
      changed.

      These four carry no operator-path policy row: IMP-5a2b801f3386 withdrew
      them from PolicyDeclarations::INSTANCE_POOL_OPERATOR_POLICIES, because a
      row for a category no gate site passes is a control an operator can edit
      that no code path reads — the same shape RUNTIME_OPERATOR_GATED_KEYS was
      introduced to avoid (IMP-9b9653e6514e). They remain declared and remain
      on the agent-scoped set — the Capacity Manager's since HIER-P2DECL.

      So moving a verb INTO this list means withdrawing its operator row, and
      moving one OUT (giving it a gate site) means adding it back to
      INSTANCE_POOL_OPERATOR_GATED_KEYS in the same change — pinned by
      spec/db/seeds/system_instance_pool_operator_policies_spec.rb. For
      replenish, staying ungated is a recorded, deliberate state; for the
      others it is tracked separately. Either way, changing the set is a
      governance decision that has to move the prose with it.
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
      # The correction that cost IMP-714ab7da6b9c a review round: "already
      # approved at pool-create time" is not the reason replenish may run
      # unattended. IMP-067f39468350 changed WHY — create is now gated on both
      # operator doors — without changing the conclusion, because GitOps apply
      # and the CI-runner lease still mint and raise with no approval. Pin the
      # current reason, and the remaining ungated writer by name, so neither
      # the stale "REST route ONLY" wording nor the weaker claim it replaced
      # can creep back.
      expect(text).to include("gated on BOTH DOORS")
      expect(text).to include("CiRunnerLeaseService")
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
      # IMP-067f39468350 — the ceiling gate now stands on the REST route AND
      # the MCP verb, so the old "gated on THIS route only" wording is false
      # here. What must still be written down is which door is which.
      expect(block).to include("gated on BOTH the REST route and the MCP verb")
      expect(block).to include("system_update_instance_pool")
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
      # Still true of DELETE, whose MCP verb is ungated and strictly more
      # destructive than the gated REST route — the one row where the old
      # wording is not stale.
      expect(text).to include("Gated on the REST route ONLY")
      expect(text).to include("system_create_instance_pool")
      # And the correction IMP-067f39468350 owes the table: create and the
      # ceiling raise/archive stand on both doors now.
      expect(text).to include("Gated on both doors")
      expect(text).to include("IMP-067f39468350")
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
        expect(guard.ceiling_writers).not_to be_empty
      end
    end

    it "scopes a method body to its own def, and skips comments" do
      lines = <<~'RUBY'.lines
        module A
          class B
            # gate_update!( in a comment above the wrong method
            def other
              gate_update!(action_category: "decoy")
            end

            def update
              authorize_write!
              # gate_update!( in a comment inside the right method
              gate_update!(action_category: categories.first)
            end
          end
        end
      RUBY

      body = InstancePoolReplenishGatingGuard.method_body(lines, "update")

      aggregate_failures do
        expect(body).to match(guard::GATE_SITE_RE)
        expect(body).to include("action_category: categories.first")
        expect(body).not_to include("decoy")
        # The comment INSIDE #update must not be what satisfies the match.
        expect(body.scan(guard::GATE_SITE_RE).length).to eq(1)
      end
    end

    it "counts instance-pool writes per file, ignoring comments" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "probe.rb"), <<~'RUBY')
          pool = ::System::InstancePool.create!(name: "x")
          # pool.update!(target_size: 9)
          @pool.update!(attrs)
          pool.assign_attributes(target_size: 1)
          pool.save!
          pool.destroy!
        RUBY

        # 4: create!, the two update!/assign_attributes and save! — the
        # comment and the destroy! are not ceiling writes.
        expect(guard.ceiling_writers(dir)).to eq({ "app/probe.rb" => 4 })
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
