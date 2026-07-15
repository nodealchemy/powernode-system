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
      # inc2 (§4.3.1/§4.3.2): names of baseline packages skipped (already
      # shipped by base-os), the synthetic top-level `requires base-os` edge,
      # and the ModuleBuildBatch the native bridge created for this closure.
      :baseline_excluded, :base_os_requires, :build_batch,
      keyword_init: true
    ) do
      def all_modules
        [ top_level_module, *dependency_modules, *recommends_modules ].compact
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
                   category: nil, dispatch_build: true,
                   include_baseline: false, base_os_module_name: nil,
                   build_mode: nil)
      @repository          = repository
      @package_name        = package_name
      # inc2 §4.3.1 — baseline exclusion. When false (default), packages the
      # base-OS module already ships are skipped and replaced by a single
      # synthetic `requires: base-os` edge on the top-level module. When true,
      # the old full-closure behavior is kept (building against a non-Powernode
      # base).
      @include_baseline    = include_baseline
      @base_os_module_name = base_os_module_name
      @base_os_module      = nil
      # inc2 §4.3.2 — build routing. :native routes the closure through
      # System::PackageClosureBuildBridge (ModuleBuildBatch + Vault-signed
      # native pipeline); :gitea keeps the legacy fire-and-forget
      # ModuleBuildDispatchService.dispatch_closure; nil → SiteSetting default.
      @build_mode          = build_mode
      # Callers (frontend, MCP) submit canonical names (post-T2.A). The
      # PackageDependencyResolver queries Package.architecture which is
      # kind-specific (apt's "amd64" / rpm's "x86_64" — whatever the
      # upstream metadata used). Translate at the boundary so the resolver
      # WHERE clauses hit the right rows.
      canonical_input      = Array(architectures).presence || [ "amd64" ]
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
          repositories: [ @repository ],
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

      # Baseline exclusion (§4.3.1): drop packages base-os already ships so a
      # materialized closure obeys inc1's own-files-only-per-package standard
      # (no duplicated libc6 layer). The top-level package is NEVER excluded
      # even if it happens to appear in the baseline — the operator explicitly
      # asked for it. Replaced by a single synthetic base-os requires edge below.
      baseline_excluded = []
      unless @include_baseline
        baseline_names = baseline_package_names
        baseline_excluded = (packages_by_name.keys.to_set & baseline_names).delete(@package_name).to_a.sort
        baseline_excluded.each { |name| packages_by_name.delete(name) }
      end

      # The first resolver's recommends_chosen list is authoritative (operator
      # selection is per-call, not per-arch).
      recommends_chosen = arch_results.values.first&.recommends_chosen.to_a
      alternatives_chosen = arch_results.values.first&.alternatives_chosen.to_h

      created_modules = {}
      recommends_module_names = Set.new
      dependencies_created = []
      base_os_requires = nil

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

            key = [ from_mod.id, to_mod.id, edge.dep_type ]
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

        # Phase 2.5: synthetic base-os requires edge (§4.3.1). Replaces the
        # per-package edges that pointed at the now-excluded baseline modules
        # (those were dropped above by the `next unless from_mod && to_mod`
        # guard, since the baseline modules were never created). Matches inc1's
        # stored shape: a plain `requires` ModuleDependency from the top-level
        # module to the base-os module (system_module_dependencies has no
        # metadata column, so capability_match is not persisted for hand-
        # authored os.userland edges either — this is byte-identical).
        base_os_requires = maybe_create_base_os_edge!(created_modules[@package_name])
        dependencies_created << base_os_requires if base_os_requires
      end

      top = created_modules[@package_name]

      build_batch = nil
      build_dispatches = []
      if @dispatch_build
        build_dispatches, build_batch = dispatch_closure_build(
          modules:       created_modules.values,
          architectures: @architectures
        )
      end

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
        build_batch:          build_batch,
        baseline_excluded:    baseline_excluded,
        base_os_requires:     base_os_requires,
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
        # M:N migration (5fcbb7e) replaced PackageRepository#node_platform
        # (belongs_to) with #node_platforms (has_many :through). Take the
        # first linked platform as the module's default scope; single-platform
        # repos (the common case) keep their original 1:1 behavior, and
        # multi-platform repos can override node_platform_id explicitly on
        # the resulting module.
        node_platform:  @repository.node_platforms.first,
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

    # Baseline package names (§4.3.1) — union across arches of the base-os
    # closure. Captures @base_os_module for the synthetic requires edge.
    def baseline_package_names
      @architectures.each_with_object(Set.new) do |arch, memo|
        result = ::System::BaseOsBaselineResolver.call(
          repository:          @repository,
          architecture:        arch,
          account:             @account,
          base_os_module_name: @base_os_module_name
        )
        @base_os_module ||= result.base_os_module
        memo.merge(result.package_names)
      end
    end

    # Synthetic `requires base-os` edge on the top-level module. Only created
    # when exclusion is active (a base-os module was resolved) — never when
    # include_baseline: true, and never self-referential (a materialized
    # package is never base-os itself). Idempotent.
    def maybe_create_base_os_edge!(top_module)
      return nil if @include_baseline
      return nil unless top_module && @base_os_module
      return nil if top_module.id == @base_os_module.id

      ::System::ModuleDependency.find_or_create_by!(
        node_module_id:  top_module.id,
        dependency_id:   @base_os_module.id,
        dependency_type: "requires"
      ) do |d|
        d.required = true
      end
    end

    # Routes the closure build. Returns [build_dispatches, build_batch].
    #   :native — System::PackageClosureBuildBridge → a ModuleBuildBatch
    #     (trigger "package") driven through the Vault-signing native pipeline
    #     (§4.3.2). The build-completion barrier inc2-A's read API polls.
    #   :gitea  — legacy fire-and-forget ModuleBuildDispatchService.dispatch_closure
    #     (no batch, no server-side signing).
    def dispatch_closure_build(modules:, architectures:)
      case resolved_build_mode
      when :native
        result = ::System::PackageClosureBuildBridge.dispatch!(
          repository:    @repository,
          modules:       modules,
          architectures: architectures,
          account:       @account,
          requested_by:  @user
        )
        batch = result.batch
        dispatches = batch ? [ { batch_id: batch.id, trigger: "package", ok: result.ok? } ] : []
        [ dispatches, batch ]
      when :gitea
        [ legacy_gitea_dispatch(modules, architectures), nil ]
      else
        [ [], nil ]
      end
    rescue NameError, NoMethodError => e
      # Native bridge not loaded yet (incremental rollout) — degrade to logging
      # rather than aborting the whole materialization (the modules + edges are
      # already committed; the build can be re-dispatched).
      Rails.logger.warn("[PackageModuleMaterializer] closure build dispatch unavailable: #{e.message}")
      [ [], nil ]
    end

    def legacy_gitea_dispatch(modules, architectures)
      ::System::ModuleBuildDispatchService.dispatch_closure(
        repository:    @repository,
        modules:       modules,
        architectures: architectures,
        requested_by:  @user
      )
    end

    def resolved_build_mode
      return @build_mode.to_sym if @build_mode

      (::SiteSetting.get("system.package_builds.mode").presence || "native").to_sym
    end
  end
end
