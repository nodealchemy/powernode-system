# frozen_string_literal: true

require "spec_helper"

# IMP-e8dc40813adb — docs/tutorials/06-rolling-upgrade.md (and its siblings)
# document a supervised rollout runtime that does not exist.
#
# RollingModuleUpgradeExecutor#perform validates batch_pct, resolves the target
# version, slices instances into batches, and RETURNS. It creates no Task,
# dispatches nothing, never reads running_module_digests, and never compares a
# digest. `health_timeout_sec` is echoed into the returned circuit_breaker hash
# and read by nothing. The only reference to an advancer is the literal string
# "M7 reconciler advances batches one at a time" in the plan's own note — and
# there is no M7 reconciler.
#
# So the failure is worse than an absent safety net. An operator sizing
# batch_pct believes they are pacing a rollout; the rollout never rolls. And
# because the version an instance receives is resolved from
# NodeModule#current_version_id (see module_promotion_docs_accuracy_spec.rb),
# which is a per-MODULE pointer, batch_pct could not bound blast radius even if
# something walked the batches: moving the pointer moves it for every instance
# carrying that module at once.
#
# This guard has two halves and needs both:
#
#   1. The CODE half pins the premise — the executor plans and does not
#      actuate, and nothing else advances its plan. If someone implements the
#      runtime, these examples redden and the docs corrected here are exactly
#      the ones to restore. Without it the doc half is a spelling test.
#   2. The DOC half is a matched PAIR per file — the false promise ABSENT and
#      a truthful replacement PRESENT. Absence alone is vacuous: deleting the
#      circuit-breaker section outright would satisfy it, and leave an operator
#      with a real rollout to perform and nothing to perform it with.
#
# The CODE half needs its CONTRAST or it is untethered: "creates no Task" is
# unimpressive if no executor creates tasks. BootImageDriftRolloutExecutor is
# the same shape for boot images and DOES dispatch (UpgradeDispatcher.dispatch!
# at :98, dispatched_task_ids in its outputs), converging tick-by-tick off its
# own drift sensor rather than through a batch-advancer. It is pinned below
# both as the discriminator and as the reference contract for the module lane's
# implementation gap.
#
# What this does NOT catch: the same belief restated in wording none of these
# regexes match, in a doc not listed here, or in the frontend. It is a
# regression pin on known statements, not a semantic check.
RSpec.describe "rolling-upgrade docs vs. what RollingModuleUpgradeExecutor actually does" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # --- code: the premise the docs must be written to ----------------------

  describe "RollingModuleUpgradeExecutor" do
    let(:executor) do
      self.class.read(ext_root, "server/app/services/system/ai/skills/rolling_module_upgrade_executor.rb")
    end

    it "creates no Task and dispatches nothing — it returns a plan" do
      expect(executor).not_to match(/Task\.create!?/)
      expect(executor).not_to match(/Dispatcher\./)
    end

    it "runs no health check: it never reads a running digest nor waits on health_timeout_sec" do
      expect(executor).not_to include("running_module_digests")

      # health_timeout_sec may appear ONLY as a keyword arg, its descriptor
      # entry, and the echo into the returned hash. Any comparison, sleep, or
      # deadline arithmetic on it would be the health gate the docs promise.
      expect(executor).not_to match(/health_timeout_sec\s*[<>]/)
      expect(executor).not_to match(/(?:sleep|deadline|wait_until|Timeout)/)
    end

    it "does not describe itself as dispatching, nor promise an advancer that exists" do
      # The class header said "Plan + dispatch"; :123's note said "M7 reconciler
      # advances batches one at a time". Both are the finding, in the two
      # places a caller reads before trusting the plan.
      expect(executor).not_to match(/Plan \+ dispatch/)
      expect(executor).not_to match(/M7 reconciler advances batches/)
    end

    # IMP-b948ea7fa382 — the contract removal, pinned at the SOURCE rather
    # than only through .descriptor (which the executor spec asserts by
    # equality). This catches a reintroduction in the perform signature or a
    # local default constant, neither of which the descriptor would show.
    it "accepts no batch_pct anywhere: not as an input, a keyword, or a default" do
      expect(executor).not_to match(/batch_pct:/)
      expect(executor).not_to match(/DEFAULT_BATCH_PCT/)
    end

    it "returns one atomic affected set rather than a batch structure" do
      expect(executor).to include("affected_instance_ids")
      expect(executor).not_to match(/each_slice/)
      expect(executor).not_to match(/batch_size|batch_count/)
    end

    it "states in its skill_descriptor that it plans only" do
      # The descriptor description is what an AGENT reads BEFORE calling, so
      # the plan/execute split has to be stated there too — correcting it only
      # in prose teaches a human and leaves the agent surface lying. Same
      # reasoning as system_promote_module_version's descriptor (IMP-65bea54e4081,
      # system_fleet_tool.rb:873), which is purely additive truth-telling and
      # disables no mechanism.
      descriptor = executor[/skill_descriptor\(.*?\n        \)/m] ||
                   raise("could not locate skill_descriptor in rolling_module_upgrade_executor.rb")

      # IMP-a699af087f5d — "no batch advancer" / "nothing advances" were
      # dropped as legal alternatives here. They are the conceding formulation
      # this file forbids in the docs (denying the ADVANCER concedes the
      # batches), so leaving them in the alternation licensed a future editor
      # to REPLACE the fleet-atomic descriptor text with expired wording and
      # stay green.
      expect(descriptor).to match(/NOT executed|not executed/)
      # And it must stop advertising gating it does not perform.
      expect(descriptor).not_to match(/with circuit-breaker and health gating/)
    end
  end

  describe "the rest of the extension" do
    # Scoped to shipped Ruby under server/app + server/lib. Deliberately NOT a
    # tree sweep: docs are allowed to name these (they now name them as NOT
    # IMPLEMENTED), and specs are allowed to assert their absence.
    let(:ruby_sources) do
      Dir.glob(File.join(ext_root, "server/{app,lib}/**/*.rb")).sort
    end

    # IMP-b948ea7fa382 — the M7 sweep below runs over a WIDER tree than the
    # two above it. Those two hunt for a runtime, which could only live in
    # server/{app,lib}. A deferral comment is a claim, and a claim misleads
    # wherever a reader meets it: the seeds are operator-facing by this
    # file's own argument (see example_rolling_upgrade.rb below — "an operator
    # running the seed reads its stdout as the authority"), and the worker
    # jobs are where a reader would go looking for the tick that supposedly
    # drives the reconciler. All three trees are clean today, so the wider
    # glob costs nothing and closes the hole before someone fills it.
    let(:shipped_sources) do
      Dir.glob(File.join(ext_root, "{server/{app,lib,db/seeds},worker/app}/**/*.rb")).sort
    end

    it "contains no batch advancer, circuit breaker, or continuation handler for module upgrades" do
      vocabulary = /circuit_breaker_tripped|rollback_completed_batches|continue_anyway|rolling_upgrade_continuation/
      offenders = ruby_sources.select { |f| File.read(f).match?(vocabulary) }

      expect(offenders).to be_empty
    end

    it "emits none of the module.upgrade.* events the docs tell an operator to poll for" do
      offenders = ruby_sources.select { |f| File.read(f).include?("module.upgrade.") }

      expect(offenders).to be_empty
    end

    # IMP-b948ea7fa382 — the ghost, swept.
    #
    # "M7" was a milestone in the Golden Eclipse plan, and naming it as
    # PROVENANCE is fine and stays legal here: "Reference: Golden Eclipse plan
    # M7 — <thing>" appears on FleetAutonomyService, DecisionEngine, the
    # reconcile controller and the channel, and each of those things exists.
    # What is banned is the other use — DEFERRING behaviour to it. Two files
    # did that, and each deferral hid a false success:
    # RollingModuleUpgradeExecutor promised an advancer ("M7 reconciler
    # advances batches one at a time"), and DriftRemediateExecutor returned
    # `resolved: !requires_approval` under the note "auto-apply pending M7
    # reconciler". ScaleProjectExecutor then repeated the first one verbatim
    # while surfacing that same plan, which is why an absence check on ONE
    # file was not enough.
    #
    # A comment deferring to unbuilt infrastructure reads to the next reader
    # as a pending dependency owned by somebody else. There is no M7 owner.
    it "defers no behaviour to an 'M7' that was never built" do
      deferral = /
        M7\ (?:reconciler|will|owns|milestone\ will|ApprovalRequest)  # names it as the actor
        |
        (?:pending|until|awaiting|waiting\ on|blocked\ on|deferred\ to|lives\ in)\ M7  # as the blocker
        |
        TODO\(M7                                     # the sanctioned milestone-TODO form
      /x
      offenders = shipped_sources.select { |f| File.read(f).match?(deferral) }

      expect(offenders.map { |f| f.delete_prefix("#{ext_root}/") }).to be_empty
    end
  end

  # IMP-b948ea7fa382 — the second caller. ScaleProjectExecutor surfaces this
  # same plan as outputs.rolling_upgrade_plan, and its comment used to explain
  # the plan-only shape as deliberate by naming the reconciler that would walk
  # the batches. The M7 sweep above is ABSENCE-only, and this file's own header
  # argues absence alone is vacuous — deleting the comment outright would
  # satisfy it and leave the next reader with no warning at all. So pin the
  # replacement here.
  describe "ScaleProjectExecutor#run_vertical_resize (the second caller of the plan)" do
    let(:scale) do
      self.class.read(ext_root, "server/app/services/system/ai/skills/scale_project_executor.rb")
    end

    it "warns that nothing executes the plan it surfaces, rather than explaining it away" do
      comment = scale[/# vertical_resize produces a plan only.*?def run_vertical_resize/m] ||
                raise("could not locate the run_vertical_resize preamble in scale_project_executor.rb")

      expect(comment).to match(/NOTHING EXECUTES IT/i)
      expect(comment).to match(/no batch advancer|there is no batch advancer/i)
      # IMP-a699af087f5d — the require above is a LATENT expired-require of the
      # kind this file already documents for "nothing walks the batches". On
      # its own, "there is no batch advancer" concedes that batches exist and
      # implies that building an advancer would finish the story; after the
      # 2026-08-30 fleet-atomic decision it is the misleading half of the pair.
      # IMP-b948ea7fa382 appended the correction to the comment
      # (scale_project_executor.rb:513-515) but did not pin it, so an edit could
      # delete the fleet-atomic sentence, keep the conceding phrase, and stay
      # green. Requiring BOTH halves is what keeps the pair matched.
      expect(comment).to match(/FLEET-ATOMIC/i)
      # \s*#?\s* because the sentence wraps across a comment continuation
      # ("There are no\n        # batches to advance either"). A guard on a
      # wrapped comment must survive a harmless rewrap.
      expect(comment).to match(/there are no\s*#?\s*batches to advance/i)
      # And it must point at the procedure that does work, not just say no.
      expect(comment).to include("06-rolling-upgrade.md")
    end
  end

  # The contrast. Without this, "creates no Task" proves nothing about whether
  # actuating executors exist at all.
  describe "BootImageDriftRolloutExecutor (the same shape, implemented)" do
    let(:boot_rollout) do
      self.class.read(ext_root, "server/app/services/system/ai/skills/boot_image_drift_rollout_executor.rb")
    end

    it "does dispatch its current batch, so the module executor's silence is a real difference" do
      expect(boot_rollout).to match(/UpgradeDispatcher\.dispatch!/)
      expect(boot_rollout).to include("dispatched_task_ids")
    end

    it "converges without a batch advancer, by re-planning off its own drift sensor each tick" do
      # This is the contract the module lane is missing, and the reason the gap
      # is a design task rather than a missing loop: convergence here is
      # tick-driven, so no advancer was ever needed.
      expect(boot_rollout).to match(/tick-driven/)
    end
  end

  # --- docs: the false promise gone AND a truthful replacement present ----

  describe "docs/tutorials/06-rolling-upgrade.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/06-rolling-upgrade.md") }

    it "no longer promises health-gated batches and an automatic circuit breaker" do
      expect(doc).not_to match(/with health-check gates between batches and an automatic circuit breaker/)
      expect(doc).not_to match(/^3\. On approval, walks batches one at a time$/)
      expect(doc).not_to match(/Once approved, the autonomy reconciler picks up the plan/)
    end

    it "no longer presents batch_pct as a blast-radius control" do
      expect(doc).not_to match(/A bad version reaches at most\s*\n?`?batch_pct`? of the fleet before the circuit trips/)
    end

    # IMP-b948ea7fa382 — the matched pair moved with the decision. The old
    # truthful replacement ("nothing advances the batches") is now itself
    # misleading: it concedes there ARE batches and implies an advancer would
    # complete the story. The operator decision was that module upgrades are
    # fleet-atomic, so the honest replacement names that AND the two staging
    # mechanisms that actually exist — otherwise an operator who needs a
    # blast-radius bound is left with a "no" and no procedure.
    it "states plainly that the upgrade is fleet-atomic and that nothing executes the plan" do
      expect(doc).to match(/NOT IMPLEMENTED/)
      expect(doc).to match(/FLEET-ATOMIC/i)
      expect(doc).to match(/no version column/i)
    end

    it "names both staging mechanisms that do exist, rather than only refusing" do
      bound = doc[/^### If you need a real blast-radius bound.*?(?=^## )/m] ||
              raise("could not locate the blast-radius-bound section in 06-rolling-upgrade.md")

      expect(bound).to match(/instance pool/i)
      expect(bound).to match(/separate module row|second `NodeModule` row|two `NodeModule` rows/i)
    end

    # The removal has to be visible where a caller would COPY it. A tutorial
    # that still shows batch_pct in its invocation teaches the dead parameter
    # regardless of what the prose says two screens up.
    it "shows no batch_pct in the executor invocation it tells the operator to copy" do
      expect(doc).not_to match(/^\s*batch_pct:\s*\d+/)
    end

    it "marks the circuit breaker and all three continuation options as unimplemented" do
      # Scoped to the section, so deleting the drill and leaving the words
      # elsewhere in the file cannot satisfy it.
      section = doc[/^## Step 5 —.*?(?=^## )/m] ||
                raise("could not locate the Step 5 circuit-breaker section in 06-rolling-upgrade.md")

      expect(section).to match(/NOT IMPLEMENTED/)
      %w[continue_anyway rollback_completed_batches abort].each do |option|
        expect(section).to include(option)
      end
    end

    it "tells the operator what to do INSTEAD, naming the pointer and the verb that moves it" do
      # Deleting the promise is not enough: an operator with a real upgrade to
      # perform needs the procedure that works. current_version_id is what the
      # node-facing download resolves; system_rollback_module_version is the
      # sanctioned MCP writer of it and accepts any version of the module with
      # a mountable artifact — forward as well as backward
      # (SystemFleetTool#explicit_rollback_target imposes no direction).
      instead = doc[/^## What to do instead.*?(?=^## )/m] ||
                raise("could not locate a \"What to do instead\" section in 06-rolling-upgrade.md")

      expect(instead).to include("current_version_id")
      expect(instead).to include("system_rollback_module_version")
      expect(instead).to include("system_refresh_instance_modules")
    end

    it "says plainly that no automated bound exists, rather than implying the manual walk is one" do
      # The sharpest thing an operator can be told: the pointer is per-MODULE,
      # so the manual procedure is not a batched rollout either. Anything that
      # presented it as one would re-create the original defect by hand.
      instead = doc[/^## What to do instead.*?(?=^## )/m] ||
                raise("could not locate a \"What to do instead\" section in 06-rolling-upgrade.md")

      expect(instead).to match(/no automated bound/i)
      expect(instead).to match(/every instance carrying that module/i)
    end
  end

  describe "docs/runbooks/cve-response.md" do
    let(:doc) { self.class.read(ext_root, "docs/runbooks/cve-response.md") }

    let(:phase6) do
      doc[/^## Phase 6 —.*?(?=^## )/m] ||
        raise("could not locate Phase 6 in cve-response.md")
    end

    it "no longer says the reconciler executes the plan batch-by-batch" do
      expect(phase6).not_to match(/reconciler executes batch-by-batch/)
      expect(phase6).not_to match(/^1\. Reconciler picks N instances per the `batch_size`/)
    end

    it "marks the phase unimplemented and routes the operator to the manual procedure" do
      expect(phase6).to match(/NOT IMPLEMENTED/)
      expect(phase6).to include("06-rolling-upgrade.md")
    end
  end

  describe "docs/SKILL_EXECUTORS.md" do
    let(:doc) { self.class.read(ext_root, "docs/SKILL_EXECUTORS.md") }

    it "no longer claims the autonomy reconciler executes the plan batch-by-batch" do
      expect(doc).not_to match(/the autonomy reconciler executes it batch-by-batch, gating on health between batches/)
    end

    it "says the plan is returned and never executed, and that the upgrade is fleet-atomic" do
      section = doc[/^### `rolling_module_upgrade` — Fleet-atomic module upgrade.*?(?=^### )/m] ||
                raise("could not locate the rolling_module_upgrade section in SKILL_EXECUTORS.md")

      expect(section).to match(/NOT IMPLEMENTED/)
      expect(section).to match(/FLEET-ATOMIC/i)
      # The input list is the thing a caller copies — it must not still name
      # the removed parameter.
      expect(section).to match(/^\*\*Inputs:\*\*.*$/)
      expect(section[/^\*\*Inputs:\*\*.*$/]).not_to include("batch_pct")
      expect(section[/^\*\*Outputs:\*\*.*$/]).to include("affected_instance_ids")
      expect(section[/^\*\*Outputs:\*\*.*$/]).not_to match(/batch_size|batch_count|batches/)
    end

    # IMP-b948ea7fa382 — the file has TWO rolling_module_upgrade sections: the
    # reference entry at "### `rolling_module_upgrade` — Batched fleet upgrade"
    # and a bare "### `rolling_module_upgrade`" in the JSON appendix. The
    # example above scopes to the first, so the appendix kept the original
    # claim in slightly different words ("The autonomy reconciler executes the
    # plan batch-by-batch") — two lines under a JSON body already saying
    # "status": "not_implemented" and "PLAN ONLY". A section-scoped guard
    # inherits the coverage boundary of its heading regex.
    it "corrects the appendix section too, not just the reference entry" do
      appendix = doc[/^### `rolling_module_upgrade`\n.*?(?=^### )/m] ||
                 raise("could not locate the rolling_module_upgrade JSON appendix in SKILL_EXECUTORS.md")

      expect(appendix).not_to match(/The autonomy reconciler executes the plan batch-by-batch/)
      expect(appendix).to match(/NOT IMPLEMENTED/)
      # IMP-b948ea7fa382 — the appendix carries a copyable JSON input body, so
      # it is the likeliest place for the removed parameter to survive. The
      # heading-scoped guard above cannot see this section (bare heading), and
      # that is exactly how the previous false claim lived on here.
      expect(appendix).to match(/FLEET-ATOMIC/i)
      expect(appendix).not_to match(/"batch_pct"\s*:/)
      expect(appendix).not_to match(/"batch_size"\s*:|"batch_count"\s*:|"batches"\s*:/)
      expect(appendix).to match(/"affected_instance_ids"/)
    end
  end

  # IMP-b948ea7fa382 — two runbooks told an operator the same thing in wording
  # no M7 regex could catch: that a reconciler drives the skill in prod. Both
  # get the matched pair, since deleting the sentence would leave an operator
  # planning an upgrade with no warning that it will not run.
  # IMP-b948ea7fa382 — these two pairs originally demanded the phrases
  # "nothing walks the batches" / "no reconciler tick advances these batches".
  # Once module upgrades were accepted as fleet-atomic those replacements
  # became misleading in the same way the tutorial's was: they concede there
  # ARE batches and imply an advancer would finish the story. There are none.
  # The guard now demands the fleet-atomic replacement instead — and asserts
  # the conceding wording is GONE, so a future edit cannot drift back to it.
  describe "the runbooks that told an operator a reconciler drives the upgrade" do
    it "docs/runbooks/multi-cluster-k3s.md says the skill plans only, and returns no batches" do
      doc = self.class.read(ext_root, "docs/runbooks/multi-cluster-k3s.md")

      expect(doc).not_to match(/skill is driven by the autonomy reconciler/)
      expect(doc).not_to match(/nothing walks the batches/i)
      expect(doc).to match(/PLANS ONLY/)
      expect(doc).to match(/FLEET-ATOMIC/i)
    end

    it "docs/runbooks/k3s-smoke-full-lifecycle.md does not promise a prod reconciler tick, nor a canary batch" do
      doc = self.class.read(ext_root, "docs/runbooks/k3s-smoke-full-lifecycle.md")

      expect(doc).not_to match(/Fleet Autonomy's reconciler tick does that in prod/)
      # The smoke seed's canary-batch assertions were deleted with batch_pct;
      # this doc described them, so it had to stop.
      expect(doc).not_to match(/first\s*\n?batch is canary-sized/i)
      expect(doc).to match(/FLEET-ATOMIC/i)
      expect(doc).to match(/affected_instance_ids/)
    end
  end

  describe "server/db/seeds/example_rolling_upgrade.rb" do
    let(:seed) { self.class.read(ext_root, "server/db/seeds/example_rolling_upgrade.rb") }

    it "no longer tells the operator a reconciler will pick the plan up" do
      # An operator running the seed reads its stdout as the authority on what
      # happens next, which makes this as operator-facing as the tutorial.
      expect(seed).not_to match(/the autonomy reconciler executes batches in production/)
      expect(seed).not_to match(/To execute the plan in production, the autonomy reconciler picks up/)
    end

    it "states that nothing executes the plan" do
      expect(seed).to match(/NOT IMPLEMENTED|nothing executes/i)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # IMP-a699af087f5d — the surfaces IMP-b948ea7fa382 (iteration 554) did not
  # reach. That change corrected the executor, the two runbooks,
  # SKILL_EXECUTORS.md and the BODY of 06-rolling-upgrade.md. Six further
  # doc/seed surfaces still taught the batched/canary model, including 06's own
  # TITLE — three lines above the NOT-IMPLEMENTED banner that exists to retract
  # it. A reader who stops at the heading takes away exactly the model the
  # banner is there to withdraw.
  #
  # SCOPE POLICY for every example below: FILE-scoped by default, and the scope
  # is stated per describe block. This claim can appear as an H1, a prose
  # sentence, a table cell, a mermaid node label, a JSON body and a link's
  # anchor text — six shapes, of which a heading-scoped guard sees at most one.
  # Heading- or line-scoping is used below ONLY where a claim is genuinely
  # confined to one region AND a file-wide forbid would collide with a
  # legitimate corrective mention of the same words; each such site says so.
  # ══════════════════════════════════════════════════════════════════════

  describe "docs/tutorials/06-rolling-upgrade.md — its title and its batch concessions" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/06-rolling-upgrade.md") }

    # Anchored to the H1 specifically — not because the claim is confined
    # there, but because the title is the one line a reader can carry away
    # without ever reaching the banner three lines below it. The file-wide
    # sweeps follow.
    it "does not advertise in its H1 the canary model its own banner retracts" do
      h1 = doc[/\A# .*$/] || raise("could not locate the H1 in 06-rolling-upgrade.md")

      expect(h1).not_to match(/canary/i)
      expect(h1).not_to match(/batch/i)
      expect(h1).to match(/fleet-atomic/i)
    end

    # FILE-scoped. "Nothing advances the batches" was the TRUTHFUL half of
    # IMP-e8dc40813adb's matched pair, and accurate while the only defect was a
    # missing advancer. The 2026-08-30 fleet-atomic decision expired it: it
    # concedes there ARE batches and implies that building an advancer would
    # complete the story. There are none to advance —
    # system_node_module_assignments has no version column, so nothing can be
    # sliced. This is the identical failure this file already records for
    # "nothing walks the batches" in the two runbooks; it survived here in two
    # more places (the reality column of the NOT IMPLEMENTED table, and the
    # troubleshooting entry 360 lines later).
    it "does not concede that batches exist while denying only their advancer" do
      expect(doc).not_to match(/Nothing advances the batches/i)
      expect(doc).not_to match(/nothing walks the batches/i)
    end

    # FILE-scoped. IMP-a699af087f5d nearly shipped a FRESH false claim here
    # while correcting the old ones. Explaining why boot images can be batched
    # and modules cannot, the first draft wrote that "a boot image is selected
    # per instance, whereas a module version is selected per module". The first
    # half is false: NodeInstance#promoted_image_git_sha reads
    # `node.node_platform.disk_image_git_sha` (node_instance.rb:807-808) — a
    # pointer on a shared parent, exactly like NodeModule#current_version_id.
    #
    # The real difference is ACTUATION, not target selection: a boot image
    # converges only when a per-instance `upgrade_boot_image` System::Task is
    # dispatched to it (boot_image/upgrade_dispatcher.rb:190-192), so the
    # rollout picks who moves now; a module has no such gate, because the node
    # pulls the pointer at its own next reconcile. Pinned because "the other
    # lane targets instances individually" is the intuitive and wrong story,
    # and it would re-license batching the module lane.
    it "does not explain the boot-image contrast as per-instance target selection" do
      expect(doc).not_to match(/boot image is selected per.instance/i)
      expect(doc).not_to match(/per.instance boot image (?:target|selection)/i)

      contrast = doc[/\*\*Why batching is possible there and not here\*\*.*?(?=\n## )/m] ||
                 raise("could not locate the boot-image contrast paragraph in 06-rolling-upgrade.md")

      expect(contrast).to include("disk_image_git_sha")
      expect(contrast).to include("upgrade_boot_image")
      expect(contrast).to match(/actuation/i)
      # Both halves of the explanation must stay CHECKABLE. A mutation that
      # stripped the dispatcher citation left the paragraph reading correctly
      # and survived on the prose alone — which is precisely the uncited-claim
      # failure this whole guard exists to prevent.
      expect(contrast).to include("node_instance.rb")
      expect(contrast).to include("upgrade_dispatcher.rb")

      # IMP-a699af087f5d — the SECOND half of the same paragraph was wrong in a
      # second way, and survived a mutation run until this was added. The draft
      # said "A module has no such gate". It has one: system_refresh_instance_modules
      # queues a per-instance `sync_modules` System::Task
      # (system_fleet_tool.rb:2641-2646). The real difference is that the
      # boot-image task PINS ITS TARGET in options ("target_git_sha" =>
      # target_sha, upgrade_dispatcher.rb:190-196) while sync_modules carries no
      # version at all — so it can only hasten an instance toward the single
      # global pointer. The doc's own § 4 already said exactly that ("changes
      # when an instance converges, never what it converges to"), so the draft
      # contradicted its own file 130 lines later.
      expect(doc).not_to match(/module has no such gate/i)
      expect(contrast).to include("sync_modules")
      expect(contrast).to include("target_git_sha")
      # Cited, not just named — a mutation that stripped this citation left the
      # paragraph reading correctly and survived on the prose alone, the same
      # way the dispatcher citation did.
      expect(contrast).to include("system_fleet_tool.rb")
    end

    # FILE-scoped. The learning-objectives blurb promised "a batched upgrade
    # plan". The executor returns one atomic set — `affected_instance_ids`,
    # asserted above to be the whole population — and its descriptor says the
    # upgrade "cannot be staged or batched".
    it "does not promise the reader a batched plan" do
      expect(doc).not_to match(/batched upgrade plan/i)
    end
  end

  # FILE-scoped. The CVE lane routes to this same executor, so it inherits the
  # gap — 06 already says so in its "What's next". Tutorial 07 did not: it
  # showed a plan JSON carrying `batch_size`, told the operator to tune it at
  # the approval gate, and then described watching batches complete.
  describe "docs/tutorials/07-cve-response.md (the CVE lane inherits the gap)" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/07-cve-response.md") }

    # batch_size appeared in THREE shapes in this one file, ~90 lines apart: a
    # jsonc plan body under Step 3, an operator instruction under Step 5, and a
    # create_learning payload under "Extract a learning". A heading-scoped
    # guard would have caught at most one of the three.
    it "shows no batch_size in the plan JSON, the approval step, or the learning payload" do
      expect(doc).not_to match(/batch_size/)
      expect(doc).not_to match(/\d+-batch/)
      expect(doc).not_to match(/After all batches complete/i)
    end

    # CveResponseExecutor#build_plan
    # (server/app/services/system/ai/skills/cve_response_executor.rb:180-204)
    # returns { steps: [...], ordering: "sequential" }, whose rolling_upgrade
    # step carries `fleet_atomic: true` and no batch key of any kind. Step 3's
    # body was wrong in SHAPE as well as in content, and nothing downstream of
    # the approval acts on it: cve-response.md Phase 6 is the runbook half of
    # this same correction.
    it "does not claim a reconciler executes the approved remediation" do
      expect(doc).not_to match(/autonomy reconciler executes the plan/i)
      expect(doc).not_to match(/Zero circuit breaker trips/i)
    end

    it "marks the remediation step unimplemented and routes to the manual procedure" do
      expect(doc).to match(/NOT IMPLEMENTED/)
      expect(doc).to match(/FLEET-ATOMIC/i)
      expect(doc).to include("06-rolling-upgrade.md#what-to-do-instead")
    end

    # FILE-scoped, and this example exists because the first pass at correcting
    # this file was HEADING-shaped in practice: it rewrote Steps 3, 5, 6 and
    # Verification and left the PIPELINE SUMMARY in the front matter — which a
    # reader meets ~100 lines EARLIER — asserting the opposite of every one of
    # them. Four survivors, all above Step 3: a "~75 min (mostly waiting for
    # batched remediation)" time estimate derived from figures the change had
    # just deleted; a prerequisite to have "the rolling upgrade machinery
    # working end-to-end" (there is no machinery); "batched by instance count";
    # and "Parallel when modules are independent; sequenced when
    # dependency_spec requires it".
    #
    # That last one was false on both halves and is worth pinning by NAME:
    # CveResponseExecutor#build_plan emits ONE rolling_upgrade step carrying
    # ALL module_ids, with `ordering: "sequential"` unconditionally
    # (cve_response_executor.rb:196-204). No dependency_spec is consulted
    # anywhere in that method and there is no parallel path.
    it "does not restate the retracted model in the pipeline summary above Step 3" do
      expect(doc).not_to match(/batched remediation/i)
      expect(doc).not_to match(/batched by/i)
      expect(doc).not_to match(/rolling upgrade machinery working end-to-end/i)
      expect(doc).not_to match(/[Pp]arallel when modules/)
      expect(doc).not_to match(/sequenced when dependency_spec/i)
    end

    # FILE-scoped. IMP-a699af087f5d's own first draft asserted "There is no CVE
    # response panel at /app/system/operations" — a FRESH false absence claim
    # introduced while removing older ones, and exactly the failure this task
    # was warned about. The panel exists: OperationsHubPage.tsx:30 registers
    # the tab and :136 routes it to operations/CveTab.tsx, which renders
    # CveExposure rows with an open/remediating/resolved badge. The true and
    # narrower claim is that it shows exposure STATE and not upgrade progress.
    it "does not deny that the CVE operations panel exists" do
      expect(doc).not_to match(/no CVE response panel/i)
      expect(doc).not_to match(/There is no CVE panel/i)

      # An absence claim was replaced by a cited presence claim; keep it cited.
      expect(doc).to include("CveTab.tsx")
    end
  end

  # TREE-scoped over docs/**/*.md — the widest scope in this file, and
  # deliberately wider than the three referrers that were wrong today. A
  # referring document describes 06 in its LINK TEXT, which no guard on 06
  # itself can see and which is the only description a reader of the REFERRER
  # ever reads. "Rolling module upgrade with canary" was carried by three
  # files, one of them the tutorial index — the first place a new operator
  # meets the topic. Tree scope so a NEW referrer cannot reintroduce it.
  #
  # IMP-a699af087f5d — this sweep originally globbed `docs/**/*.md` while its
  # own comment claimed "a NEW referrer cannot reintroduce it". That was false
  # twice over, and review caught both:
  #
  #   1. The extension's top-level README.md is OUTSIDE docs/ and carried the
  #      retracted row character-for-character ("Rolling module upgrade with
  #      canary | rolling_module_upgrade, circuit breaker, ..."), identical to
  #      the docs/tutorials/README.md row that WAS corrected — and it is the
  #      landing page of the public GitHub mirror. The glob now covers the
  #      extension root's own markdown as well.
  #   2. The vocabulary was `canary|batch`, which cannot see a link that simply
  #      uses the RETIRED TITLE: "[Tutorial 06 — Rolling module upgrade]"
  #      (05-multi-cluster-k3s.md:64) and "[Tutorial 06 — Rolling upgrade]"
  #      (08-instance-pool.md:293) both survived it. The title is retired, so
  #      the title itself is now part of the forbidden vocabulary.
  #
  # Known boundary, stated rather than implied: the regex matches INLINE links
  # only, so a reference-style link (`[text][ref]`) is invisible to it.
  describe "every doc that links to 06-rolling-upgrade.md" do
    let(:link_texts) do
      Dir.glob(File.join(ext_root, "{docs/**/*.md,*.md}")).sort.flat_map do |path|
        File.read(path)
            .scan(/\[([^\]]+)\]\([^)]*06-rolling-upgrade\.md[^)]*\)/)
            .map { |(text)| [ path.delete_prefix("#{ext_root}/"), text ] }
      end
    end

    it "finds such links at all, so the sweep is not vacuous" do
      expect(link_texts).not_to be_empty
    end

    it "describes it without the retracted batched/canary model" do
      offenders = link_texts.select { |(_path, text)| text.match?(/canary|batch/i) }

      expect(offenders).to be_empty
    end

    it "does not describe it by its retired title" do
      # "rolling upgrade" as prose in link TEXT. A path used as link text
      # ("`docs/tutorials/06-rolling-upgrade.md`") is hyphenated and does not
      # match, which is intended — a filename is not a description.
      offenders = link_texts.select { |(_path, text)| text.match?(/rolling (?:module )?upgrade/i) }

      expect(offenders).to be_empty
    end

    it "covers the extension root, not only docs/ (the public mirror's landing page)" do
      expect(link_texts.map(&:first)).to include("README.md")
    end
  end

  # FILE-scoped, one example per referring file. The tree sweep above covers
  # the anchor TEXT; these cover the sentence around it, which is where each
  # referrer restated the model in its own words and where the sweep is blind.
  describe "the referring docs' prose about tutorial 06" do
    it "05-multi-cluster-k3s.md does not tell the operator to canary one cluster" do
      doc = self.class.read(ext_root, "docs/tutorials/05-multi-cluster-k3s.md")

      expect(doc).not_to match(/upgrade one cluster as a canary/i)
      expect(doc).not_to match(/rolling upgrades become non-trivial/i)
    end

    it "10-gitops-fleet.md does not say tutorial 06 teaches batched application" do
      doc = self.class.read(ext_root, "docs/tutorials/10-gitops-fleet.md")

      expect(doc).not_to match(/changes in batches/i)
    end

    # Row-scoped rather than file-scoped, because the index legitimately
    # describes tutorial 09 (honeypot canaries) two rows below — a different
    # and real feature. Presence is asserted on the same row, so deleting the
    # forbidden words without replacing them cannot satisfy this.
    it "the tutorial index's 06 row names neither a circuit breaker nor a canary" do
      readme = self.class.read(ext_root, "docs/tutorials/README.md")
      row = readme[/^\|\s*\[06\].*$/] ||
            raise("could not locate the 06 row in docs/tutorials/README.md")

      expect(row).not_to match(/circuit breaker/i)
      expect(row).not_to match(/canary|batch/i)
      expect(row).to match(/fleet-atomic/i)
    end

    # Row-scoped, same reasoning. The index row for 07 promised an
    # "orchestrated rebuild", which is the execution the tutorial itself now
    # marks NOT IMPLEMENTED — the index contradicting its own page is the same
    # failure as 06's title contradicting the banner three lines below it, and
    # it reaches the reader FIRST.
    it "the tutorial index's 07 row does not promise an executed remediation" do
      readme = self.class.read(ext_root, "docs/tutorials/README.md")
      row = readme[/^\|\s*\[07\].*$/] ||
            raise("could not locate the 07 row in docs/tutorials/README.md")

      expect(row).not_to match(/orchestrated rebuild/i)
      expect(row).to match(/NOT IMPLEMENTED/)
    end
  end

  # LINE-scoped, and this is the one place that scope is right: SMOKE_TEST.md
  # is a catalog of one row per seed, and a file-wide forbid on "canary" would
  # collide with the honeypot-canary rows, which describe a different and real
  # feature. Scoping to the rows that NAME this seed keeps the guard precise
  # and still catches a newly added row. Presence is asserted PER ROW, so a
  # second row cannot inherit the first row's correctness — which is exactly
  # how the stale wording survived in two rows 318 lines apart.
  describe "docs/SMOKE_TEST.md rows for smoke_test_k3s_rolling_upgrade.rb" do
    let(:rows) do
      self.class.read(ext_root, "docs/SMOKE_TEST.md")
          .lines.select { |line| line.include?("smoke_test_k3s_rolling_upgrade.rb") }
    end

    it "finds the rows at all, so the sweep is not vacuous" do
      expect(rows.size).to be >= 2
    end

    it "describes the seed as asserting an atomic plan, not canary-first batch sequencing" do
      expect(rows.reject { |line| line.match?(/canary|batch/i) }).to eq(rows)
      expect(rows.select { |line| line.match?(/atomic/i) }).to eq(rows)
    end
  end

  # HEADER-scoped — `let(:header)` slices the leading comment block. NOT
  # file-scoped: an earlier draft of this comment claimed file scope and was
  # wrong about its own mechanism. The narrowing IS justified, because the
  # corrective comment in the body (:139) legitimately reads "there is no
  # canary batch to assert on", and a file-wide ban on "canary" would forbid
  # the correction itself. The body is covered separately by the assertion pin
  # at the end of this block.
  #
  # IMP-b948ea7fa382 corrected this seed's ASSERTIONS — :147-148 now assert
  # `!data.key?(:batches) && !data.key?(:batch_count)` — and one header
  # paragraph, but left the "Tier semantics" and "Asserts:" lists still
  # advertising the deleted checks ("Plan has batch_count >= 1", "First batch
  # is the canary"). A reader who trusts the header believes the seed verifies
  # a canary batch that the seed explicitly asserts is ABSENT.
  describe "server/db/seeds/smoke_test_k3s_rolling_upgrade.rb (header vs. its own assertions)" do
    let(:seed) { self.class.read(ext_root, "server/db/seeds/smoke_test_k3s_rolling_upgrade.rb") }

    let(:header) do
      seed[/\A(?:#.*\n|\n)*/] ||
        raise("could not read the header comment block of smoke_test_k3s_rolling_upgrade.rb")
    end

    it "does not advertise batch assertions the seed no longer makes" do
      expect(header).not_to match(/batch_count >= 1/)
      expect(header).not_to match(/First batch is the canary/i)
      expect(header).not_to match(/with canary first/i)
      # Same expired-concession pattern as 06's "Nothing advances the batches":
      # denying only the ADVANCER concedes that batches exist.
      expect(header).not_to match(/reconciler stepping through batches/i)
    end

    it "states the contract the seed actually asserts" do
      expect(header).to match(/FLEET-ATOMIC/i)
      expect(header).to match(/affected_instance_ids/)
    end

    # The pin that keeps the two halves in step: whatever the header claims,
    # the executable assertion below it is the authority. If someone deletes
    # the assertion, the header's promise becomes false again and this reddens.
    it "still asserts the absence of a batch structure in its body" do
      expect(seed).to include("!data.key?(:batches) && !data.key?(:batch_count)")
    end
  end

  # FILE-scoped. IMP-a699af087f5d checked this seed against the same vocabulary
  # as the six above and it was ALREADY clean — it never described the batched
  # model, so it is pinned rather than edited. A verified-clean surface is
  # worth a standing guard rather than a one-off grep in a report, since it is
  # the sibling most likely to acquire the wording later: it is the operator-
  # facing seed for the very lane tutorial 07 documents.
  describe "server/db/seeds/example_cve_response.rb (verified clean, pinned)" do
    let(:seed) { self.class.read(ext_root, "server/db/seeds/example_cve_response.rb") }

    it "teaches no batched or canary remediation model" do
      expect(seed).not_to match(/batch_size|batch_pct|batch_count|batches|canary/i)
    end
  end
end
