# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for package-module materialization + refresh.
        # Invoked by SystemPackageModuleMaterializeJob and SystemPackageModuleRefreshJob.
        # Materialization is the heavy work (resolver + N NodeModule creates +
        # ModuleDependency edges + CI dispatch); the worker provides retry +
        # queue isolation around it.
        class PackageModulesController < BaseController
          def materialize
            authorize_worker_permission!("system.package_modules.create")
            return if performed?

            repo    = ::System::PackageRepository.find(params[:repository_id])
            account = ::Account.find(params[:account_id])
            user    = ::User.find(params[:requested_by_user_id])
            category = params[:category_id].present? ?
                        ::System::NodeModuleCategory.find_by(id: params[:category_id]) : nil

            result = ::System::PackageModuleMaterializer.call(
              repository:          repo,
              package_name:        params[:package_name],
              architectures:       Array(params[:architectures]),
              account:             account,
              requested_by_user:   user,
              recommends_selected: Array(params[:recommends_selected]),
              category:            category,
              dispatch_build:      true
            )

            render_success(
              success:               result.success?,
              top_level_module_id:   result.top_level_module&.id,
              dependency_count:      result.dependency_modules.size,
              recommends_count:      result.recommends_modules.size,
              dependencies_created:  result.dependencies_created.size,
              build_dispatches:      result.build_dispatches,
              warnings:              result.warnings,
              errors:                result.errors
            )
          end

          def refresh
            authorize_worker_permission!("system.package_modules.refresh")
            return if performed?

            link = ::System::PackageModuleLink.find(params[:package_module_link_id])
            mod = link.node_module
            repo = link.package_repository

            # Look up the latest upstream version
            adapter = ::System::PackageAdapters.for(kind: repo.kind)
            upstream = ::System::Package.live.find_by(
              package_repository_id: repo.id,
              name:                  link.package_name,
              architecture:          link.architecture
            )
            unless upstream
              return render_success(success: false, errors: ["upstream package not in synced index"])
            end

            cmp = adapter.compare_versions(upstream.version, link.package_version)
            if cmp <= 0 && !params[:force]
              return render_success(
                success: false,
                errors:  ["upstream version #{upstream.version} not newer than current #{link.package_version}; use force=true to override"]
              )
            end

            # Detect new recommends that weren't available at original materialize
            new_recommends = detect_new_recommends_available(link, upstream, repo)

            # Re-materialize using the persisted recommends_chosen
            result = ::System::PackageModuleMaterializer.call(
              repository:          repo,
              package_name:        link.package_name,
              architectures:       [link.architecture],
              account:             mod.account,
              requested_by_user:   ::User.find_by(id: link.created_by_id) || mod.account.users.first,
              recommends_selected: Array(link.recommends_chosen),
              dispatch_build:      true
            )

            render_success(
              success:                   result.success?,
              new_version_number:        result.top_level_module&.current_version_number,
              new_recommends_available:  new_recommends,
              build_dispatches:          result.build_dispatches,
              warnings:                  result.warnings,
              errors:                    result.errors
            )
          end

          private

          # Returns Array<String> of package names that are NEW Recommends in
          # the upstream package since the link was last materialized. The
          # operator can re-materialize to opt in; refresh itself does not
          # silently add them (matches `feedback_clean_implementations`
          # principle of deterministic behavior).
          def detect_new_recommends_available(link, upstream, repo)
            existing_recommends = Array(upstream.recommends).flat_map do |group|
              group.map { |alt| alt["name"] }
            end.compact.uniq
            # Persisted: link.recommends_chosen — the operator's pick set.
            # If upstream now lists recommends that aren't in the original
            # closure's recommends set, surface them.
            existing_recommends - Array(link.recommends_chosen)
          end
        end
      end
    end
  end
end
