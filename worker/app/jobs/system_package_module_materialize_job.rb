# frozen_string_literal: true

# Materializes a package + its transitive dependency closure into NodeModule
# rows and dispatches a Gitea Actions build of the closure.
#
# Invoked by:
#   * MCP `system_create_module_from_package` action
#   * Fleet Autonomy `package_module.create` skill executor
#
# The actual work happens server-side via PackageModuleMaterializer (worker
# has no DB access per worker/CLAUDE.md). The worker provides queue isolation
# + retry semantics for long-running CI dispatches.
class SystemPackageModuleMaterializeJob < BaseJob
  sidekiq_options queue: "system", retry: 2

  # job args: [account_id, repository_id, package_name, architectures_array,
  #            recommends_selected_array, requested_by_user_id, category_id_or_nil]
  def execute(account_id, repository_id, package_name, architectures,
              recommends_selected, user_id, category_id)
    log_info("[PackageModuleMaterialize] start",
             account: account_id, repo: repository_id, package: package_name,
             archs: architectures, recommends_count: Array(recommends_selected).size)

    response = api_client.post(
      "/api/v1/system/worker_api/package_modules/materialize",
      {
        account_id:          account_id,
        repository_id:       repository_id,
        package_name:        package_name,
        architectures:       architectures,
        recommends_selected: recommends_selected,
        requested_by_user_id: user_id,
        category_id:         category_id
      }
    )
    data = response["data"] || {}

    if data["success"]
      log_info("[PackageModuleMaterialize] done",
               top_module_id: data["top_level_module_id"],
               dep_count:     data["dependency_count"],
               dispatch_count: Array(data["build_dispatches"]).size)
    else
      log_warn("[PackageModuleMaterialize] reported failure",
               errors: data["errors"])
    end
    data
  rescue BackendApiClient::ApiError => e
    log_error("[PackageModuleMaterialize] API error", e)
    raise # let Sidekiq retry
  end
end
