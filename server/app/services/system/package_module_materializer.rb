# frozen_string_literal: true

module System
  # Materializes an apt/rpm Package (and its resolved dependency closure) into
  # System::NodeModule rows + System::ModuleDependency edges + PackageModuleLink
  # back-refs, then optionally dispatches a CI build for the new closure.
  #
  # Idempotent: re-calling with the same parameters produces the same module
  # graph + 0 net side effects.
  #
  # Naming scheme:
  #   - Top-level package (user-requested):  bare `<package-name>`
  #     (e.g., "nginx"). Conflicts against an existing non-auto-generated
  #     module with the same name are refused with a clear error.
  #   - Transitive deps:  `<repo-slug>--<package-name>`
  #     (e.g., "ubuntu-noble--libc6"). The repo-slug prefix prevents
  #     collisions between repositories that ship the same package
  #     (Ubuntu archive vs. nginx.org, etc.).
  class PackageModuleMaterializer
    class NamingConflictError < StandardError; end

    Result = Struct.new(
      :top_level_module, :dependency_modules, :recommends_modules,
      :dependencies_created, :build_dispatches, :warnings, :errors,
      keyword_init: true
    ) do
      def all_modules
        [top_level_module, *dependency_modules, *recommends_modules].compact
      end

      def success?
        top_level_module.present? && errors.empty?
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(repository:, package_name:, architectures:, account:,
                   requested_by_user:, recommends_selected: [],
                   category: nil, dispatch_build: true)
      @repository          = repository
      @package_name        = package_name
      # Callers (frontend, MCP) submit canonical names (post-T2.A). The
      # PackageDependencyResolver queries Package.architecture which is
      # kind-specific (apt's "amd64" / rpm's "x86_64" — whatever the
      # upstream metadata used). Translate at the boundary so the resolver
      # WHERE clauses hit the right rows.
      canonical_input      = Array(architectures).presence || ["amd64"]
      @architectures       = canonical_input.filter_map do |canonical|
        arch_row = ::System::NodeArchitecture.find_normalized(canonical)
        arch_row ? arch_row.value_for_kind(repository.kind) : canonical
      end
      @account             = account
      @user                = requested_by_user
      @recommends_selected = Array(recommends_selected).map(&:to_s)
      @category            = category
      @dispatch_build      = dispatch_build
    end

    def call
      warnings = []
      errors = []
      arch_results = {}

      @architectures.each do |arch|
        resolver = ::System::PackageDependencyResolver.new(
          repositories: [@repository],
          architecture: arch
        )
        result = resolver.resolve(
          root_package_name:   @package_name,
          recommends_selected: @recommends_selected
        )
        warnings.concat(result.warnings)
        errors.concat(result.errors)
        arch_results[arch] = result
      end

      if errors.any?
        return Result.new(
          top_level_module: nil, dependency_modules: [], recommends_modules: [],
          dependencies_created: [], build_dispatches: [],
          warnings: warnings, errors: errors
        )
      end

      # Union of packages across all arches (by name). Per-arch artifacts
      # are tracked at the ModuleArtifact level; the NodeModule itself is
      # arch-agnostic.
      packages_by_name = {}
      arch_results.values.each do |r|
        r.packages.each { |p| packages_by_name[p.name] = p }
      end

      # The first resolver's recommends_chosen list is authoritative (operator
      # selection is per-call, not per-arch).
      recommends_chosen = arch_results.values.first&.recommends_chosen.to_a
      alternatives_chosen = arch_results.values.first&.alternatives_chosen.to_h

      created_modules = {}
      recommends_module_names = Set.new
      dependencies_created = []

      ::System::NodeModule.transaction do
        # Phase 1: create one NodeModule + PackageModuleLink per package in closure
        packages_by_name.each_value do |pkg|
          is_top_level = (pkg.name == @package_name)
          mod = upsert_module_for_package(pkg, top_level: is_top_level)
          link = upsert_link(
            mod:    mod,
            pkg:    pkg,
            arch:   @architectures.first,
            top_level: is_top_level,
            recommends_chosen: is_top_level ? recommends_chosen : [],
            alternatives_chosen: is_top_level ? alternatives_chosen : {}
          )
          created_modules[pkg.name] = mod
          recommends_module_names.add(pkg.name) if recommends_chosen.include?(pkg.name)
        end

        # Phase 2: create ModuleDependency edges from resolver edges
        unique_edges = Set.new
        arch_results.values.each do |r|
          r.edges.each do |edge|
            from_mod = created_modules[edge.from_package.name]
            to_mod   = created_modules[edge.to_package.name]
            next unless from_mod && to_mod
            next if from_mod.id == to_mod.id

            key = [from_mod.id, to_mod.id, edge.dep_type]
            next if unique_edges.include?(key)

            unique_edges.add(key)
            dep = ::System::ModuleDependency.find_or_create_by!(
              node_module_id: from_mod.id,
              dependency_id:  to_mod.id,
              dependency_type: edge.dep_type
            ) do |d|
              d.required          = (edge.dep_type == "requires")
              d.version_constraint = edge.constraint
            end
            dependencies_created << dep
          end
        end
      end

      build_dispatches = []
      if @dispatch_build
        build_dispatches = dispatch_closure_build(
          modules:       created_modules.values,
          architectures: @architectures
        )
      end

      top = created_modules[@package_name]
      deps = created_modules.values.reject do |m|
        m.id == top&.id || recommends_module_names.include?(m.name)
      end
      recs = created_modules.values.select { |m| recommends_module_names.include?(m.name) }

      Result.new(
        top_level_module:     top,
        dependency_modules:   deps,
        recommends_modules:   recs,
        dependencies_created: dependencies_created,
        build_dispatches:     build_dispatches,
        warnings:             warnings,
        errors:               errors
      )
    end

    private

    # Module naming: top-level gets the bare package name; transitive deps
    # are prefixed with the repo slug to avoid cross-repo collisions.
    def module_name_for(pkg, top_level:)
      return pkg.name if top_level

      "#{repo_slug}--#{pkg.name}"
    end

    def repo_slug
      @repository.name.parameterize
    end

    def upsert_module_for_package(pkg, top_level:)
      canonical = module_name_for(pkg, top_level: top_level)

      existing = ::System::NodeModule.find_by(account_id: @account.id, name: canonical)
      if existing
        if !existing.auto_generated && !top_level
          raise NamingConflictError,
                "Module name `#{canonical}` already exists as an operator-authored module; " \
                "auto-materialized dependencies cannot overwrite it."
        end
        return existing
      end

      ::System::NodeModule.create!(
        account:        @account,
        node_platform:  @repository.node_platform,
        category:       @category,
        name:           canonical,
        description:    pkg.summary || pkg.description&.truncate(500),
        variety:        "subscription",
        priority:       top_level ? 100 : 50,
        enabled:        true,
        public:         top_level,
        auto_generated: !top_level,
        package_spec:   "#{pkg.name}\n",      # base64-encoded by before_validation :encode_specs
        file_spec:      "",                   # populated by build webhook from dpkg -L
        dependency_spec: ""                   # mirrors file_spec for M0.J dependant inheritance
      )
    end

    def upsert_link(mod:, pkg:, arch:, top_level:, recommends_chosen:, alternatives_chosen:)
      link = ::System::PackageModuleLink.find_or_initialize_by(node_module_id: mod.id)
      link.assign_attributes(
        package_repository:  @repository,
        package_name:        pkg.name,
        package_version:     pkg.version,
        architecture:        arch,
        file_spec_source:    "package_query",
        alternatives_chosen: alternatives_chosen,
        recommends_chosen:   recommends_chosen,
        auto_generated:      !top_level,
        last_synced_at:      Time.current
      )
      link.save!
      link
    end

    def dispatch_closure_build(modules:, architectures:)
      ::System::ModuleBuildDispatchService.dispatch_closure(
        repository:    @repository,
        modules:       modules,
        architectures: architectures,
        requested_by:  @user
      )
    rescue NameError, NoMethodError => e
      # dispatch_closure is added in Phase C — fall back to logging if
      # the method isn't loaded yet (e.g., during incremental rollout).
      Rails.logger.warn("[PackageModuleMaterializer] dispatch_closure not available: #{e.message}")
      []
    end
  end
end
