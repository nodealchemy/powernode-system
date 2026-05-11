# frozen_string_literal: true

# Re-materializes a NodeModule's closure when upstream package version drift
# is detected (or a CVE-affected dep needs an updated build). Reads the
# persisted PackageModuleLink.recommends_chosen to keep the closure
# deterministic across refreshes.
#
# Invoked by:
#   * Fleet Autonomy `package_module.refresh` skill executor when
#     PackageDriftSensor flags an outdated module
#   * MCP `system_refresh_package_module` operator action
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
