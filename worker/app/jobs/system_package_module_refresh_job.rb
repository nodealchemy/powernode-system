# frozen_string_literal: true

# Re-materializes a NodeModule's closure when upstream package version drift
# is detected (or a CVE-affected dep needs an updated build). Reads the
# persisted PackageModuleLink.recommends_chosen to keep the closure
# deterministic across refreshes.
#
# Invoked by:
#   * Fleet Autonomy `package_module.refresh` skill executor when
#     PackageDriftSensor flags an outdated module, and by the CVE remediation
#     orchestrator through the same executor (IMP-594bfa5e1be5).
#   * the MCP `system_refresh_package_module` operator action, which since
#     IMP-915d1dbdcdba delegates to that same executor rather than calling
#     `perform_async if defined?(...)` from the Rails server, where the guard
#     never fired and the action queued nothing while answering
#     `enqueued: true`.
#
# EVERY caller reaches this job over the server->worker seam
# (System::WorkerJobEnqueuer LPUSHes the Sidekiq wire format into the worker's
# Redis). The server cannot `perform_async`: this class exists only in the
# worker app, which the Rails server never autoloads.
class SystemPackageModuleRefreshJob < BaseJob
  sidekiq_options queue: "system", retry: 2

  # job args: [package_module_link_id, force]
  def execute(package_module_link_id, force = false)
    log_info("[PackageModuleRefresh] start", link_id: package_module_link_id, force: force)

    response = api_client.post(
      "/api/v1/system/worker_api/package_modules/refresh",
      {
        package_module_link_id: package_module_link_id,
        force:                  force
      }
    )
    data = response["data"] || {}

    if data["success"]
      log_info("[PackageModuleRefresh] done",
               new_version: data["new_version_number"],
               new_recommends_available: Array(data["new_recommends_available"]).size,
               dispatch_count: Array(data["build_dispatches"]).size)
    else
      log_warn("[PackageModuleRefresh] reported failure", errors: data["errors"])
    end
    data
  rescue BackendApiClient::ApiError => e
    log_error("[PackageModuleRefresh] API error", e)
    raise
  end
end
