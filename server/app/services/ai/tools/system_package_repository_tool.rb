# frozen_string_literal: true

module Ai
  module Tools
    # MCP tool surface for apt/rpm package repositories: CRUD, sync,
    # browse, dependency preview, and materialize-into-modules.
    #
    # Account scoping: actions auto-scope to current_user.account; shared
    # repos (account_id IS NULL) are visible to any account but only the
    # `manage_shared` permission allows mutation.
    class SystemPackageRepositoryTool < BaseTool
      REQUIRED_PERMISSION = "system.packages.view"

      ACTION_PERMISSIONS = {
        "system_list_package_repositories"   => "system.package_repositories.view",
        "system_get_package_repository"      => "system.package_repositories.view",
        "system_create_package_repository"   => "system.package_repositories.create",
        "system_update_package_repository"   => "system.package_repositories.update",
        "system_delete_package_repository"   => "system.package_repositories.delete",
        "system_sync_package_repository"     => "system.package_repositories.sync",

        "system_search_packages"             => "system.packages.search",
        "system_get_package"                 => "system.packages.view",

        "system_resolve_package_dependencies" => "system.packages.view",
        "system_create_module_from_package"   => "system.package_modules.create",
        "system_list_package_module_links"    => "system.package_modules.view",
        "system_refresh_package_module"       => "system.package_modules.refresh",

        # T2.B — AI-suggested architectures for materialization.
        # Read-only: gated by the same view permission as packages.
        "system_suggest_architectures_for_fleet" => "system.packages.view"
      }.freeze

      # Generic top-level definition consumed by BaseTool#validate_params!.
      # Per-action schemas live in #action_definitions; this advertises the
      # `action` discriminator + a free-form params surface.
      def self.definition
        {
          name: "system_package_repository",
          description: "Manage apt/rpm package repositories — sync, search, materialize, suggest archs",
          parameters: {
            action:                 { type: "string",  required: true,
                                       description: "One of: #{ACTION_PERMISSIONS.keys.join(', ')}" },
            repository_id:          { type: "string",  required: false },
            package_id:             { type: "string",  required: false },
            package_module_link_id: { type: "string",  required: false },
            attributes:             { type: "object",  required: false },
            architectures:          { type: "array",   required: false },
            recommends_selected:    { type: "array",   required: false },
            max_suggestions:        { type: "integer", required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_list_package_repositories" => {
            description: "List accessible apt/rpm package repositories (account-scoped + shared)",
            parameters: {
              kind: { type: "string", required: false },
              node_platform_id: { type: "string", required: false }
            }
          },
          "system_get_package_repository" => {
            description: "Fetch one package repository with sync status",
            parameters: { repository_id: { type: "string", required: true } }
          },
          "system_create_package_repository" => {
            description: "Register a new apt/rpm package repository. Set visibility='shared' for system-wide (requires manage_shared permission).",
            parameters: {
              name: { type: "string", required: true },
              kind: { type: "string", required: true },           # apt|rpm|dnf
              base_url: { type: "string", required: true },
              visibility: { type: "string", required: false },     # account|shared
              architectures: { type: "array", required: false },
              apt_config: { type: "object", required: false },    # { suite, components: [] }
              rpm_config: { type: "object", required: false },    # { releasever, gpgcheck, metalink }
              signing_key_armor: { type: "string", required: false },
              node_platform_id: { type: "string", required: false },
              description: { type: "string", required: false }
            }
          },
          "system_update_package_repository" => {
            description: "Update an apt/rpm package repository's configuration",
            parameters: {
              repository_id: { type: "string", required: true },
              attributes:    { type: "object", required: true }
            }
          },
          "system_delete_package_repository" => {
            description: "Delete a package repository (soft-delete linked Package metadata)",
            parameters: { repository_id: { type: "string", required: true } }
          },
          "system_sync_package_repository" => {
            description: "Trigger an immediate sync of the upstream apt/rpm index for this repository",
            parameters: { repository_id: { type: "string", required: true } }
          },
          "system_search_packages" => {
            description: "Search the synced apt/rpm package catalog by name/section/architecture",
            parameters: {
              q:             { type: "string", required: false },
              repository_id: { type: "string", required: false },
              section:       { type: "string", required: false },
              architecture:  { type: "string", required: false },
              page:          { type: "integer", required: false },
              per_page:      { type: "integer", required: false }
            }
          },
          "system_get_package" => {
            description: "Fetch package metadata including depends/recommends/provides",
            parameters: { package_id: { type: "string", required: true } }
          },
          "system_resolve_package_dependencies" => {
            description: "Preview the dependency closure of a package WITHOUT writes. Returns required closure + recommends candidates the operator can opt into.",
            parameters: {
              repository_id: { type: "string", required: true },
              package_name:  { type: "string", required: true },
              architecture:  { type: "string", required: true }
            }
          },
          "system_create_module_from_package" => {
            description: "Materialize a package + transitive deps as NodeModule rows, link them via ModuleDependency edges, and dispatch a CI build. Operator picks recommends_selected from the resolve_dependencies preview.",
            parameters: {
              repository_id:       { type: "string", required: true },
              package_name:        { type: "string", required: true },
              architectures:       { type: "array",  required: true },
              recommends_selected: { type: "array",  required: false },
              category_id:         { type: "string", required: false },
              dispatch_build:      { type: "boolean", required: false }
            }
          },
          "system_list_package_module_links" => {
            description: "List which NodeModules were materialized from which packages (auditable provenance)",
            parameters: {
              repository_id: { type: "string", required: false },
              auto_generated: { type: "boolean", required: false }
            }
          },
          "system_refresh_package_module" => {
            description: "Re-materialize a NodeModule from its source package when upstream drifts. Replays persisted recommends_chosen for deterministic refreshes.",
            parameters: {
              package_module_link_id: { type: "string", required: true },
              force: { type: "boolean", required: false }
            }
          },
          "system_suggest_architectures_for_fleet" => {
            description: "Suggest which canonical architectures to materialize a package for, based on the fleet's NodePlatform coverage and the repository's served archs. Returns suggested arches + per-arch rationale + confidence label. Frontend uses this to pre-populate the CreateModuleFromPackageModal multi-select.",
            parameters: {
              repository_id:   { type: "string",  required: true },
              max_suggestions: { type: "integer", required: false, description: "1-7 (default 4)" }
            }
          }
        }
      end

      protected

      def call(params)
        action = params[:action]
        return error_result("permission denied: #{required_perm_for(action)} required") unless action_permitted?(action)

        case action
        when "system_list_package_repositories"   then list_repositories(params)
        when "system_get_package_repository"      then get_repository(params)
        when "system_create_package_repository"   then create_repository(params)
        when "system_update_package_repository"   then update_repository(params)
        when "system_delete_package_repository"   then delete_repository(params)
        when "system_sync_package_repository"     then sync_repository(params)
        when "system_search_packages"             then search_packages(params)
        when "system_get_package"                 then get_package(params)
        when "system_resolve_package_dependencies" then resolve_dependencies(params)
        when "system_create_module_from_package"  then create_module_from_package(params)
        when "system_list_package_module_links"   then list_package_module_links(params)
        when "system_refresh_package_module"      then refresh_package_module(params)
        when "system_suggest_architectures_for_fleet" then suggest_architectures_for_fleet(params)
        else error_result("Unknown action: #{action}")
        end
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      rescue ::System::PackageModuleMaterializer::NamingConflictError => e
        error_result(e.message)
      end

      private

      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      def scoped_repos
        ::System::PackageRepository.accessible_to(@user&.account)
      end

      # === Repositories ===

      def list_repositories(params)
        repos = scoped_repos.enabled
        repos = repos.where(kind: params[:kind]) if params[:kind].present?
        repos = repos.where(node_platform_id: params[:node_platform_id]) if params[:node_platform_id].present?
        success_result(
          package_repositories: repos.order(:name).map { |r| serialize_repo(r) }
        )
      end

      def get_repository(params)
        repo = scoped_repos.find(params[:repository_id])
        success_result(package_repository: serialize_repo(repo, detail: true))
      end

      def create_repository(params)
        visibility = params[:visibility] || "account"
        if visibility == "shared" && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: system.package_repositories.manage_shared required for shared repositories")
        end

        repo = ::System::PackageRepository.new(
          name:                  params[:name],
          description:           params[:description],
          kind:                  params[:kind],
          visibility:            visibility,
          base_url:              params[:base_url],
          architectures:         Array(params[:architectures]).presence || ["amd64"],
          apt_config:            params[:apt_config] || {},
          rpm_config:            params[:rpm_config] || {},
          signing_key_armor:     params[:signing_key_armor],
          node_platform_id:      params[:node_platform_id],
          account:               (visibility == "shared" ? nil : @user&.account),
          created_by:            @user
        )
        if repo.save
          success_result(package_repository: serialize_repo(repo))
        else
          error_result(repo.errors.full_messages.join("; "))
        end
      end

      def update_repository(params)
        repo = scoped_repos.find(params[:repository_id])
        if repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot mutate shared repository without manage_shared")
        end

        attrs = (params[:attributes] || {}).slice(
          "name", "description", "base_url", "architectures",
          "apt_config", "rpm_config", "signing_key_armor",
          "node_platform_id", "priority", "enabled"
        )
        if repo.update(attrs)
          success_result(package_repository: serialize_repo(repo))
        else
          error_result(repo.errors.full_messages.join("; "))
        end
      end

      def delete_repository(params)
        repo = scoped_repos.find(params[:repository_id])
        if repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot delete shared repository without manage_shared")
        end

        if repo.destroy
          success_result(deleted: true, repository_id: repo.id)
        else
          error_result(repo.errors.full_messages.join("; "))
        end
      end

      def sync_repository(params)
        repo = scoped_repos.find(params[:repository_id])
        result = ::System::PackageRepositorySyncService.call(repository: repo)
        success_result(
          ok:            result.success?,
          upserted:      result.upserted,
          obsoleted:     result.obsoleted,
          package_count: result.package_count,
          error:         result.error
        )
      end

      # === Packages ===

      def search_packages(params)
        repos = scoped_repos.enabled
        repos = repos.where(id: params[:repository_id]) if params[:repository_id].present?
        scope = ::System::Package.live.where(package_repository_id: repos.pluck(:id))
        scope = scope.where("name ILIKE ?", "%#{params[:q]}%") if params[:q].present?
        scope = scope.where(section_or_group: params[:section]) if params[:section].present?
        scope = scope.where(architecture: params[:architecture]) if params[:architecture].present?
        per_page = [[params[:per_page].to_i, 50].max, 200].min
        page = [params[:page].to_i, 1].max
        rows = scope.order(:name, :architecture).limit(per_page).offset((page - 1) * per_page)
        success_result(
          packages: rows.map { |p| serialize_package(p) },
          page: page, per_page: per_page, total: scope.count
        )
      end

      def get_package(params)
        pkg = ::System::Package.find(params[:package_id])
        unless scoped_repos.exists?(id: pkg.package_repository_id)
          return error_result("package not in accessible repository")
        end

        success_result(package: serialize_package(pkg, detail: true))
      end

      def resolve_dependencies(params)
        repo = scoped_repos.find(params[:repository_id])
        resolver = ::System::PackageDependencyResolver.new(
          repositories: [repo],
          architecture: params[:architecture]
        )
        preview = resolver.preview(root_package_name: params[:package_name])

        success_result(
          required_packages: preview.required_packages.map { |p| { name: p.name, version: p.version, installed_size: p.installed_size_bytes } },
          required_edges:    preview.required_edges.map { |e| { from: e.from_package.name, to: e.to_package.name, type: e.dep_type, constraint: e.constraint } },
          recommends_candidates: preview.recommends_candidates.map { |c|
            {
              from: c.from_package.name,
              to: c.to_package.name,
              summary: c.to_package.summary,
              installed_size: c.installed_size_bytes,
              transitive_required_if_chosen: c.transitive_required_if_chosen.map(&:name)
            }
          },
          suggests_candidates: preview.suggests_candidates.map { |c| { from: c.from_package.name, to: c.to_package.name } },
          alternatives_chosen: preview.alternatives_chosen,
          warnings: preview.warnings,
          errors: preview.errors
        )
      end

      def create_module_from_package(params)
        repo = scoped_repos.find(params[:repository_id])
        category = params[:category_id].present? ?
                     @user.account.system_node_module_categories.find_by(id: params[:category_id]) : nil
        result = ::System::PackageModuleMaterializer.call(
          repository:          repo,
          package_name:        params[:package_name],
          architectures:       Array(params[:architectures]),
          account:             @user.account,
          requested_by_user:   @user,
          recommends_selected: Array(params[:recommends_selected]),
          category:            category,
          dispatch_build:      params.fetch(:dispatch_build, true)
        )

        if result.success?
          success_result(
            top_level_module:    result.top_level_module ? mod_summary(result.top_level_module) : nil,
            dependency_modules:  result.dependency_modules.map { |m| mod_summary(m) },
            recommends_modules:  result.recommends_modules.map { |m| mod_summary(m) },
            dependencies_created: result.dependencies_created.size,
            build_dispatches:    result.build_dispatches,
            warnings:            result.warnings
          )
        else
          error_result("Materialization failed: #{result.errors.join('; ')}")
        end
      end

      def list_package_module_links(params)
        links = ::System::PackageModuleLink
                  .joins(:node_module)
                  .where(system_node_modules: { account_id: @user&.account_id })
        links = links.where(package_repository_id: params[:repository_id]) if params[:repository_id].present?
        unless params[:auto_generated].nil?
          links = links.where(auto_generated: params[:auto_generated])
        end
        success_result(
          links: links.order(created_at: :desc).limit(200).map { |l|
            {
              id: l.id,
              node_module_id: l.node_module_id,
              package_name: l.package_name,
              package_version: l.package_version,
              architecture: l.architecture,
              repository_id: l.package_repository_id,
              auto_generated: l.auto_generated,
              recommends_chosen: l.recommends_chosen,
              last_synced_at: l.last_synced_at
            }
          }
        )
      end

      def refresh_package_module(params)
        # Trigger via worker job — refresh involves CI dispatch and is async
        SystemPackageModuleRefreshJob.perform_async(
          params[:package_module_link_id],
          params[:force] || false
        ) if defined?(SystemPackageModuleRefreshJob)
        success_result(
          enqueued: true,
          package_module_link_id: params[:package_module_link_id]
        )
      end

      # T2.B — thin MCP wrapper over the skill executor. Keeps the
      # ranking + rationale logic in one place (the executor) so direct
      # skill invocation and MCP invocation return identical shapes.
      def suggest_architectures_for_fleet(params)
        executor = ::System::Ai::Skills::SuggestArchitecturesForFleetExecutor.new(
          account: @user&.account, agent: @agent, user: @user
        )
        result = executor.execute(
          repository_id:   params[:repository_id],
          max_suggestions: params[:max_suggestions] || ::System::Ai::Skills::SuggestArchitecturesForFleetExecutor::DEFAULT_MAX_SUGGESTIONS
        )
        result[:success] ? success_result(**result[:data]) : error_result(result[:error])
      end

      # === Serializers ===

      def serialize_repo(repo, detail: false)
        base = {
          id: repo.id, name: repo.name, kind: repo.kind, visibility: repo.visibility,
          base_url: repo.base_url, architectures: Array(repo.architectures),
          enabled: repo.enabled, sync_status: repo.sync_status, last_synced_at: repo.last_synced_at,
          package_count: repo.package_count, shared: repo.shared?,
          node_platform_id: repo.node_platform_id
        }
        base[:apt_config] = repo.apt_config if detail
        base[:rpm_config] = repo.rpm_config if detail
        base
      end

      def serialize_package(pkg, detail: false)
        base = {
          id: pkg.id, name: pkg.name, version: pkg.version, architecture: pkg.architecture,
          section: pkg.section_or_group, summary: pkg.summary,
          installed_size: pkg.installed_size_bytes, download_size: pkg.download_size_bytes,
          repository_id: pkg.package_repository_id
        }
        if detail
          base[:description] = pkg.description
          base[:depends] = pkg.depends
          base[:recommends] = pkg.recommends
          base[:provides] = pkg.provides
          base[:conflicts] = pkg.conflicts
          base[:maintainer] = pkg.maintainer
          base[:license] = pkg.license
          base[:homepage] = pkg.homepage
        end
        base
      end

      def mod_summary(m)
        { id: m.id, name: m.name, auto_generated: m.auto_generated, public: m.public }
      end
    end
  end
end
