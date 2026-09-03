# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-9a5e40a21d70 (increment 1 — the ratchet) — the census of everything that
# writes System::NodeModule#current_version_id.
#
# WHY THIS EXISTS. NodeModule#promote_to_version! carried a comment calling
# itself "the platform's ONLY choke point for 'this version is now what the
# fleet runs'". That claim was false when it was written and stayed false
# through five separate readers of it. (Increment 2 of this task deleted it; the
# quote is preserved here because the shape of the mistake is the reason this
# file exists.) A self-describing control suppresses its own audit: the comment
# was exactly what a reader consulted INSTEAD of grepping the column, so each
# reader inherited the claim rather than checking it.
#
# The claim's cost is concrete. `current_version_id` is the fleet's actuator —
# every instance carrying the module converges on whatever it points at — and
# the guards that decide whether a version may become that pointer do NOT live
# in the writer. They live in System::ModulePublicationProcessor:
#
#   auto_promote?              the per-module opt-out          (processor:100)
#   promotable_artifact?       the non-empty artifact floor    (processor:102)
#                              added after the 2026-08-07 empty-erofs incident
#   core_verdict.refused?      the core-drift refusal          (processor:104)
#   deferring_batch_for        the batch-atomic hold           (processor:358)
#                              added after the core/extension promote-skew outage
#
# plus System::RestartAfterUpdate.arm!, which NodeModule#promote_to_version!
# applies itself. A writer that reaches the column by another route gets none of
# the four and, unless it goes through promote_to_version!, not the fifth either.
#
# WHAT THIS SPEC ACTUALLY FOUND. The finding that opened this task named four
# writers. Re-deriving the set from the COLUMN rather than from the finding
# turned up a fifth (ModuleVersionService#create_version) and this scanner, run
# for the first time, turned up a SIXTH (cutover_renamed_modules.rb:74) that no
# human enumeration had listed. That is the argument for a ratchet in one
# sentence: the enumeration is the part that rots, so the enumeration is the
# part that has to be executable.
#
# The fifth is gone: IMP-b7abf6c777da made #create_version mint a row without
# touching the pointer (its widest caller was the `after_update
# :auto_create_version` callback, i.e. every ordinary spec edit), and routed
# the rollback path through NodeModule#promote_to_version!. The census below is
# the FIVE that remain; the "carries no stale CENSUS entries" example is what
# forced the entry out when the write went.
#
# THE PROPERTY, stated as an EQUALITY. The set of source sites that write
# `current_version_id` (or the `current_version` association that denormalizes
# onto it) EQUALS the census below. Not "contains only known-bad ones", not "the
# known writers still exist" — equality, checked in both directions. An
# existence check over the writers you already know about cannot see a NEW one
# appearing next month, which is precisely how the fifth and sixth survived.
#
# ══ THIS IS A TRIPWIRE, NOT THE WALL ══════════════════════════════════════
#
# A source scan sees only mechanisms it greps for. Invisible to it:
#
#   * `update_columns(hash)` where the hash is built at runtime, or any
#     `send(:update!, attrs)` — the column name never appears as a literal.
#   * `update_all("current_version_id = ...")` written as a raw SQL STRING
#     rather than a keyword hash, and the string hash-rocket form
#     `update!("current_version_id" => v.id)`. (The SYMBOL rocket,
#     `:current_version_id => v.id`, IS caught.)
#   * `ActiveRecord::Base.connection.execute("UPDATE system_node_modules ...")`,
#     or a psql session, or a migration.
#   * A call whose pointer keyword sits more than KW_WINDOW lines below the verb.
#   * A call whose earlier arguments contain a `)` inside a STRING LITERAL:
#     `call_args` counts brackets without parsing strings, so it stops early and
#     the keyword after it is never seen. Note that the "finds every censused
#     writer" example below does NOT catch this — that example only re-checks the
#     writers already in the census, so a NEWLY TYPED writer spelled this way
#     passes green. The mitigation is the shell twin in
#     scripts/pattern-validation.sh, which has no bracket tracking and does catch
#     it. The two guards miss different things ON PURPOSE; neither is a superset.
#   * A writer in a private extension that is not present in this checkout. The
#     public tree is all this spec can see; the shell twin runs from the repo
#     root over `extensions/private` as well.
#
# THE STRONG FORM IS A MODEL-LAYER RUNTIME GUARD — a check inside NodeModule
# that raises in EVERY environment when the pointer moves outside the sanctioned
# seam, because that one sees the write regardless of how it was spelled. This
# spec does not replace it. It blocks the AUTHORED hazard (someone types a new
# bypass) so the runtime guard can be designed without new bypasses accumulating
# underneath it. Do not read a green run here as "the pointer is protected";
# read it as "no new bypass was typed in a shape we recognize".
#
# ══ THE CENSUS IS A POLICY CLAIM, NOT HOUSEKEEPING ════════════════════════
#
# Every entry carries a :why AND a :bypasses list naming which guards that write
# does not apply. That shape is deliberate: a one-line addition to a bare array
# of paths reads as tidying up, and gets reviewed as tidying up. An addition
# that must spell out "this write skips the artifact floor and the batch hold"
# reads as what it is.
#
# ══ WHY A NAMED MODULE AND NOT BARE CONSTANTS IN THE EXAMPLE GROUP ════════
#
# A constant assigned inside the block passed to RSpec.describe binds to the
# LEXICAL cref — Object — not to the generated example-group class. The sibling
# guard spec/lint/node_instance_config_write_seam_spec.rb defines constants with
# the SAME names (SCAN_GLOBS, VERB_RE, INPLACE_RE, ATTRS_RE, CREATE_*), and
# `node_i...` sorts before `node_m...`, so writing them bare here would silently
# redefine that spec's scanner out from under it — measured: its census dropped
# from 15 keys to 9 and its own anti-vacuity example failed. It is invisible to
# a targeted run of either file, because it needs both loaded in one process.
# Naming the module is what keeps the two guards independent.
#
# CITATION POLICY. References into files this task also edits are by METHOD or
# CONSTANT name, never a line number — a line citation added in the same commit
# that shifts the lines is wrong on arrival, which is a defect this campaign has
# already hit more than once. Line numbers appear only for files left untouched.
module NodeModuleCurrentVersionSeam
  # The five guards a promotion is supposed to pass. Symbols rather than prose
  # so a census entry cannot claim exemption from a guard that does not exist —
  # see the "names only real guards" example below.
  GUARDS = %i[
    auto_promote_optout
    artifact_floor
    core_provenance
    batch_hold
    restart_arming
  ].freeze

  # Repo-relative-path#receiver-token, never a line number — the key has to
  # survive a line shift. The receiver is path-scoped because `self` means
  # NodeModule in node_module.rb and something else everywhere else.
  CENSUS = {
    "app/models/system/node_module.rb#self" => {
      why: "THE SANCTIONED WRITER — NodeModule#set_current_version!, the atomic " \
           "dual-column update_columns, called by #promote_to_version! which adds the one " \
           "piece of policy this model owns (RestartAfterUpdate.arm!). This is the " \
           "MECHANISM; the four policy guards are its CALLER's job and live in " \
           "System::ModulePublicationProcessor. Reaching this method does not mean they ran.",
      bypasses: %i[auto_promote_optout artifact_floor core_provenance batch_hold]
    },

    "app/services/system/manifest_import_service.rb#mod" => {
      why: "BYPASS — #snapshot_version (manifest_import_service.rb:1075), reached from " \
           "#import! (:197) ONLY when `create_version: true`, which is worth stating " \
           "precisely because the reachability differs per caller. REACHED: the operator " \
           "REST route node_modules#import_manifest, which takes the flag from params " \
           "(node_modules_controller.rb:247), and MCP system_create_module with " \
           "manifest_yaml, where it DEFAULTS TO TRUE (system_fleet_tool.rb:2151). " \
           "Opt-in on MCP system_update_module, which defaults it to FALSE. " \
           "NOT reached by either CI publish path — ModulePublicationProcessor and " \
           "NativeModuleBuildOrchestrator both call #import! without the kwarg, so they " \
           "take the false default and promote through the guarded path instead. " \
           "The live X->Y move is therefore the REST route and the MCP update verb.",
      bypasses: GUARDS
    },

    "app/services/system/package_build_webhook_service.rb#mod" => {
      why: "BYPASS — #create_version (package_build_webhook_service.rb:140). Latent " \
           "TODAY only because it sits behind a non-default resolved_build_mode " \
           "(package_module_materializer.rb:450-454, which falls back to \"native\" when " \
           "the SiteSetting system.package_builds.mode is unset); the write itself is " \
           "unguarded, so it stops being latent the moment that setting changes — no code " \
           "change required, which is what makes it worse than dormant.",
      bypasses: GUARDS
    },

    "app/services/system/account_bootstrap_service.rb#m" => {
      why: "EXEMPT, not a bypass — the nil->X first-version write on an account being " \
           "created (account_bootstrap_service.rb:284, guarded `if m.current_version_id != " \
           "v.id`). There is no fleet yet, nothing is running, and there is no previous " \
           "version to skew against, so every guard below is vacuous rather than skipped. " \
           "Counting it as a bypass was obscuring the structure of the real ones.",
      bypasses: GUARDS
    },

    "db/seeds/cutover_renamed_modules.rb#self" => {
      why: "EXEMPT, not a bypass — and the writer THIS SCANNER FOUND that no manual " \
           "enumeration had. An X->nil bulk clear (cutover_renamed_modules.rb:74) that " \
           "pre-empts an FK violation immediately before the modules it points into are " \
           "destroyed (phase 3, :80). Un-serving a module about to cease existing is not a " \
           "promotion; no guard has anything to say about it. Listed because it proves " \
           "`update_all` is a mechanism really used here, which is why the scanner covers it.",
      bypasses: GUARDS
    }
  }.freeze

  # db/seeds is in scope deliberately: a seed writes the same column against the
  # same live fleet, and it is outside the app/ greps that produced the four.
  SCAN_GLOBS = %w[app/**/*.rb lib/**/*.rb db/seeds/**/*.rb].freeze

  # ── the scanner ───────────────────────────────────────────────────────────
  #
  # Shapes, enumerated rather than inferred, because a sweep that greps two of
  # three mechanisms reports the third as absent:
  #
  #   kwarg   — `x.update!(current_version: v)`, `update_columns`, `update_column`,
  #             `update_all(current_version_id: nil)`, `assign_attributes`, INCLUDING
  #             the multi-line form where the key sits on a later line. That form is
  #             not an edge case: it is how ModuleVersionService#create_version — the
  #             writer the finding missed, since removed — was spelled.
  #   inplace — `x.current_version = v` / `self.current_version_id = ...`, which
  #             mutate the loaded record for a later `save!`. (`self.` needs no rule
  #             of its own: `self` matches the receiver pattern and is reported as
  #             the receiver token "self".)
  #   attrs   — `attrs = { current_version: ... }` handed to a write verb below.
  #
  # `current_version_number` is deliberately NOT a trigger on its own. It is the
  # denormalized read-model, kept in lockstep by NodeModule's `before_save
  # :sync_current_version_number` callback; writing it alone does not move what
  # the fleet runs.
  VERB_RE = /
    (?<recv>(?:@?[A-Za-z_]\w*\.)*@?[A-Za-z_]\w*)?\.?
    \b(?<verb>update!|update|update_columns|update_column|update_all|assign_attributes)[\(\[]
  /x
  # Anchored so `current_version_number:` can never satisfy it: the colon has to
  # follow the name immediately.
  POINTER_KW = /\A\s*current_version(?:_id)?:\s|[,(]\s*current_version(?:_id)?:\s|\A\s*:current_version(?:_id)?\b/
  INPLACE_RE = /(?<recv>(?:@?[A-Za-z_]\w*\.)*@?[A-Za-z_]\w*)\.current_version(?:_id)?\s*(\|\|)?=[^=~]/
  ATTRS_RE   = /^\s*[@\w]+\s*=\s*\{\s*current_version(?:_id)?:/
  # An object-CREATION block: its body runs before the INSERT, so there is no
  # pointer to move and nothing for a promotion guard to guard.
  CREATE_VERB_RE  = /\b(find_or_create_by!?|find_or_initialize_by|create_with|new|build)\b/
  CREATE_BLOCK_RE = /#{CREATE_VERB_RE.source}.*\bdo\s*\|\s*(?<var>\w+)\s*\|/o
  CONT_BLOCK_RE   = /\A\s*\)\s*do\s*\|\s*(?<var>\w+)\s*\|/
  CREATE_LOOKBACK = 6
  # How many lines past a write verb to keep reading for its arguments. 4 covered
  # the widest multi-line call the tree has carried (the since-removed
  # ModuleVersionService#create_version write, three lines); every remaining
  # writer is single-line, and the synthetic discriminator below keeps the
  # multi-line shape pinned. A key on the fifth line is a known miss — see the
  # tripwire limits above.
  KW_WINDOW = 4

  # The argument text of the call whose open bracket sits at `start_col`, and
  # NOTHING past its close.
  #
  # A fixed n-line window was the first thing written here and it was WRONG in a
  # way that mattered: it let a later, unrelated line satisfy the keyword match,
  # so `mod.update!(current_version_number: 3)` — a legitimate write of the
  # denormalized read-model — got flagged because a `render_success(
  # current_version_id: ...)` READ two lines below fell inside the window. The
  # spec's own negative example caught it. Tracking bracket depth bounds the
  # match to the actual call.
  #
  # Known limit: a bracket inside a string or comment miscounts, truncating the
  # argument text early. That is a MISS, never a false alarm, and it is listed in
  # the tripwire limits at the top of this file along with what covers it.
  def self.call_args(lines, idx, start_col)
    depth = 1
    buf = +""
    (idx...[ idx + KW_WINDOW, lines.length ].min).each do |i|
      text = (i == idx ? lines[i][start_col..].to_s : lines[i])
      next if i != idx && text.strip.start_with?("#")

      text.each_char do |ch|
        depth += 1 if [ "(", "[" ].include?(ch)
        depth -= 1 if [ ")", "]" ].include?(ch)
        return buf if depth.zero?

        buf << ch
      end
      buf << " "
    end
    buf
  end

  def self.scan(root)
    root = Pathname.new(root)
    SCAN_GLOBS.flat_map { |g| Dir.glob(root.join(g).to_s) }.sort.flat_map do |abs|
      rel   = Pathname.new(abs).relative_path_from(root).to_s
      lines = File.readlines(abs)
      found = []
      creating = []

      lines.each_with_index do |line, idx|
        creating.pop while creating.any? && line.match?(/\A\s{0,#{creating.last[0]}}end\b/)

        # Comments are skipped on purpose: this file and node_module.rb both
        # quote the forbidden idioms verbatim while explaining them, and a guard
        # that trips on its own documentation is a guard someone deletes.
        next if line.strip.start_with?("#")

        c = line.match(CREATE_BLOCK_RE)
        if c.nil? && (c = line.match(CONT_BLOCK_RE))
          opened = lines[[ idx - CREATE_LOOKBACK, 0 ].max...idx].any? { |l| l.match?(CREATE_VERB_RE) }
          c = nil unless opened
        end
        if c
          creating << [ line[/\A\s*/].length, c[:var] ]
          next
        end

        open_var = creating.last&.last

        if (m = line.match(VERB_RE))
          arg = call_args(lines, idx, m.end(0))
          if arg.match?(POINTER_KW)
            recv = m[:recv] || "self"
            found << { path: rel, line: idx + 1, receiver: recv, shape: "kwarg", source: line.strip } unless recv == open_var
          end
        end

        if (m = line.match(INPLACE_RE))
          found << { path: rel, line: idx + 1, receiver: m[:recv], shape: "inplace", source: line.strip } unless m[:recv] == open_var
        end

        if line.match?(ATTRS_RE)
          found << { path: rel, line: idx + 1, receiver: "(attrs-hash)", shape: "attrs", source: line.strip }
        end
      end

      found.uniq { |h| [ h[:line], h[:shape] ] }
    end
  end
end

RSpec.describe "System::NodeModule#current_version_id write seam", type: :lint do
  seam = NodeModuleCurrentVersionSeam

  let(:extension_root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:hits) { seam.scan(extension_root) }
  let(:keys) { hits.map { |h| "#{h[:path]}##{h[:receiver]}" }.uniq }

  # ── the equality, both directions ─────────────────────────────────────────

  it "has no writer of current_version_id outside the census" do
    novel = hits.reject { |h| seam::CENSUS.key?("#{h[:path]}##{h[:receiver]}") }

    expect(novel).to be_empty, <<~MSG
      A new write to System::NodeModule#current_version_id.

      That column is the fleet actuator: every instance carrying the module
      converges on whatever it points at. Moving it directly skips the guards in
      System::ModulePublicationProcessor — the auto_promote opt-out, the
      non-empty artifact floor (2026-08-07 incident), the core-provenance
      verdict, the batch-atomic hold (core/extension promote-skew outage) — and,
      unless you went through #promote_to_version!, RestartAfterUpdate.arm! too.

      Route the write through the publish policy, or through
      NodeModule#promote_to_version! if you have already made the policy
      decision yourself. If you need only the mechanical dual-column write and
      have made the policy decision, that seam is NodeModule#set_current_version!.

      If it genuinely needs to be exempt, add it to CENSUS above with a :why and
      the :bypasses it really skips. Do not add a bare line — the shape of that
      list is the review.

      If the receiver is NOT a System::NodeModule, say which model it is in :why.

      #{novel.map { |h| "  #{h[:path]}:#{h[:line]}  (#{h[:receiver]}, #{h[:shape]})  #{h[:source]}" }.join("\n")}
    MSG
  end

  it "carries no stale CENSUS entries" do
    fixed = seam::CENSUS.keys - keys

    expect(fixed).to be_empty, <<~MSG
      CENSUS names writers that no longer exist (or whose file moved). Delete
      those entries — a census nobody prunes stops being a set of decisions and
      becomes a blanket allow, which is what the "only choke point" comment on
      NodeModule#promote_to_version! already was:

      #{fixed.map { |k| "  #{k}" }.join("\n")}
    MSG
  end

  it "gives every census entry a rationale and a real bypass list" do
    seam::CENSUS.each do |key, entry|
      expect(entry[:why].to_s.length).to be > 60, "#{key}: :why must explain, not label"
      expect(entry[:bypasses]).to be_an(Array), "#{key}: :bypasses must be an Array"
      expect(entry[:bypasses] - seam::GUARDS).to be_empty,
                                                 "#{key}: :bypasses names guards that do not exist: " \
                                                 "#{(entry[:bypasses] - seam::GUARDS).inspect}"
    end
  end

  # ── non-vacuity ───────────────────────────────────────────────────────────
  #
  # THE FAILURE MODE THIS SECTION EXISTS FOR: a scan that matches nothing — a
  # regex broken by a refactor, a glob that stops resolving, an enumeration that
  # degrades to the easy shapes only — passes BOTH equality examples above while
  # checking nothing whatsoever, and reads as a clean tree. Every one of those
  # states is indistinguishable from success at the assertion level, so the
  # discriminator is pinned to synthetic sources and to the real tree separately.
  describe "the discriminator itself" do
    def scan_source(body)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "probe.rb"), body)
        NodeModuleCurrentVersionSeam.scan(dir)
      end
    end

    it "flags every forbidden shape, including the multi-line kwarg" do
      shapes = scan_source(<<~RUBY).map { |h| h[:shape] }
        mod.update!(current_version_id: version.id, current_version_number: n)
        mod.update_columns(current_version_id: version.id)
        mod.update_column(:current_version_id, version.id)
        ::System::NodeModule.where(id: ids).update_all(current_version_id: nil)
        mod.assign_attributes(current_version: v)
        mod.update!(
          name: "x",
          current_version: version
        )
        mod.current_version = v
        self.current_version_id = v.id
        attrs = { current_version: v }
      RUBY

      expect(shapes.tally).to eq("kwarg" => 6, "inplace" => 2, "attrs" => 1)
    end

    it "reports `self.` in-place writes under the receiver token self" do
      hits = scan_source("self.current_version_id = v.id\n")
      expect(hits.map { |h| [ h[:receiver], h[:shape] ] }).to eq([ [ "self", "inplace" ] ])
    end

    it "does not flag a READ, the denormalized number alone, or the sanctioned call" do
      expect(scan_source(<<~RUBY)).to be_empty
        mod.promote_to_version!(version)
        mod.set_current_version!(version)
        mod.update!(current_version_number: 3)
        value = mod.current_version_id
        render_success(current_version_id: mod.current_version_id)
        ::System::NodeModule.where(current_version_id: ids)
        return false if mod.current_version_id == version.id
        self.current_version_number = number
      RUBY
    end

    # The regression the example above actually caught. A fixed n-line window
    # let a later unrelated line satisfy a write verb's keyword match; the
    # denormalized-number write on line 1 was flagged because of the READ on
    # line 3. Isolated here so the cause stays legible if it ever returns.
    it "does not let a later line satisfy an earlier call's argument match" do
      expect(scan_source(<<~RUBY)).to be_empty
        mod.update!(current_version_number: 3)
        # a comment
        render_success(current_version_id: mod.current_version_id)
      RUBY
    end

    # The creation-block skip is the one rule that can silently make the whole
    # guard vacuous, so it gets a three-way pin: it must skip the initializer, it
    # must NOT extend to a different receiver inside the same block, and it must
    # STOP at the block's end.
    it "skips a creation block, but only for its own variable and only inside it" do
      flagged = scan_source(<<~RUBY).map { |h| "#{h[:receiver]}:#{h[:line]}" }
        mod = ::System::NodeModule.find_or_create_by!(account: a, name: n) do |m|
          m.current_version = v
          other.current_version = v
        end
        mod.current_version = v2
      RUBY

      expect(flagged).to contain_exactly("other:3", "mod:5")
    end

    it "does not treat an ordinary multi-line block as a creation block" do
      expect(scan_source(<<~RUBY).map { |h| h[:receiver] }).to eq([ "m" ])
        rows.each_slice(
          10
        ) do |m|
          m.current_version = v
        end
      RUBY
    end

    # THE ANTI-VACUITY ASSERTION PROPER. Not "hits is non-empty" alone — an
    # exact set equality and the two writers that matter most by name, so a
    # scanner that degrades to finding only the easy single-line shape fails HERE
    # rather than passing the equality above with a shrunken set.
    it "reads the real tree, and finds every censused writer in it" do
      expect(hits).not_to be_empty
      expect(keys).to match_array(seam::CENSUS.keys)
      # The sanctioned writer and the most reachable remaining bypass (the
      # manifest-import snapshot behind the REST import route and the MCP
      # create verb). If either drops out, the scan degraded — it did not get
      # cleaner. (The multi-line bypass this once pinned,
      # ModuleVersionService#create_version, was REMOVED by IMP-b7abf6c777da;
      # the multi-line shape stays pinned by the synthetic example above.)
      expect(keys).to include("app/models/system/node_module.rb#self")
      expect(keys).to include("app/services/system/manifest_import_service.rb#mod")
    end

    # The sibling guard must survive this file being loaded in the same process.
    #
    # Note what this can and cannot assert. The sibling
    # (node_instance_config_write_seam_spec.rb) DOES define SCAN_GLOBS, VERB_RE
    # etc. at Object scope — that is pre-existing and not introduced here — so
    # "nothing is defined on Object" is not the property. The property is that
    # THIS file did not overwrite them, and the discriminator is a value only
    # this scanner has: our VERB_RE matches `update_all` and our POINTER_KW does
    # not exist in the sibling at all. If either shows up on Object, this file's
    # constants leaked and the sibling's scanner is now running our regexes —
    # which is exactly the failure measured while writing this (its census fell
    # from 15 keys to 9, silently, and only when both files load together).
    it "does not clobber the sibling write-seam guard's constants" do
      expect(Object.const_defined?(:POINTER_KW, false)).to be(false),
                                                          "POINTER_KW leaked to Object — this file's constants are not contained"

      if Object.const_defined?(:VERB_RE, false)
        expect(Object.const_get(:VERB_RE).source).not_to include("update_all"),
                                                         "Object::VERB_RE is THIS file's regex — the sibling guard has been clobbered"
      end

      # And our own are where they belong.
      expect(NodeModuleCurrentVersionSeam.const_defined?(:POINTER_KW, false)).to be(true)
      expect(NodeModuleCurrentVersionSeam::VERB_RE.source).to include("update_all")
    end
  end

  # ── the behavioural half ──────────────────────────────────────────────────
  #
  # The source scan proves the writers exist. This proves the consequence — or,
  # for the writer that was removed, its ABSENCE — and it asserts the MODULE'S
  # OWN COLUMN rather than any writer's return value: a service that returns a
  # NodeModuleVersion tells you nothing about whether the pointer moved, and
  # reading the return value is how a bypass looks like a success.
  describe "the consequence, executed" do
    let(:account) { create(:account) }
    let(:node_module) do
      create(:system_node_module, account: account, auto_promote: false)
    end

    # This example used to assert the opposite — that #create_version moved the
    # pointer on an opted-out module — as the executed proof of the bypass. It
    # now pins the removal (IMP-b7abf6c777da): the same call, the same column,
    # unchanged.
    it "leaves the fleet pointer alone on a module whose auto_promote opt-out is set" do
      v1 = create(:system_node_module_version, node_module: node_module, version_number: 1)
      node_module.update_columns(current_version_id: v1.id, current_version_number: 1)

      expect(::System::ModulePublicationProcessor.auto_promote?(node_module)).to be(false)

      minted = ::System::ModuleVersionService.new(node_module).create_version(changelog: "edit")

      expect(minted).to be_persisted
      expect(node_module.reload.current_version_id).to eq(v1.id)
      expect(node_module.current_version_number).to eq(1)
    end
  end
end
