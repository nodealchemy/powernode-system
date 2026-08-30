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

    it "states in its skill_descriptor that it plans only" do
      # The descriptor description is what an AGENT reads BEFORE calling, so
      # the plan/execute split has to be stated there too — correcting it only
      # in prose teaches a human and leaves the agent surface lying. Same
      # reasoning as system_promote_module_version's descriptor (IMP-65bea54e4081,
      # system_fleet_tool.rb:873), which is purely additive truth-telling and
      # disables no mechanism.
      descriptor = executor[/skill_descriptor\(.*?\n        \)/m] ||
                   raise("could not locate skill_descriptor in rolling_module_upgrade_executor.rb")

      expect(descriptor).to match(/NOT executed|not executed|no batch advancer|nothing advances/i)
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

    it "states plainly that the executor plans and nothing advances the batches" do
      expect(doc).to match(/NOT IMPLEMENTED/)
      expect(doc).to match(/nothing advances the batches/i)
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

    it "says the plan is returned and never executed" do
      section = doc[/^### `rolling_module_upgrade` — Batched fleet upgrade.*?(?=^### )/m] ||
                raise("could not locate the rolling_module_upgrade section in SKILL_EXECUTORS.md")

      expect(section).to match(/NOT IMPLEMENTED/)
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
      expect(appendix).to match(/not a blast-radius control/i)
    end
  end

  # IMP-b948ea7fa382 — two runbooks told an operator the same thing in wording
  # no M7 regex could catch: that a reconciler drives the skill in prod. Both
  # get the matched pair, since deleting the sentence would leave an operator
  # planning an upgrade with no warning that it will not run.
  describe "the runbooks that told an operator a reconciler drives the upgrade" do
    it "docs/runbooks/multi-cluster-k3s.md says the skill plans only" do
      doc = self.class.read(ext_root, "docs/runbooks/multi-cluster-k3s.md")

      expect(doc).not_to match(/skill is driven by the autonomy reconciler/)
      expect(doc).to match(/PLANS ONLY/)
      expect(doc).to match(/nothing walks the batches/i)
    end

    it "docs/runbooks/k3s-smoke-full-lifecycle.md does not promise a prod reconciler tick" do
      doc = self.class.read(ext_root, "docs/runbooks/k3s-smoke-full-lifecycle.md")

      expect(doc).not_to match(/Fleet Autonomy's reconciler tick does that in prod/)
      expect(doc).to match(/no reconciler tick advances\s*\n?these batches/i)
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
end
