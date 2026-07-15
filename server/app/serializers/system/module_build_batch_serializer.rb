# frozen_string_literal: true

module System
  # Serializer for System::ModuleBuildBatch (campaign 019f6084 inc2-A read
  # API). Two shapes:
  #
  #   as_summary — list-shape (index). Batch fields only, no per-module join.
  #   as_full    — detail-shape (show). Batch fields + AASM timestamp ladder +
  #     one row per module, joined from metadata["modules"] (build/lease
  #     state) x metadata["parity"] (shadow-batch diff result, when present)
  #     x member_tasks (System::Task status/timestamps) x CiRunnerLease
  #     (status/node_instance/runner_name) x the published ModuleArtifact
  #     (matched via NodeModuleVersion.config["git_tag"] == the module's tag).
  #
  # CRITICAL — never dumps raw metadata. batch.metadata["package_context"]
  # carries gpg_key_armor (the package repo's signing key — public-repo key
  # material, but still key material) plus repo coordinates; only a narrow,
  # explicitly-whitelisted subset (architecture/snapshot/tag) is exposed via
  # #package_context_summary. Every other field below is an explicit
  # attribute read, never metadata passthrough, so a future metadata key
  # can't leak by accident.
  class ModuleBuildBatchSerializer
    def initialize(batch)
      @batch = batch
    end

    def as_summary
      {
        id:               @batch.id,
        status:           @batch.status,
        trigger:          @batch.trigger,
        shadow:           @batch.shadow,
        base_sha:         @batch.base_sha,
        head_sha:         @batch.head_sha,
        module_slugs:     @batch.module_slugs,
        planned_count:    @batch.planned_count,
        succeeded_count:  @batch.succeeded_count,
        failed_count:     @batch.failed_count,
        active:           @batch.active?,
        finished:         @batch.finished?,
        package_context:  package_context_summary,
        created_at:       @batch.created_at,
        updated_at:       @batch.updated_at
      }
    end

    def as_full
      as_summary.merge(
        dispatched_at:         @batch.dispatched_at,
        awaiting_signature_at: @batch.awaiting_signature_at,
        publishing_at:         @batch.publishing_at,
        completed_at:          @batch.completed_at,
        failed_at:             @batch.failed_at,
        error_message:         @batch.error_message,
        modules:                module_rows
      )
    end

    private

    def account
      @account ||= @batch.account
    end

    # Narrow, explicit whitelist of metadata["package_context"] — see class
    # comment. nil for every non-"package"-trigger batch.
    def package_context_summary
      ctx = @batch.metadata["package_context"]
      return nil unless ctx.is_a?(Hash)

      {
        repository_id:     ctx["repository_id"],
        package_repo_kind: ctx["package_repo_kind"],
        architecture:      ctx["architecture"],
        architectures:     ctx["architectures"],
        snapshot:          ctx["apt_snapshot"],
        tag:               ctx["tag"]
      }
    end

    def module_state
      @batch.metadata["modules"] || {}
    end

    def parity_state
      @batch.metadata["parity"] || {}
    end

    # Keyed by task_id (each state entry's own "task_id" pointer), not by
    # re-deriving a lookup key from task.options — robust to both the
    # bare-slug state key (platform / single-arch package) and the compound
    # "slug@arch" key a multi-arch package plan entry uses (campaign
    # 019f6084 inc J; see NativeModuleBuildOrchestrator#load_modules_state)
    # without this serializer needing to know which shape a given batch is.
    def module_rows
      tasks_by_id    = index_tasks_by_id
      leases_by_task = index_leases_by_task(tasks_by_id.keys)

      module_state.map do |key, entry|
        task  = tasks_by_id[entry["task_id"]]
        lease = task && leases_by_task[task.id]
        slug  = entry["module"] || key

        {
          module:       slug,
          architecture: entry["architecture"],
          tag:          entry["tag"],
          state:        entry["state"],
          attempts:     entry["attempts"],
          error:        entry["error"],
          task:         task && serialize_task(task),
          lease:        lease && serialize_lease(lease),
          artifact:     serialize_artifact(slug, entry["tag"], architecture: entry["architecture"]),
          parity:       parity_state[key]
        }
      end
    end

    def index_tasks_by_id
      task_ids = module_state.values.map { |e| e["task_id"] }.compact
      return {} if task_ids.empty?

      ::System::Task.where(id: task_ids).index_by(&:id)
    end

    def index_leases_by_task(task_ids)
      return {} if task_ids.empty?

      ::System::CiRunnerLease.where(build_task_id: task_ids).index_by(&:build_task_id)
    end

    def serialize_task(task)
      {
        id:           task.id,
        status:       task.status,
        progress:     task.progress,
        started_at:   task.started_at,
        completed_at: task.completed_at,
        error_message: task.error_message
      }
    end

    def serialize_lease(lease)
      {
        id:               lease.id,
        status:           lease.status,
        node_instance_id: lease.node_instance_id,
        runner_name:      lease.runner_name
      }
    end

    # Finds the published NodeModuleVersion for this module+tag (same lookup
    # ModulePublicationProcessor#find_or_create_version uses — config's
    # "git_tag" carries the short tag the build published under) and
    # summarizes its ModuleArtifact. nil when the module hasn't published yet
    # (build still in flight / failed pre-sign).
    #
    # architecture: the row's own build-target arch (multi-arch package
    # builds — campaign 019f6084 inc J — give each arch its own tag/version,
    # see NativeModuleBuildOrchestrator#finalize_success!'s doc). When given,
    # picks that arch's own artifact rather than the amd64-preferred
    # default, so an arm64 row never shows an amd64 artifact's digest/size.
    def serialize_artifact(slug, tag, architecture: nil)
      return nil if tag.blank?

      node_module = account.system_node_modules.find_by(name: slug)
      return nil unless node_module

      version = ::System::NodeModuleVersion
                  .where(node_module: node_module)
                  .where("config->>'git_tag' = ?", tag)
                  .order(version_number: :desc)
                  .first
      return nil unless version

      artifact = if architecture.present?
                   version.module_artifacts.find { |a| a.architecture == architecture }
                 else
                   version.module_artifacts.find { |a| a.architecture == "amd64" } || version.module_artifacts.first
                 end

      {
        version_number:  version.version_number,
        promotion_state: version.promotion_state,
        oci_ref:      artifact&.oci_ref,
        oci_digest:   artifact&.oci_digest,
        size_bytes:   artifact&.size_bytes,
        architecture: artifact&.architecture,
        # cosign_bundle itself is never exposed — only whether one is
        # present. The bundle bytes stay server-side.
        signed:       artifact.present? && artifact.cosign_bundle.present?
      }
    end
  end
end
