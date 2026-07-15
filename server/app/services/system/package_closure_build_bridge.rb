# frozen_string_literal: true

module System
  # Bridges a materialized package closure (System::PackageModuleMaterializer)
  # onto the native module-build pipeline (campaign 019f5885 inc9): instead of
  # the legacy fire-and-forget Gitea workflow_dispatch — which creates no
  # System::Task and no ModuleBuildBatch, so nothing can poll for completion or
  # server-side-sign the result — this creates ONE System::ModuleBuildBatch
  # (trigger "package") over the closure and hands it to
  # System::NativeModuleBuildOrchestrator, the SAME lease→build→Vault-sign→
  # publish machinery platform modules use (campaign 019f6084 inc2 §4.3.2 — the
  # unification point of the plan).
  #
  # The resulting batch is the build-completion barrier an on-demand consumer
  # (inc2-A's batch read API, inc3's template/instance slice) polls. Members are
  # `ci.package_build` System::Task rows correlated by options["batch_id"] (see
  # ModuleBuildBatch#member_tasks / #member_task_command). The full mmdebstrap
  # recipe (package name, arch, repo coordinates, pinned apt snapshot) travels
  # in metadata["package_context"], from which the orchestrator builds each
  # member task's options — a materialized package module has no modules/<slug>
  # tree in a repo to check out, so the recipe cannot come from a git ref.
  #
  # PARKED (reported to the driver, NOT attempted here): actually EXECUTING a
  # native package build needs the live builder fleet (module-forge /
  # gitea-act-runner), which per inc0's size-ledger finding has NEVER built in
  # this dev env. Absent a leasable builder the batch's modules stay `queued`
  # (never failed — see NativeModuleBuildOrchestrator's pool-exhaustion posture)
  # until a builder appears; the batch + tasks are created either way, so the
  # read/poll surface inc2-A and inc3 build on top of exists immediately.
  class PackageClosureBuildBridge
    Result = Struct.new(:ok?, :batch, :error, keyword_init: true)

    def self.dispatch!(**kwargs)
      new(**kwargs).dispatch!
    end

    # @param repository [System::PackageRepository]
    # @param modules [Array<System::NodeModule>] the materialized closure
    #   (top-level + non-baseline deps) to build.
    # @param architectures [Array<String>] kind-specific arches (campaign
    #   019f6084 inc J) — every requested arch is fanned out into its own
    #   member Task per module (see #build_plan); the agent-side
    #   ci.package_build handler builds exactly the one arch its Task's
    #   options["architecture"] names.
    # @param account [Account]
    # @param requested_by [User, nil]
    def initialize(repository:, modules:, architectures:, account:, requested_by: nil)
      @repository    = repository
      @modules       = Array(modules).compact
      @architectures = Array(architectures).map(&:to_s).uniq
      @account       = account
      @requested_by  = requested_by
    end

    def dispatch!
      return Result.new(ok?: false, error: "no modules to build") if @modules.empty?
      return Result.new(ok?: false, error: "no architectures") if @architectures.empty?

      snapshot = snapshot_token
      tag      = build_tag(snapshot)
      plan     = build_plan(tag)

      batch = ::System::ModuleBuildBatch.create_for(
        account:  @account,
        plan:     plan,
        trigger:  "package",
        # No git ref exists for a package build — the repository sync-snapshot
        # token stands in for base/head so the batch's provenance records WHICH
        # synced repo state produced it (§4.3.4).
        base_sha: snapshot,
        head_sha: snapshot
      )
      batch.update!(metadata: batch.metadata.merge("package_context" => package_context(tag, snapshot)))

      ::System::NativeModuleBuildOrchestrator.dispatch!(batch: batch)

      Result.new(ok?: true, batch: batch.reload)
    rescue StandardError => e
      Rails.logger.error("[PackageClosureBuildBridge] #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message, batch: nil)
    end

    private

    # §4.3.4 snapshot decision — thread the repository's sync snapshot into the
    # build so a package build records the exact synced state it built from.
    # PackageRepository carries no separate immutable-snapshot pointer, so its
    # last_synced_at (a compact UTC token) IS the snapshot identity; falls back
    # to a per-dispatch token when the repo was never synced (dev/test).
    def snapshot_token
      ts = @repository.respond_to?(:last_synced_at) ? @repository.last_synced_at : nil
      return ts.utc.strftime("%Y%m%dT%H%M%SZ") if ts

      "unsynced-#{SecureRandom.hex(4)}"
    end

    # Short, stable OCI tag for the closure. Mirrors the platform planner's
    # 7-char tag convention (module-forge treats a plan's oci_ref as a short
    # TAG, not a full reference); derived from repo + module set + snapshot so
    # re-materializing the same closure at the same snapshot reuses the tag.
    def build_tag(snapshot)
      key = "#{@repository.id}|#{@modules.map(&:name).sort.join(',')}|#{snapshot}"
      ::Digest::SHA256.hexdigest(key)[0, 7]
    end

    # One plan entry per module when a single architecture is requested —
    # byte-identical to the pre-multi-arch shape (no "architecture" key, no
    # tag suffix), so single-arch dispatch is unaffected by this method
    # existing at all. One entry per (module, arch) pair when 2+ are
    # requested: mmdebstrap can't produce a multi-arch rootfs in one
    # invocation the way platform modules' single buildx push can (that
    # push yields one OCI index ModuleOciIngestService fans out into N
    # ModuleArtifact rows at ingest time) — so a package multi-arch build is
    # genuinely N independent build units, each needing its own lease +
    # ci.package_build Task + OCI tag (arch-suffixed so two concurrent
    # builders never race the same mutable registry tag) + resulting
    # NodeModuleVersion/ModuleArtifact.
    def build_plan(tag)
      return @modules.map { |m| { module: m.name, oci_ref: tag } } if @architectures.size <= 1

      @modules.flat_map do |m|
        @architectures.map { |arch| { module: m.name, oci_ref: "#{tag}-#{arch}", architecture: arch } }
      end
    end

    def package_context(tag, snapshot)
      {
        "repository_id"     => @repository.id,
        "package_repo_url"  => @repository.base_url,
        "package_repo_kind" => @repository.kind,
        "apt_suite"         => (@repository.kind == "apt" ? @repository.suite : nil),
        "apt_components"    => (@repository.kind == "apt" ? Array(@repository.components).join(",") : nil),
        "rpm_releasever"    => (@repository.kind != "apt" ? @repository.releasever : nil),
        "gpg_key_armor"     => @repository.signing_key_armor,
        "architecture"      => @architectures.first,
        "architectures"     => @architectures,
        "apt_snapshot"      => snapshot,
        "tag"               => tag,
        "requested_by"      => @requested_by&.id,
        "modules"           => module_context
      }.compact
    end

    def module_context
      @modules.each_with_object({}) do |m, memo|
        link = m.package_module_link
        memo[m.name] = {
          "package_name"     => (link&.package_name || m.name),
          "architecture"     => (link&.architecture || @architectures.first),
          "mask"             => m.mask_text,
          "file_spec_source" => (link&.file_spec_source || "package_query")
        }
      end
    end
  end
end
