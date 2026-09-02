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

        # M:N platform linkage. Same gating as update — link/unlink are
        # mutations of the repo's compatibility set, not new authority.
        "system_link_repository_platform"    => "system.package_repositories.update",
        "system_unlink_repository_platform"  => "system.package_repositories.update",

        "system_search_packages"             => "system.packages.search",
        "system_discover_packages"           => "system.packages.view",
        "system_get_package"                 => "system.packages.view",

        "system_resolve_package_dependencies" => "system.packages.view",
        "system_create_module_from_package"   => "system.package_modules.create",
        "system_list_package_module_links"    => "system.package_modules.view",
        "system_refresh_package_module"       => "system.package_modules.refresh",

        # T2.B — AI-suggested architectures for materialization.
        # Read-only: gated by the same view permission as packages.
        "system_suggest_architectures_for_fleet" => "system.packages.view"
      }.freeze

      # APO-1a (IMP-1e58753b3b6c) — governance declarations for every action
      # this tool advertises. NON-ENFORCING: `mutating:` alone leaves
      # BaseTool#gated_action? false, so #execute still routes to #call and
      # behaviour is unchanged. Gate wiring (categories/executors) is APO-1e.
      declare_action "system_create_module_from_package", mutating: true
      declare_action "system_create_package_repository", mutating: true
      declare_action "system_delete_package_repository", mutating: true
      declare_action "system_discover_packages", mutating: false
      declare_action "system_get_package", mutating: false
      declare_action "system_get_package_repository", mutating: false
      declare_action "system_link_repository_platform", mutating: true
      declare_action "system_list_package_module_links", mutating: false
      declare_action "system_list_package_repositories", mutating: false
      declare_action "system_refresh_package_module", mutating: true
      declare_action "system_resolve_package_dependencies", mutating: false
      declare_action "system_search_packages", mutating: false
      declare_action "system_suggest_architectures_for_fleet", mutating: false
      declare_action "system_sync_package_repository", mutating: true
      declare_action "system_unlink_repository_platform", mutating: true
      declare_action "system_update_package_repository", mutating: true

      # Generic top-level definition consumed by BaseTool#validate_params!.
      # Per-action schemas live in #action_definitions; this advertises the
      # `action` discriminator + a free-form params surface.
      def self.definition
        {
          name: "system_package_repository",
          description: "Manage apt/rpm package repositories — sync, search, materialize, link platforms, suggest archs",
          parameters: {
            action:                 { type: "string",  required: true, enum: action_definitions.keys,
                                       description: "One of: #{ACTION_PERMISSIONS.keys.join(', ')}" },
            repository_id:          { type: "string",  required: false },
            package_id:             { type: "string",  required: false },
            package_module_link_id: { type: "string",  required: false },
            node_platform_id:       { type: "string",  required: false },
            attributes:             { type: "object",  required: false },
            architectures:          { type: "array",   required: false, items: { type: "string" } },
            node_platform_ids:      { type: "array",   required: false, items: { type: "string" } },
            recommends_selected:    { type: "array",   required: false, items: { type: "string" } },
            max_suggestions:        { type: "integer", required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_list_package_repositories" => {
            description: "List accessible apt/rpm package repositories (account-scoped + shared). Filter by platform via node_platform_ids — repos linked to any of the supplied platforms are returned.",
            parameters: {
              kind: { type: "string", required: false, enum: ::System::PackageRepository::KINDS,
                                      description: "Filter by repository kind: apt, rpm, or dnf" },
              node_platform_ids: { type: "array", required: false, items: { type: "string" }, description: "Array of NodePlatform UUIDs; repos linked to ANY are returned" }
            }
          },
          "system_get_package_repository" => {
            description: "Fetch one package repository with sync status",
            parameters: { repository_id: { type: "string", required: true, description: "UUID of the package repository to fetch" } }
          },
          "system_create_package_repository" => {
            description: "Register a new apt/rpm package repository. Set visibility='shared' for system-wide (requires manage_shared permission). Optionally pre-link NodePlatforms via node_platform_ids.",
            parameters: {
              name: { type: "string", required: true, description: "Human-readable repository name" },
              kind: { type: "string", required: true, enum: ::System::PackageRepository::KINDS,
                                      description: "Repository kind: apt, rpm, or dnf" },
              base_url: { type: "string", required: true, description: "Upstream repository base URL to sync from" },
              visibility: { type: "string", required: false, description: "'account' (default, account-scoped) or 'shared' (system-wide; requires manage_shared)" },     # account|shared
              architectures: { type: "array", required: false, items: { type: "string" }, description: "Canonical arch names this repo serves (defaults to ['amd64'])" },
              apt_config: { type: "object", required: false, description: "APT-specific config: { suite, components: [] }" },    # { suite, components: [] }
              rpm_config: { type: "object", required: false, description: "RPM/DNF-specific config: { releasever, gpgcheck, metalink }" },    # { releasever, gpgcheck, metalink }
              signing_key_armor: { type: "string", required: false, description: "ASCII-armored GPG public key used to verify the repository signature" },
              node_platform_ids: { type: "array", required: false, items: { type: "string" }, description: "NodePlatform UUIDs to link on create" },
              description: { type: "string", required: false, description: "Optional free-text description of the repository" }
            }
          },
          "system_update_package_repository" => {
            description: "Update an apt/rpm package repository's configuration",
            parameters: {
              repository_id: { type: "string", required: true, description: "UUID of the package repository to update" },
              attributes:    { type: "object", required: true, description: "Fields to update: name, description, base_url, architectures, apt_config, rpm_config, signing_key_armor, priority, enabled, node_platform_ids" }
            }
          },
          "system_delete_package_repository" => {
            description: "Delete a package repository (soft-delete linked Package metadata)",
            parameters: { repository_id: { type: "string", required: true, description: "UUID of the package repository to delete" } }
          },
          "system_sync_package_repository" => {
            description: "Enqueue a background sync of the upstream apt/rpm index for this repository (returns immediately; poll get_package_repository for sync_status)",
            parameters: {
              repository_id: { type: "string", required: true, description: "UUID of the package repository to sync" },
              force:         { type: "boolean", required: false, description: "Re-write every package row + bypass the unchanged-fingerprint fast-path and the mass-obsoletion guard (metadata refresh / override a partial-upstream guard trip)" }
            }
          },
          "system_link_repository_platform" => {
            description: "Link a NodePlatform to a PackageRepository. Cross-account validated — account-scoped repos can only link platforms in the same account; shared repos can link any platform.",
            parameters: {
              repository_id:    { type: "string", required: true, description: "UUID of the package repository to link" },
              node_platform_id: { type: "string", required: true, description: "UUID of the NodePlatform to link to the repository" }
            }
          },
          "system_unlink_repository_platform" => {
            description: "Remove a NodePlatform ↔ PackageRepository link. Idempotent — returns linked:false whether or not the link existed.",
            parameters: {
              repository_id:    { type: "string", required: true, description: "UUID of the package repository to unlink" },
              node_platform_id: { type: "string", required: true, description: "UUID of the NodePlatform to unlink from the repository" }
            }
          },
          "system_search_packages" => {
            description: "Search the synced apt/rpm package catalog. Supports name+description trigram + semantic embedding ranking (mode: lexical|semantic|hybrid, default hybrid). Filters: kind (apt/rpm/dnf), repository_ids[], architectures[] (canonical, cross-kind expanded), sections[], license, provides (capability lookup).",
            parameters: {
              q:              { type: "string",  required: false, description: "Search query matched against package name + description" },
              mode:           { type: "string",  required: false, enum: ::System::PackageSearchService::MODES,
                                                   description: "lexical | semantic | hybrid (default hybrid; blank q forces lexical)" },
              sort:           { type: "string",  required: false, description: "relevance | name | updated (default relevance)" },
              repository_id:  { type: "string",  required: false, description: "Back-compat: singular form of repository_ids" },
              repository_ids: { type: "array",   required: false, items: { type: "string" }, description: "Restrict search to these PackageRepository UUIDs" },
              kind:           { type: "string",  required: false, enum: ::System::PackageRepository::KINDS,
                                                   description: "apt | rpm | dnf" },
              architecture:   { type: "string",  required: false, description: "Back-compat: singular form of architectures" },
              architectures:  { type: "array",   required: false, items: { type: "string" }, description: "Canonical arch names (amd64, arm64) — cross-kind expanded" },
              section:        { type: "string",  required: false, description: "Back-compat: singular form of sections" },
              sections:       { type: "array",   required: false, items: { type: "string" }, description: "Filter by package section/group names" },
              license:        { type: "string",  required: false, description: "Filter by package license identifier" },
              provides:       { type: "string",  required: false, description: "Capability name — finds packages whose name=capability OR provides @> [{name: capability}]" },
              page:           { type: "integer", required: false, description: "1-based page number for paginated results" },
              per_page:       { type: "integer", required: false, description: "Number of results per page" }
            }
          },
          "system_discover_packages" => {
            description: "Intent-based package discovery — describe a capability ('reverse proxy', 'distributed cache') and get ranked packages from accessible repositories. Pure semantic ranking via pgvector cosine distance. Use system_search_packages instead when you already know the package name.",
            parameters: {
              intent:         { type: "string",  required: true,  description: "Free-text capability description — what the package should do" },
              repository_ids: { type: "array",   required: false, items: { type: "string" }, description: "Restrict discovery to these PackageRepository UUIDs" },
              kind:           { type: "string",  required: false, enum: ::System::PackageRepository::KINDS,
                                                   description: "apt | rpm | dnf" },
              architectures:  { type: "array",   required: false, items: { type: "string" }, description: "Canonical arch names — cross-kind expanded" },
              license:        { type: "string",  required: false, description: "Filter by package license identifier" },
              top_k:          { type: "integer", required: false, description: "Max results (1-50, default 10)" }
            }
          },
          "system_get_package" => {
            description: "Fetch package metadata including depends/recommends/provides",
            parameters: { package_id: { type: "string", required: true, description: "UUID of the package to fetch" } }
          },
          "system_resolve_package_dependencies" => {
            description: "Preview the dependency closure of a package WITHOUT writes. Returns required closure + recommends candidates the operator can opt into.",
            parameters: {
              repository_id: { type: "string", required: true, description: "UUID of the package repository to resolve against" },
              package_name:  { type: "string", required: true, description: "Name of the root package whose dependency closure to preview" },
              architecture:  { type: "string", required: true, description: "Canonical architecture to resolve dependencies for (e.g. amd64)" }
            }
          },
          "system_create_module_from_package" => {
            description: "Materialize a package + transitive deps as NodeModule rows, link them via ModuleDependency edges, and dispatch a CI build. Operator picks recommends_selected from the resolve_dependencies preview.",
            parameters: {
              repository_id:       { type: "string", required: true, description: "UUID of the source package repository" },
              package_name:        { type: "string", required: true, description: "Name of the package to materialize into a NodeModule" },
              architectures:       { type: "array",  required: true, items: { type: "string" }, description: "Canonical arch names to build the module for" },
              recommends_selected: { type: "array",  required: false, items: { type: "string" }, description: "Recommended package names (from resolve_dependencies preview) to opt into" },
              category_id:         { type: "string", required: false, description: "UUID of the NodeModuleCategory to assign the new module to" },
              dispatch_build:      { type: "boolean", required: false, description: "Whether to dispatch a CI build after materialization (default true)" }
            }
          },
          "system_list_package_module_links" => {
            description: "List which NodeModules were materialized from which packages (auditable provenance)",
            parameters: {
              repository_id: { type: "string", required: false, description: "Filter links by source PackageRepository UUID" },
              auto_generated: { type: "boolean", required: false, description: "Filter by whether the link was auto-generated (true) or operator-created (false)" }
            }
          },
          "system_refresh_package_module" => {
            description: "Re-materialize a NodeModule from its source package when upstream drifts. Replays persisted recommends_chosen for deterministic refreshes.",
            parameters: {
              package_module_link_id: { type: "string", required: true, description: "UUID of the PackageModuleLink to refresh" },
              force: { type: "boolean", required: false, description: "Force re-materialization even when no upstream drift is detected" }
            }
          },
          "system_suggest_architectures_for_fleet" => {
            description: "Suggest which canonical architectures to materialize a package for, based on the fleet's NodePlatform coverage and the repository's served archs. Returns suggested arches + per-arch rationale + confidence label. Frontend uses this to pre-populate the CreateModuleFromPackageModal multi-select.",
            parameters: {
              repository_id:   { type: "string",  required: true, description: "UUID of the package repository whose served archs constrain suggestions" },
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
        when "system_link_repository_platform"    then link_repository_platform(params)
        when "system_unlink_repository_platform"  then unlink_repository_platform(params)
        when "system_search_packages"             then search_packages(params)
        when "system_discover_packages"           then discover_packages(params)
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

      # === Permission gating ===
      # Two bypasses, both EXPLICIT (IMP-54bf2643f542, sibling of the
      # SystemFleetTool fix IMP-9030413bc292 — its ladder carries the full note):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — that per-tool grant
      #                        stands in for authorization. It is NAME-scoped
      #                        while this tool runs the action the caller
      #                        supplies, so treat it as provenance, not a fence.
      #
      # This used to be one implicit `@user.nil?` bypass, whose premise — that
      # MCP callers always carry a user — predates instance principals and is
      # false for them, so an instance skipped this map entirely. A nil user
      # with neither flag now fails CLOSED.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
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
        platform_ids = Array(params[:node_platform_ids]).compact_blank
        if platform_ids.any?
          repos = repos.joins(:package_repository_platforms)
                       .where(system_package_repository_platforms: { node_platform_id: platform_ids })
                       .distinct
        end
        success_result(
          package_repositories: repos.includes(:node_platforms).order(:name).map { |r| serialize_repo(r) }
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

        platform_ids = Array(params[:node_platform_ids]).compact_blank
        repo = ::System::PackageRepository.new(
          name:                  params[:name],
          description:           params[:description],
          kind:                  params[:kind],
          visibility:            visibility,
          base_url:              params[:base_url],
          architectures:         Array(params[:architectures]).presence || [ "amd64" ],
          apt_config:            params[:apt_config] || {},
          rpm_config:            params[:rpm_config] || {},
          signing_key_armor:     params[:signing_key_armor],
          account:               (visibility == "shared" ? nil : @user&.account),
          created_by:            @user
        )
        ::System::PackageRepository.transaction do
          repo.save!
          platform_ids.each { |pid| repo.package_repository_platforms.create!(node_platform_id: pid) }
        end
        success_result(package_repository: serialize_repo(repo, detail: true))
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      end

      def update_repository(params)
        repo = scoped_repos.find(params[:repository_id])
        if repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot mutate shared repository without manage_shared")
        end

        attrs = (params[:attributes] || {}).slice(
          "name", "description", "base_url", "architectures",
          "apt_config", "rpm_config", "signing_key_armor",
          "priority", "enabled"
        )
        # node_platform_ids — if explicitly supplied, reconcile the link
        # set; absent means "no change".
        new_platform_ids = params[:attributes]&.dig("node_platform_ids")
        ::System::PackageRepository.transaction do
          repo.update!(attrs) if attrs.any?
          unless new_platform_ids.nil?
            sync_platform_links!(repo, Array(new_platform_ids).compact_blank.map(&:to_s))
          end
        end
        success_result(package_repository: serialize_repo(repo, detail: true))
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      end

      def sync_platform_links!(repo, ids)
        current = repo.package_repository_platforms.pluck(:node_platform_id).map(&:to_s)
        (ids - current).each { |pid| repo.package_repository_platforms.create!(node_platform_id: pid) }
        remove_ids = current - ids
        repo.package_repository_platforms.where(node_platform_id: remove_ids).destroy_all if remove_ids.any?
      end

      def link_repository_platform(params)
        repo = scoped_repos.find(params[:repository_id])
        if repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot link platform on shared repository without manage_shared")
        end
        platform = ::System::NodePlatform.find(params[:node_platform_id])

        link = repo.package_repository_platforms.find_or_initialize_by(node_platform_id: platform.id)
        if link.persisted?
          return success_result(repository_id: repo.id, node_platform_id: platform.id, linked: true, idempotent: true)
        end

        if link.save
          success_result(repository_id: repo.id, node_platform_id: platform.id, linked: true)
        else
          error_result(link.errors.full_messages.join("; "))
        end
      end

      def unlink_repository_platform(params)
        repo = scoped_repos.find(params[:repository_id])
        if repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot unlink platform on shared repository without manage_shared")
        end

        deleted = repo.package_repository_platforms
                      .where(node_platform_id: params[:node_platform_id])
                      .destroy_all
        success_result(
          repository_id: repo.id,
          node_platform_id: params[:node_platform_id],
          linked: false,
          removed: deleted.size
        )
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
        repo  = scoped_repos.find(params[:repository_id])
        force = ::ActiveModel::Type::Boolean.new.cast(params[:force]) || false
        # IMP-c90ba4ec46da — `force` switches OFF the sync service's
        # mass-obsoletion guard, so a forced sync of a SHARED repo can
        # soft-delete an arbitrary fraction of a catalog every tenant reads.
        # `scoped_repos` is accessible_to(account), which admits every shared
        # repo to every account, so the forced path needs manage_shared — the
        # same discriminator every other mutating action here uses. An UNFORCED
        # sync stays open to a plain `sync` holder (benign idempotent refresh),
        # and an account-scoped repo's owner may force (own catalog only).
        if force && repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
          return error_result("permission denied: cannot force-sync a shared repository without manage_shared")
        end

        # Async: a full sync is minutes long — enqueue it (→ detached
        # out-of-puma process) rather than block the MCP call. Poll
        # get_package_repository for sync_status.
        ::System::PackageRepositorySyncService.enqueue!(repository: repo, force: force)
        success_result(
          queued:        true,
          repository_id: repo.id,
          status:        repo.sync_status,
          message:       "Sync queued — running in the background; poll get_package_repository for sync_status."
        )
      end

      # === Packages ===

      def search_packages(params)
        result = ::System::PackageSearchService.call(account: @user&.account, params: params)
        success_result(
          packages:        result.packages.map { |p| serialize_package(p, similarity: extract_similarity(p)) },
          page:            result.applied_filters[:page],
          per_page:        result.applied_filters[:per_page],
          total:           result.total,
          mode:            result.mode,
          applied_filters: result.applied_filters
        )
      end

      # Intent-based discovery — thin wrapper over the skill executor so
      # direct skill invocation and MCP invocation return identical shapes.
      def discover_packages(params)
        executor = build_skill_executor(::System::Ai::Skills::DiscoverPackagesByIntentExecutor,
                                        account: @user&.account)
        result = executor.execute(
          intent:         params[:intent],
          repository_ids: Array(params[:repository_ids]).compact_blank,
          kind:           params[:kind],
          architectures:  Array(params[:architectures]).compact_blank,
          license:        params[:license],
          top_k:          params[:top_k] || ::System::Ai::Skills::DiscoverPackagesByIntentExecutor::DEFAULT_TOP_K
        )
        result[:success] ? success_result(**result[:data]) : error_result(result[:error])
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
          repositories: [ repo ],
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
        # IMP-c33045a39443 — an unresolvable category_id used to yield nil and
        # fall through to the materializer's DEFAULT category with a success
        # envelope, so an agent that named a category got a different one and
        # was never told. Absent is still fine (nil keeps the materializer's
        # documented defaulting); NAMED-BUT-WRONG is now a refusal.
        category = nil
        if params[:category_id].present?
          category = @user.account.system_node_module_categories.find_by(id: params[:category_id])
          unless category
            return error_result(
              "category not found in this account: #{params[:category_id]} — " \
              "omit category_id to use the default category"
            )
          end
        end
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
        executor = build_skill_executor(::System::Ai::Skills::SuggestArchitecturesForFleetExecutor,
                                        account: @user&.account)
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
          embedding_pending_count: embedding_pending_count_for(repo),
          node_platform_ids: repo.node_platforms.map(&:id)
        }
        if detail
          base[:apt_config] = repo.apt_config
          base[:rpm_config] = repo.rpm_config
          base[:node_platforms] = repo.node_platforms.map { |p| { id: p.id, name: p.name } }
        end
        base
      end

      def serialize_package(pkg, detail: false, similarity: nil)
        base = {
          id: pkg.id, name: pkg.name, version: pkg.version, architecture: pkg.architecture,
          section: pkg.section_or_group, summary: pkg.summary, license: pkg.license,
          provides_names: pkg.provides_capabilities,
          installed_size: pkg.installed_size_bytes, download_size: pkg.download_size_bytes,
          repository_id: pkg.package_repository_id
        }
        base[:similarity] = similarity if similarity
        if detail
          base[:description] = pkg.description
          base[:depends] = pkg.depends
          base[:recommends] = pkg.recommends
          base[:provides] = pkg.provides
          base[:conflicts] = pkg.conflicts
          base[:maintainer] = pkg.maintainer
          base[:homepage] = pkg.homepage
        end
        base
      end

      # Lightweight count — uses the same scope the worker leases from so
      # the Catalog UI can show coverage at a glance. Not eager-loaded; this
      # runs once per repo serialized.
      def embedding_pending_count_for(repo)
        ::System::Package.live
                         .where(package_repository_id: repo.id, embedding: nil)
                         .count
      end

      # Pulls a similarity score off the AR record when run_hybrid stashed
      # one via define_singleton_method, OR derives it from neighbor_distance
      # when nearest_neighbors set the virtual attribute. Returns nil for
      # lexical-mode rows (no similarity meaningful).
      def extract_similarity(pkg)
        return pkg.hybrid_similarity.round(4) if pkg.respond_to?(:hybrid_similarity)
        dist = pkg.neighbor_distance
        dist ? (1.0 - dist.to_f).round(4) : nil
      end

      def mod_summary(m)
        { id: m.id, name: m.name, auto_generated: m.auto_generated, public: m.public }
      end
    end
  end
end
