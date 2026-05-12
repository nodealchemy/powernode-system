# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator browse + materialize endpoints over the synced apt/rpm
      # package catalog.
      #
      # Permission gates:
      #   - system.packages.view / search
      #   - system.package_modules.create
      class PackagesController < BaseController
        before_action :set_account

        # GET /api/v1/system/packages
        # Filters: repository_id, q (name LIKE), section, architecture, page, per_page
        def index
          require_permission("system.packages.search")
          repos = scoped_repositories
          scope = ::System::Package.live.where(package_repository_id: repos.pluck(:id))
          scope = scope.where("name ILIKE ?", "%#{params[:q]}%") if params[:q].present?
          scope = scope.where(section_or_group: params[:section]) if params[:section].present?
          scope = scope.where(architecture: params[:architecture]) if params[:architecture].present?
          scope = scope.order(:name, :architecture).limit(per_page).offset(offset)
          total = scope.except(:limit, :offset).count
          render_success(
            packages: scope.map { |p| serialize(p) },
            meta: { total: total, page: page, per_page: per_page }
          )
        end

        # GET /api/v1/system/packages/:id
        def show
          require_permission("system.packages.view")
          pkg = ::System::Package.find(params[:id])
          unless scoped_repositories.exists?(id: pkg.package_repository_id)
            return render_not_found("Package")
          end

          render_success(package: serialize(pkg, detail: true))
        end

        # POST /api/v1/system/packages/resolve_dependencies
        # Body: { repository_id, package_name, architecture }
        # Returns the closure preview without writes.
        def resolve_dependencies
          require_permission("system.packages.view")
          repo = scoped_repositories.find(params[:repository_id])
          resolver = ::System::PackageDependencyResolver.new(
            repositories: [repo],
            architecture: params[:architecture]
          )
          preview = resolver.preview(root_package_name: params[:package_name])

          render_success(
            required_packages:     preview.required_packages.map { |p| serialize_lite(p) },
            required_edges:        preview.required_edges.map { |e| serialize_edge(e) },
            recommends_candidates: preview.recommends_candidates.map { |c| serialize_candidate(c) },
            suggests_candidates:   preview.suggests_candidates.map { |c| serialize_suggests(c) },
            alternatives_chosen:   preview.alternatives_chosen,
            warnings:              preview.warnings,
            errors:                preview.errors
          )
        end

        # POST /api/v1/system/packages/suggest_architectures
        # Body: { repository_id, max_suggestions? }
        # Returns the fleet-aware arch suggestion set + per-arch rationale.
        # Frontend modal calls this on open to pre-populate the materialize
        # form's architectures field. Same data shape as the MCP action
        # system_suggest_architectures_for_fleet — backed by the same
        # executor.
        def suggest_architectures
          require_permission("system.packages.view")
          executor = ::System::Ai::Skills::SuggestArchitecturesForFleetExecutor.new(
            account: @account, user: current_user
          )
          result = executor.execute(
            repository_id:   params[:repository_id],
            max_suggestions: params[:max_suggestions]&.to_i || 4
          )
          if result[:success]
            render_success(**result[:data])
          else
            render_error(result[:error], status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/packages/create_module
        # Body: { repository_id, package_name, architectures, recommends_selected[], category_id? }
        # Materializes the package + closure into NodeModules and dispatches build.
        def create_module
          require_permission("system.package_modules.create")
          repo = scoped_repositories.find(params[:repository_id])
          category = params[:category_id].present? ?
                       @account.system_node_module_categories.find_by(id: params[:category_id]) : nil

          result = ::System::PackageModuleMaterializer.call(
            repository:          repo,
            package_name:        params[:package_name],
            architectures:       Array(params[:architectures]),
            account:             @account,
            requested_by_user:   current_user,
            recommends_selected: Array(params[:recommends_selected]),
            category:            category,
            dispatch_build:      params.fetch(:dispatch_build, true)
          )

          if result.success?
            render_success(
              top_level_module: result.top_level_module ? module_summary(result.top_level_module) : nil,
              dependency_modules:  result.dependency_modules.map { |m| module_summary(m) },
              recommends_modules:  result.recommends_modules.map { |m| module_summary(m) },
              dependencies_created: result.dependencies_created.size,
              build_dispatches:     result.build_dispatches,
              warnings:             result.warnings
            )
          else
            render_error(
              "Materialization failed: #{result.errors.join('; ')}",
              status: :unprocessable_entity,
              data:   { warnings: result.warnings, errors: result.errors }
            )
          end
        rescue ::System::PackageModuleMaterializer::NamingConflictError => e
          render_error(e.message, status: :conflict)
        end

        private

        def scoped_repositories
          ::System::PackageRepository.accessible_to(@account).enabled
        end

        def serialize(pkg, detail: false)
          base = {
            id:           pkg.id,
            name:         pkg.name,
            version:      pkg.version,
            architecture: pkg.architecture,
            section:      pkg.section_or_group,
            summary:      pkg.summary,
            installed_size_bytes: pkg.installed_size_bytes,
            download_size_bytes:  pkg.download_size_bytes,
            homepage:     pkg.homepage,
            license:      pkg.license,
            package_repository_id: pkg.package_repository_id
          }
          if detail
            base[:description] = pkg.description
            base[:depends]     = pkg.depends
            base[:pre_depends] = pkg.pre_depends
            base[:recommends]  = pkg.recommends
            base[:suggests]    = pkg.suggests
            base[:conflicts]   = pkg.conflicts
            base[:provides]    = pkg.provides
            base[:maintainer]  = pkg.maintainer
            base[:filename]    = pkg.filename
            base[:sha256]      = pkg.sha256
          end
          base
        end

        def serialize_lite(pkg)
          { name: pkg.name, version: pkg.version, architecture: pkg.architecture,
            summary: pkg.summary, installed_size_bytes: pkg.installed_size_bytes }
        end

        def serialize_edge(edge)
          { from: edge.from_package.name, to: edge.to_package.name,
            type: edge.dep_type, constraint: edge.constraint }
        end

        def serialize_candidate(c)
          {
            from: c.from_package.name,
            to:   c.to_package.name,
            summary: c.to_package.summary,
            installed_size_bytes: c.installed_size_bytes,
            transitive_required_if_chosen: c.transitive_required_if_chosen.map(&:name)
          }
        end

        def serialize_suggests(c)
          { from: c.from_package.name, to: c.to_package.name, summary: c.to_package.summary }
        end

        def module_summary(m)
          { id: m.id, name: m.name, auto_generated: m.auto_generated, public: m.public }
        end

        def page
          [params[:page].to_i, 1].max
        end

        def per_page
          [[params[:per_page].to_i, 50].max, 200].min
        end

        def offset
          (page - 1) * per_page
        end
      end
    end
  end
end
