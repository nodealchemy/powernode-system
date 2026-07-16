# frozen_string_literal: true

module System
  # Campaign 019f5885 inc9 Part B — the brain of native module builds. Turns a
  # System::ModuleBuildBatch (Part A's bookkeeping row) into per-module
  # `ci.module_build` System::Task rows on leased ephemeral module-forge
  # builders, then signs + publishes each successful result server-side.
  # Retargets the inc4 CiBuildOrchestrator seam (Gitea-workflow-dispatch) to
  # platform-task-dispatch for the native (non-Gitea-Actions) build path —
  # this class is the module-forge analog of CiBuildOrchestrator.
  #
  # Two entry points, both safe to call repeatedly:
  #
  #   dispatch!(batch:) — the initial pass, called once right after
  #     ModuleBuildBatch.create_for: lease a builder + create a Task for
  #     every module in the batch's plan, up to the concurrency cap. Modules
  #     that can't get a lease right now are left "queued" for a later
  #     advance! tick — this NEVER fails the batch (see class doc on
  #     System::CiRunnerLeaseService for why pool exhaustion is routine).
  #
  #   advance!(batch:) — idempotent; called by
  #     System::CiRunnerLeaseSweepService's purpose-aware `module_build`
  #     branch whenever a lease's correlated Task reaches a terminal status
  #     (also safe to call on a schedule directly). Opportunistically
  #     dispatches any still-queued modules if capacity has freed up, signs +
  #     publishes builds whose Task completed, retries failed builds on a
  #     fresh lease (up to a configured attempt cap), and advances the
  #     batch's own AASM status once every module has reached ITS terminal
  #     state (succeeded or failed).
  #
  # Per-module bookkeeping (state/attempts/lease id/task id) lives in
  # batch.metadata["modules"] (keyed by slug — or "slug@arch" for a
  # multi-arch package plan entry, campaign 019f6084 inc J; see
  # #load_modules_state) — ModuleBuildBatch has no per-module table, only
  # the aggregate succeeded_count/failed_count (see
  # #recompute_counts!), so this orchestrator is the one place that tracks
  # retry/concurrency state. Seeded from batch.metadata["plan"] (written by
  # ModuleBuildBatch.create_for) — each plan entry's "oci_ref" is actually a
  # short TAG (see System::ModuleBuildPlannerService's doc), never a full OCI
  # reference; the full ref is only ever constructed here for signing (see
  # #full_oci_ref), mirroring System::ModulePublicationProcessor#build_oci_ref.
  #
  # FAIL-CLOSED: a module is only ever marked "succeeded" after
  # System::ModuleSigningService.sign! AND System::ModulePublicationProcessor
  # .process! both report ok? — an unsigned/digest-mismatched artifact or a
  # publish failure is treated exactly like a build failure (retry-or-give-up
  # via #attempt_retry!).
  #
  # LEASE RELEASE happens HERE, in #advance! (via #release_module_lease),
  # exactly once per terminal member Task it processes — never inside
  # System::CiRunnerLeaseSweepService itself. This is safe by construction:
  # #advance! (called by the sweep's purpose-aware branch, or
  # #advance_for_task!) only ever reaches a module's release call after that
  # module's CURRENT Task is already `finished?` (see #terminal_member_tasks),
  # so a lease whose build might still be running is never torn down. The
  # sweep keeps a non-forced release call of its OWN as a backstop — see
  # CiRunnerLeaseSweepService#advance_module_build — in case the orchestrator
  # couldn't be reached (batch_id missing/batch deleted) or its release
  # attempt itself failed, so a lease is never permanently stranded.
  class NativeModuleBuildOrchestrator
    DEFAULT_POOL_NAME               = "ci-native-builders-amd64"
    DEFAULT_MAX_CONCURRENT_BUILDERS = 2
    DEFAULT_MAX_ATTEMPTS            = 2

    TERMINAL_MODULE_STATES = %w[succeeded failed].freeze

    Result = Struct.new(:ok?, :dispatched, :queued, :succeeded, :retried, :failed, keyword_init: true)

    class << self
      def dispatch!(batch:)
        new(batch: batch).dispatch!
      end

      def advance!(batch:)
        new(batch: batch).advance!
      end

      # Convenience seam for CiRunnerLeaseSweepService: resolve the batch a
      # Task belongs to (via its options["batch_id"]) and advance it. Returns
      # nil (a no-op) when the task carries no batch_id or the batch can't be
      # found — the sweep treats that as "nothing to advance", not an error.
      def advance_for_task!(task)
        batch_id = task_batch_id(task)
        return nil if batch_id.blank?

        batch = ::System::ModuleBuildBatch.find_by(id: batch_id)
        return nil unless batch

        advance!(batch: batch)
      end

      def task_batch_id(task)
        opts = task.options || {}
        opts["batch_id"] || opts[:batch_id]
      end
    end

    def initialize(batch:)
      @batch = batch
      @account = batch.account
    end

    def dispatch!
      modules = load_modules_state

      if modules.empty?
        finish_empty_batch!
        return vacuous_result
      end

      try_dispatch_queued!(modules)
      save_modules_state!(modules)

      @batch.dispatch! if @batch.may_dispatch?
      @batch.recompute_counts!

      Result.new(ok?: true, dispatched: count_state(modules, "dispatched"), queued: count_state(modules, "queued"),
                 succeeded: 0, retried: 0, failed: count_state(modules, "failed"))
    end

    def advance!
      modules = load_modules_state
      return vacuous_result if modules.empty?

      try_dispatch_queued!(modules)

      succeeded = 0
      retried   = 0
      failed    = 0

      # Reverse index by task_id rather than re-deriving a state key from
      # task.options — robust to both the bare-slug key (platform / single-
      # arch package) and the compound "slug@arch" key (multi-arch package,
      # campaign 019f6084 inc J) without needing to know which shape a given
      # batch uses.
      entries_by_task_id = modules.values.index_by { |e| e["task_id"] }

      terminal_member_tasks(modules).each do |task|
        entry = entries_by_task_id[task.id]
        next unless entry
        next if TERMINAL_MODULE_STATES.include?(entry["state"]) # already resolved

        slug = entry["module"]

        # Captured BEFORE attempt_retry! (which nils lease_id for the NEW
        # attempt) — this task's lease is done being built on either way
        # (success, retry, or exhausted failure) and must be released here.
        lease_id_to_release = entry["lease_id"]

        if task.status == "complete" && finalize_success!(slug, entry, task)
          entry["state"] = "succeeded"
          succeeded += 1
        elsif attempt_retry!(entry)
          retried += 1
        else
          entry["state"] = "failed"
          failed += 1
        end

        release_module_lease(lease_id_to_release)
      end

      save_modules_state!(modules)
      @batch.recompute_counts!
      advance_batch_status!(modules)

      Result.new(ok?: true, dispatched: count_state(modules, "dispatched"), queued: count_state(modules, "queued"),
                 succeeded: succeeded, retried: retried, failed: failed)
    end

    private

    def vacuous_result
      Result.new(ok?: true, dispatched: 0, queued: 0, succeeded: 0, retried: 0, failed: 0)
    end

    # A batch whose plan is empty (nothing needed rebuilding) has no member
    # tasks to ever drive the normal per-module transitions — walk the AASM
    # chain straight through so it lands on `complete` (vacuously: zero
    # modules planned, zero failed) instead of sitting in `planning` forever.
    def finish_empty_batch!
      @batch.dispatch!         if @batch.may_dispatch?
      @batch.await_signature!  if @batch.may_await_signature?
      @batch.begin_publishing! if @batch.may_begin_publishing?
      @batch.complete!         if @batch.may_complete?
      @batch.recompute_counts!
    end

    # === Per-module state (persisted in batch.metadata["modules"]) ===

    # Keyed by module slug — EXCEPT a multi-arch package plan entry (campaign
    # 019f6084 inc J), which carries an "architecture" and is keyed
    # "<slug>@<arch>" so its own independent lease/Task/tag never collides
    # with a sibling arch's state for the same module. A single-arch plan
    # entry never carries "architecture" (see PackageClosureBuildBridge
    # #build_plan) so its key stays the bare slug — byte-identical to the
    # pre-inc-J shape, no regression. Every entry keeps its real module name
    # in "module" (never the compound key) so callers never need to parse
    # the key back apart — see #finalize_success!/#dispatch_one!, which take
    # the module name from entry["module"], not from the hash key.
    def load_modules_state
      existing = @batch.metadata["modules"]
      return existing.dup if existing.present?

      Array(@batch.metadata["plan"]).each_with_object({}) do |plan_entry, memo|
        slug = plan_entry["module"] || plan_entry[:module]
        tag  = plan_entry["oci_ref"] || plan_entry[:oci_ref]
        arch = plan_entry["architecture"] || plan_entry[:architecture]
        next if slug.blank?

        key = arch.present? ? "#{slug}@#{arch}" : slug.to_s
        memo[key] = {
          "module" => slug.to_s, "architecture" => arch,
          "tag" => tag, "state" => "queued", "attempts" => 0,
          "lease_id" => nil, "task_id" => nil, "error" => nil
        }
      end
    end

    def save_modules_state!(modules)
      @batch.update!(metadata: @batch.metadata.merge("modules" => modules))
    end

    def count_state(modules, state)
      modules.values.count { |e| e["state"] == state }
    end

    # === Dispatch (lease + task creation), capacity-bounded ===

    def try_dispatch_queued!(modules)
      modules.each_value do |entry|
        next unless entry["state"] == "queued"
        next unless capacity_available?

        dispatch_one!(entry)
      end
    end

    def capacity_available?
      active_module_build_lease_count < max_concurrent_builders
    end

    def active_module_build_lease_count
      ::System::CiRunnerLease.for_account(@account).active.where(purpose: "module_build").count
    end

    # Leases a builder + creates the ci.module_build Task for one module (one
    # arch of it, for a multi-arch package entry). Mutates `entry` in place;
    # returns true when dispatched. Leaves entry in "queued" (pool
    # unavailable right now — NOT a batch failure) unless the module itself
    # is unresolvable, in which case it's marked "failed" directly (no retry
    # can fix a missing NodeModule). Always takes the real module slug from
    # entry["module"] — never a (possibly compound "slug@arch") state key —
    # so a NodeModule lookup / task options["module"] is never handed a
    # synthetic key.
    def dispatch_one!(entry)
      slug = entry["module"]
      lease = acquire_lease
      return false unless lease

      node_module = find_node_module(slug)
      unless node_module
        entry["state"] = "failed"
        entry["error"] = "NodeModule '#{slug}' not found for account #{@account.id}"
        release_lease_best_effort(lease)
        return false
      end

      task = create_build_task(lease, slug, entry)
      unless task
        release_lease_best_effort(lease)
        return false
      end

      lease.update!(build_task_id: task.id)
      # No Gitea runner will ever correlate for a module-forge builder (it
      # isn't a gitea-act-runner) — register immediately (a runner-less
      # `register!` is a valid AASM invocation; see System::CiRunnerLease's
      # `event :register`) so the lease can reach `busy` once the agent
      # acknowledges the task. System::CiRunnerLeaseSweepService's
      # purpose-aware branch drives this lease off Task state instead of a
      # Gitea workflow run from here on.
      lease.register! if lease.may_register?

      entry["state"]    = "dispatched"
      entry["attempts"] = entry["attempts"].to_i + 1
      entry["lease_id"] = lease.id
      entry["task_id"]  = task.id
      entry["error"]    = nil
      true
    end

    def acquire_lease
      ::System::CiRunnerLeaseService.lease!(
        account: @account, pool_name: pool_name, purpose: "module_build", correlate_timeout: 0
      )
    rescue ::System::CiRunnerLeaseService::LeaseError => e
      Rails.logger.info("[NativeModuleBuildOrchestrator] lease unavailable (#{e.class}): #{e.message}")
      nil
    end

    def create_build_task(lease, slug, entry)
      ::System::Task.create!(
        account: @account,
        operable: lease.node_instance,
        command: @batch.member_task_command,
        status: "pending",
        options: build_task_options(slug, entry)
      )
    rescue ActiveRecord::RecordInvalid => e
      entry["error"] = "task creation failed: #{e.message}"
      nil
    end

    # Platform (ci.module_build) tasks carry {module, sha, oci_ref, batch_id}.
    # Package (ci.package_build — campaign 019f6084 inc2 §4.3.2) tasks carry the
    # same four PLUS the mmdebstrap build inputs (package name, arch, repo
    # coordinates, pinned apt snapshot) the leased builder needs — there is no
    # modules/<slug> tree in a repo to check out for a materialized package
    # module, so the whole build recipe travels in the task options.
    def build_task_options(slug, entry)
      base = {
        "module"   => slug,
        "sha"      => @batch.head_sha,
        "oci_ref"  => entry["tag"],
        "batch_id" => @batch.id
      }
      return base unless package_batch?

      base.merge(package_task_options(slug, entry))
    end

    def package_task_options(slug, entry)
      ctx     = package_context
      mod_ctx = (ctx["modules"] || {})[slug] || {}
      # EVR lockfile pin (campaign 019f6084 item L) — sourced from
      # PackageClosureBuildBridge#package_lock, embedded in package_context
      # under the same key so this is the one place both a fresh
      # metadata["package_lock"] and the older per-module mod_ctx snapshot
      # are consulted. Absent for a batch dispatched before this lockfile
      # existed (or a link with no recorded version) — nil here means "no
      # pin", which PackageBuildHandler treats as today's unpinned behavior.
      pinned_version = (ctx["package_lock"] || {})[slug] || mod_ctx["package_version"]
      {
        "build_kind"        => "package",
        "package_name"      => mod_ctx["package_name"] || slug,
        "package_version"   => pinned_version,
        # entry["architecture"] is THIS build unit's target arch (multi-arch
        # fan-out — campaign 019f6084 inc J); mod_ctx["architecture"] is the
        # PackageModuleLink's discovery-time arch (unrelated to which arch is
        # being built); ctx["architecture"] (single arch, pre-inc-J) is the
        # final fallback for a plan entry that never set one.
        "architecture"      => entry["architecture"] || mod_ctx["architecture"] || ctx["architecture"],
        "package_repo_id"   => ctx["repository_id"],
        "package_repo_url"  => ctx["package_repo_url"],
        "package_repo_kind" => ctx["package_repo_kind"],
        "apt_suite"         => ctx["apt_suite"],
        "apt_components"    => ctx["apt_components"],
        "rpm_releasever"    => ctx["rpm_releasever"],
        "apt_snapshot"      => ctx["apt_snapshot"],
        "gpg_key_armor"     => ctx["gpg_key_armor"],
        "mask"              => mod_ctx["mask"],
        "file_spec_source"  => mod_ctx["file_spec_source"]
      }.compact
    end

    # Only ever called for a lease that never got a Task dispatched onto it
    # (unresolvable module / task-creation failure) — never for a lease
    # whose task might be running. force: true mirrors
    # CiBuildOrchestrator#release_stranded_lease (the runner, if even
    # registered yet, cannot be busy with work that was never created).
    def release_lease_best_effort(lease)
      ::System::CiRunnerLeaseService.release!(account: @account, lease: lease, force: true)
    rescue StandardError => e
      Rails.logger.warn("[NativeModuleBuildOrchestrator] release after undispatched lease failed: #{e.message}")
    end

    # Releases the lease that just finished building a module's Task — called
    # exactly once per terminal task, AFTER the module's fate (succeeded /
    # queued-for-retry / failed) has already been decided, so it's always
    # safe: the Task this lease was tracking is already `finished?` by
    # construction (see #terminal_member_tasks). force: false — never tear
    # down a runner Gitea (or here, the task-lease loop) still considers
    # busy; module_build leases have no git_runner_id so this check is
    # effectively always clear, but the same safe default is kept for
    # consistency with every other release! call in this codebase.
    def release_module_lease(lease_id)
      return if lease_id.blank?

      lease = ::System::CiRunnerLease.find_by(id: lease_id)
      return if lease.nil? || lease.finished?

      ::System::CiRunnerLeaseService.release!(account: @account, lease: lease, force: false)
    rescue StandardError => e
      Rails.logger.warn("[NativeModuleBuildOrchestrator] lease ##{lease_id} release failed: #{e.message}")
    end

    # === Per-module terminal handling ===

    def terminal_member_tasks(modules)
      tracked_task_ids = modules.values.map { |e| e["task_id"] }.compact
      return [] if tracked_task_ids.empty?

      @batch.member_tasks.where(id: tracked_task_ids).select(&:finished?)
    end

    # Signs + publishes a successful build. Returns true only when BOTH
    # steps report ok? — fail-closed: never publish an unsigned or
    # digest-mismatched artifact. Opportunistically advances the batch's own
    # AASM status through awaiting_signature/publishing the first time any
    # module reaches each phase (a best-effort real-time signal; the final
    # complete/partial/failed call happens once in #advance_batch_status!).
    #
    # Multi-arch package builds (campaign 019f6084 inc J): each arch's entry
    # carries its OWN entry["tag"] (arch-suffixed — see
    # PackageClosureBuildBridge#build_plan), so this runs the exact same
    # sign→publish call once per arch, unmodified. #process!'s
    # #find_or_create_version keys on that tag, so each arch lands its own
    # NodeModuleVersion + single ModuleArtifact rather than one shared
    # version with N per-arch artifacts (the shape a platform module's
    # single multi-arch OCI index push ingests into). Unifying them into one
    # version would need either an OCI-index-assembly step after all arches
    # land, or decoupling ModulePublicationProcessor's version-identity tag
    # from its OCI-ref tag — flagged as a follow-up, not attempted here (no
    # real builder exists in this dev env to exercise either path yet).
    def finalize_success!(slug, entry, task)
      node_module = find_node_module(slug)
      unless node_module
        entry["error"] = "NodeModule '#{slug}' not found for account #{@account.id}"
        return false
      end

      result = task_result(task)

      # Package builds (§4.3.2): the ONE package-specific finalize step the
      # native path adds — write the builder's discovered dpkg -L / rpm -ql
      # file list to file_spec + dependency_spec BEFORE signing. Versioning +
      # OCI artifact ingest are then handled by the SAME sign→publish path as
      # platform modules (ModulePublicationProcessor below), so this does NOT
      # run the full PackageBuildWebhookService (which would double-create the
      # version + artifact) — only its file_spec seam.
      apply_package_file_spec!(node_module, result) if package_batch?

      @batch.await_signature! if @batch.may_await_signature?
      sign_result = ::System::ModuleSigningService.sign!(
        oci_ref: full_oci_ref(node_module, entry["tag"]),
        expected_digest: result["oci_digest"],
        account: @account,
        node_module_id: node_module.id
      )
      unless sign_result.ok?
        entry["error"] = "signing failed: #{sign_result.error}"
        return false
      end

      @batch.begin_publishing! if @batch.may_begin_publishing?
      # Shadow batches (campaign 019f5885 inc10 — dual-run) ingest + record a
      # NodeModuleVersion under the `native-` tag (see class doc) but must
      # NEVER advance current_version_id — the fleet keeps consuming exactly
      # what the Gitea build published. Non-shadow batches (authoritative
      # native dispatch, and every pre-inc10 manual/CVE dispatch) promote
      # exactly as before — @batch.shadow? defaults false so this is a no-op
      # change for every existing caller.
      # native_build routes ModulePublicationProcessor to record the artifact
      # from the registry-resolved erofs LAYER (blob) digest — the sha256 the
      # agent verifies on pull — instead of the dev LocalOciAdapter stub /
      # multi-arch index ingest path. fs-verity root comes from the builder's
      # result (computed over the erofs bytes); the reported result["oci_digest"]
      # is the MANIFEST descriptor digest (used for signing above) and is
      # deliberately NOT passed as the artifact digest.
      publish_result = ::System::ModulePublicationProcessor.process!(
        node_module: node_module, tag: entry["tag"], promote: !@batch.shadow?,
        native_build: {
          fsverity_root: result["fsverity_root"],
          architecture: entry["architecture"]
        }
      )
      unless publish_result.ok?
        entry["error"] = "publish failed: #{publish_result.error}"
        return false
      end

      emit_event("system.module_build_batch_module_succeeded", module: node_module.name, tag: entry["tag"])
      true
    end

    # Re-queues for another dispatch attempt (a fresh lease + Task, picked up
    # by a later #try_dispatch_queued! pass) when attempts remain; false once
    # max_attempts is exhausted — the caller marks the module "failed".
    def attempt_retry!(entry)
      return false if entry["attempts"].to_i >= max_attempts

      entry["state"]    = "queued"
      entry["lease_id"] = nil
      entry["task_id"]  = nil
      true
    end

    def advance_batch_status!(modules)
      states = modules.values.map { |e| e["state"] }
      return if states.include?("queued") || states.include?("dispatched") # still in flight

      if states.all? { |s| s == "succeeded" }
        @batch.complete! if @batch.may_complete?
      elsif states.any? { |s| s == "succeeded" }
        @batch.complete_partially! if @batch.may_complete_partially?
      else
        @batch.fail!("all #{states.size} module build(s) failed") if @batch.may_fail?
      end
    end

    # === Helpers ===

    def task_result(task)
      completed_event = Array(task.events).reverse.find { |e| (e["type"] || e[:type]).to_s == "completed" }
      raw = completed_event && (completed_event["result"] || completed_event[:result])
      raw.is_a?(Hash) ? raw.stringify_keys : {}
    end

    def find_node_module(slug)
      @account.system_node_modules.find_by(name: slug)
    end

    # === Package-build (campaign 019f6084 inc2 §4.3.2) ===

    def package_batch?
      @batch.trigger == "package"
    end

    def package_context
      @batch.metadata["package_context"] || {}
    end

    # Non-fatal: an absent/failed file_spec application does not fail the build
    # (the sign→publish path still runs and the operator sees the module), but
    # it IS logged — a package module that publishes with an empty file_spec
    # carves nothing, which the size ledger / carve-conformance check surfaces.
    def apply_package_file_spec!(node_module, result)
      file_spec = result["file_spec"] || result[:file_spec]
      if file_spec.blank?
        Rails.logger.warn("[NativeModuleBuildOrchestrator] package build for #{node_module.name} " \
                          "reported no file_spec — module will carry an empty file_spec")
        return
      end

      ::System::PackageBuildWebhookService.apply_file_spec!(node_module: node_module, file_spec: file_spec)
    rescue StandardError => e
      Rails.logger.warn("[NativeModuleBuildOrchestrator] package file_spec apply failed " \
                        "for #{node_module.name}: #{e.message}")
    end

    # Mirrors System::ModulePublicationProcessor#build_oci_ref — CONFIRMED
    # against scripts/module-build/push.sh's EROFS_REF construction
    # ("#{REGISTRY_HOST}/powernode/#{MODULE}:#{TAG}"): the same
    # registry+namespace+tag shape module-forge-build.sh's push actually
    # used, so the digest this fetches back is the one the builder just
    # pushed. `entry["tag"]` here is the SHORT tag (see class doc) — the
    # plan's "oci_ref" key despite the name.
    def full_oci_ref(node_module, tag)
      registry = ::System::DiskImageRegistryConfig.registry_host(account: @account)
      "#{registry}/#{oci_repo_path(node_module)}:#{tag}"
    end

    # OCI repo path an artifact was actually pushed under. push.sh hardcodes the
    # `powernode/<module>` namespace (REGISTRY_NS="${REGISTRY_HOST}/powernode"),
    # and gitea_repo_full_name is blank for every platform module (only the 5
    # custom per-repo modules populate it). Prefer the explicit column when set
    # (custom modules), else mirror push.sh so the ref matches where
    # module-forge-build.sh's push.sh just pushed — without it the fetch/sign/
    # publish all target `<registry>/:<tag>` (empty repo) and fail.
    def oci_repo_path(node_module)
      node_module.gitea_repo_full_name.presence || "powernode/#{node_module.name}"
    end

    def emit_event(kind, severity: :low, **payload)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: @account, kind: kind, severity: severity, source: "native_module_build_orchestrator",
        payload: payload.stringify_keys.merge("batch_id" => @batch.id)
      )
    rescue StandardError => e
      Rails.logger.warn("[NativeModuleBuildOrchestrator] event emit failed: #{e.message}")
    end

    def pool_name
      ::SiteSetting.get("system.module_builds.pool_name").presence || DEFAULT_POOL_NAME
    end

    def max_concurrent_builders
      (::SiteSetting.get("system.module_builds.max_concurrent_builders").presence || DEFAULT_MAX_CONCURRENT_BUILDERS).to_i
    end

    def max_attempts
      (::SiteSetting.get("system.module_builds.max_attempts").presence || DEFAULT_MAX_ATTEMPTS).to_i
    end
  end
end
