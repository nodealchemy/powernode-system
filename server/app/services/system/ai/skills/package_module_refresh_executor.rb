# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for refreshing a NodeModule when its source package
      # version drifts upstream. Triggered by PackageDriftSensor.
      #
      # Approval policy:
      #   * CVE-flagged refresh → auto-approve (4h cooldown)
      #   * Non-CVE drift refresh → human approval required
      # The CVE check happens in the Fleet Autonomy intervention policy
      # layer, not here — this executor unconditionally enqueues; the
      # autonomy framework gates whether the enqueue is allowed.
      class PackageModuleRefreshExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "package_module_refresh",
          description: "Re-materialize a NodeModule's source package when upstream drifts (replays persisted recommends_chosen for determinism)",
          category:    "devops",
          inputs: {
            package_module_link_id: { type: "string", required: true,
                                      description: "PackageModuleLink.id of the module to refresh" },
            force:                  { type: "boolean", required: false }
          },
          outputs: {
            enqueued:               :boolean,
            package_module_link_id: :string
          }
        )

        binds_to "Fleet Autonomy", "System Concierge", "CVE Responder"

        protected

        def perform(package_module_link_id:, force: false)
          link = ::System::PackageModuleLink
                   .joins(:node_module)
                   .where(system_node_modules: { account_id: @account.id })
                   .find_by(id: package_module_link_id)
          return failure("link not found or not accessible") unless link

          # IMP-594bfa5e1be5 — route through the server->worker seam. This used
          # to call `SystemPackageModuleRefreshJob.perform_async` directly, but
          # that class is defined only in the worker app (extensions/system/
          # worker/app/jobs/), which the Rails server never autoloads
          # (`rails runner 'defined?(SystemPackageModuleRefreshJob)'` => nil),
          # so the callers that reach THIS executor — the CVE Responder's
          # inline dispatch and the orchestrator's #dispatch_refreshes —
          # queued nothing (IMP-9b8d774298d5 made the output admit that; this
          # makes the delivery real).
          #
          # Not every door is fixed: Ai::Tools::SystemPackageRepositoryTool
          # #refresh_package_module (the MCP `system_refresh_package_module`
          # operator action) still does the same `perform_async if defined?`
          # and still answers `enqueued: true`. It is owned by another lane
          # and tracked separately — do not read this note as "all callers".
          #
          # WorkerJobEnqueuer writes the Sidekiq wire format straight into the
          # worker's Redis, the same way PackageRepositorySyncService.enqueue!
          # does. Wire contract of SystemPackageModuleRefreshJob#execute: args
          # [link_id, force] on the "system" queue. `retry` is deliberately
          # not passed: a raw LPUSH never consults the job's `sidekiq_options`,
          # so the payload carries WorkerJobEnqueuer::DEFAULT_RETRY, which is
          # the value the worker honours for this job.
          jid = ::System::WorkerJobEnqueuer.enqueue(
            job_class: "SystemPackageModuleRefreshJob",
            args:      [ link.id, !!force ],
            queue:     "system"
          )

          # The enqueuer is fail-soft (logs and returns nil on any Redis or
          # serialization error — its log line carries the real exception).
          # Nothing was queued then, and this executor's one job is to queue —
          # so that is a failure, not a success with a flag a caller may never
          # read. A BARE failure by contract: BaseSkillExecutor#failure's
          # `**extra` is the composition runner's rollback payload and takes
          # ONLY ids of resources this run created (see its note). This run
          # created nothing; naming the pre-existing link there would make the
          # failure outputs `present` and displace a retried step's genuine
          # last_outputs. `enqueued` stays reconstructible for callers: a
          # failure envelope has no :data, so `result.dig(:data, :enqueued)`
          # is nil, which is what the orchestrator already reads.
          unless jid
            return failure("refresh job could not be enqueued " \
                           "(worker seam returned no jid — see WorkerJobEnqueuer log)")
          end

          success(
            enqueued:               true,
            package_module_link_id: link.id,
            requires_approval:      false
          )
        end
      end
    end
  end
end
