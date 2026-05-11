# frozen_string_literal: true

module System
  # Resolves the transitive dependency closure of a Package across one or
  # more PackageRepositories that share a node_platform.
  #
  # Two-phase API:
  #
  #   # Phase 1: preview — what would the closure look like, and what
  #   #          Recommends edges could the operator opt into?
  #   preview = resolver.preview(root_package_name: "nginx")
  #   #   preview.required_packages         → Array<Package>
  #   #   preview.required_edges            → Array<Edge>
  #   #   preview.recommends_candidates     → Array<{from, to, transitive_required_if_chosen}>
  #   #   preview.suggests_candidates       → Array<{from, to}>     # informational
  #   #   preview.alternatives_chosen       → Hash<String, String>
  #   #   preview.warnings, preview.errors  → Array<String>
  #
  #   # Phase 2: resolve — commit to a recommends selection and produce the
  #   #          full closure ready for materialization.
  #   result = resolver.resolve(root_package_name: "nginx",
  #                              recommends_selected: ["ssl-cert"])
  #   #   result.packages          → Array<Package>   # required + selected-recommends + their deps
  #   #   result.edges             → Array<Edge>      # requires + recommends edges in closure
  #   #   result.recommends_chosen → Array<String>    # for PackageModuleLink.recommends_chosen
  #
  # Dependency-shape input (Package columns):
  #   depends/pre_depends/recommends/...: [[{name,op,version}, {name,...}], ...]
  #     outer = AND, inner = OR (alternatives)
  #
  # Alternatives policy: pick the first option whose first item exists in
  # the synced metadata of an enabled, same-platform repo. Record the
  # selection in alternatives_chosen so it can be persisted to
  # PackageModuleLink for replayable refresh.
  class PackageDependencyResolver
    Edge = Struct.new(:from_package, :to_package, :dep_type, :constraint, keyword_init: true)
    RecommendsCandidate = Struct.new(
      :from_package, :to_package, :transitive_required_if_chosen, :installed_size_bytes,
      keyword_init: true
    )
    SuggestsCandidate = Struct.new(:from_package, :to_package, keyword_init: true)

    PreviewResult = Struct.new(
      :required_packages, :required_edges, :recommends_candidates,
      :suggests_candidates, :alternatives_chosen, :warnings, :errors,
      keyword_init: true
    )

    ResolveResult = Struct.new(
      :packages, :edges, :recommends_chosen, :alternatives_chosen,
      :warnings, :errors,
      keyword_init: true
    )

    attr_reader :repositories, :architecture, :include_pre_depends

    def initialize(repositories:, architecture:, include_pre_depends: true)
      @repositories = Array(repositories)
      @architecture = architecture
      @include_pre_depends = include_pre_depends
    end

    # Resolve required closure only + enumerate recommends candidates. No
    # side effects. The UI uses this to render checkboxes.
    def preview(root_package_name:)
      root = find_package(root_package_name)
      return preview_error("Package #{root_package_name} not found in synced repos") if root.nil?

      walker = Walker.new(self, follow_recommends: false)
      walker.walk!(root)

      recommends_candidates = enumerate_recommends_candidates(walker.packages)
      suggests_candidates   = enumerate_suggests_candidates(walker.packages)

      PreviewResult.new(
        required_packages:     walker.packages.values,
        required_edges:        walker.edges,
        recommends_candidates: recommends_candidates,
        suggests_candidates:   suggests_candidates,
        alternatives_chosen:   walker.alternatives_chosen,
        warnings:              walker.warnings,
        errors:                walker.errors
      )
    end

    # Walk the full closure with operator's recommends_selected included as
    # required-from-here-on. Returns the set the materializer will create
    # NodeModules for.
    def resolve(root_package_name:, recommends_selected: [])
      root = find_package(root_package_name)
      return resolve_error("Package #{root_package_name} not found in synced repos") if root.nil?

      selected = Set.new(Array(recommends_selected).map(&:to_s))
      walker = Walker.new(self, follow_recommends: true, recommends_filter: ->(pkg) {
        selected.include?(pkg.name)
      })
      walker.walk!(root)

      ResolveResult.new(
        packages:            walker.packages.values,
        edges:               walker.edges,
        recommends_chosen:   selected.to_a.sort,
        alternatives_chosen: walker.alternatives_chosen,
        warnings:            walker.warnings,
        errors:              walker.errors
      )
    end

    # Find a Package satisfying the given name (or capability via Provides)
    # across the resolver's repositories. Returns nil if no match.
    # Visible to Walker; package selection is consistent across the
    # whole closure walk.
    def find_package(name)
      live_scope.where(name: name).first || find_by_provides(name)
    end

    private

    def live_scope
      ::System::Package
        .live
        .where(architecture: @architecture)
        .where(package_repository_id: @repositories.map(&:id))
        .order(:name) # stable ordering across repos
    end

    def find_by_provides(capability)
      # Provides entries are stored as [[{name=cap, op=nil, version=nil}]]
      live_scope
        .where("provides @> ?::jsonb", [[{ name: capability }]].to_json)
        .first
    end

    def preview_error(msg)
      PreviewResult.new(
        required_packages: [], required_edges: [],
        recommends_candidates: [], suggests_candidates: [],
        alternatives_chosen: {}, warnings: [], errors: [msg]
      )
    end

    def resolve_error(msg)
      ResolveResult.new(
        packages: [], edges: [], recommends_chosen: [],
        alternatives_chosen: {}, warnings: [], errors: [msg]
      )
    end

    def enumerate_recommends_candidates(required_packages_by_name)
      required_names = required_packages_by_name.keys.to_set
      candidates = []

      required_packages_by_name.each_value do |pkg|
        Array(pkg.recommends).each do |group|
          # `recommends` is shaped like depends: [[{name,...},{name,...}]]
          chosen = pick_alternative(group)
          next unless chosen # unsatisfiable recommends → skip silently

          to_pkg = find_package(chosen["name"])
          next unless to_pkg
          next if required_names.include?(to_pkg.name) # already in required closure

          # Compute the additional packages that would be pulled if the
          # operator opts in (transitive requires of `to_pkg` MINUS what's
          # already required).
          sub_walker = Walker.new(self, follow_recommends: false)
          sub_walker.walk!(to_pkg)
          extra_pkgs = sub_walker.packages.values.reject { |p| required_names.include?(p.name) || p.name == to_pkg.name }

          candidates << RecommendsCandidate.new(
            from_package:                  pkg,
            to_package:                    to_pkg,
            transitive_required_if_chosen: extra_pkgs,
            installed_size_bytes:          to_pkg.installed_size_bytes.to_i
          )
        end
      end
      candidates.uniq { |c| [c.from_package.name, c.to_package.name] }
    end

    def enumerate_suggests_candidates(required_packages_by_name)
      required_names = required_packages_by_name.keys.to_set
      candidates = []
      required_packages_by_name.each_value do |pkg|
        Array(pkg.suggests).each do |group|
          chosen = pick_alternative(group)
          next unless chosen

          to_pkg = find_package(chosen["name"])
          next unless to_pkg
          next if required_names.include?(to_pkg.name)

          candidates << SuggestsCandidate.new(from_package: pkg, to_package: to_pkg)
        end
      end
      candidates.uniq { |c| [c.from_package.name, c.to_package.name] }
    end

    # First alternative whose primary item has a synced live Package.
    # Returns the chosen dep-hash or nil if none of the alternatives can be satisfied.
    def pick_alternative(group)
      Array(group).find do |alt|
        find_package(alt["name"]).present?
      end
    end

    public

    # Internal walker — recursive closure expansion with cycle detection.
    class Walker
      attr_reader :packages, :edges, :warnings, :errors, :alternatives_chosen

      def initialize(resolver, follow_recommends: false, recommends_filter: nil)
        @resolver = resolver
        @follow_recommends = follow_recommends
        @recommends_filter = recommends_filter
        @packages = {} # name => Package
        @edges = []
        @warnings = []
        @errors = []
        @alternatives_chosen = {}
        @visiting = Set.new # cycle detection: names currently on the call stack
      end

      def walk!(root)
        visit(root)
      end

      private

      def visit(pkg)
        # Cycle check MUST come before the already-visited check: if we're
        # mid-walk through `pkg` (it's in @visiting) and hit it again, that's
        # a true cycle, not a benign re-visit of an already-completed node.
        if @visiting.include?(pkg.name)
          @warnings << "Cycle broken at #{pkg.name}"
          return
        end
        # Benign re-visit of a finished node (DAG diamond, A→B→D and A→C→D).
        return if @packages.key?(pkg.name)

        @visiting.add(pkg.name)
        @packages[pkg.name] = pkg

        # Walk required deps
        deps = Array(pkg.depends)
        deps += Array(pkg.pre_depends) if @resolver.include_pre_depends
        deps.each do |group|
          chosen = pick_alt(group, source: pkg)
          unless chosen
            @errors << "Unsatisfiable dep #{group.map { |d| d['name'] }.join(' | ')} required by #{pkg.name}"
            next
          end
          dep_pkg = @resolver.find_package(chosen["name"])
          @edges << Edge.new(
            from_package: pkg,
            to_package:   dep_pkg,
            dep_type:     "requires",
            constraint:   format_constraint(chosen)
          )
          visit(dep_pkg)
        end

        # Walk recommends edges if configured (resolve path only)
        if @follow_recommends
          Array(pkg.recommends).each do |group|
            chosen = pick_alt(group, source: pkg)
            next unless chosen

            dep_pkg = @resolver.find_package(chosen["name"])
            next unless dep_pkg

            if @recommends_filter.nil? || @recommends_filter.call(dep_pkg)
              @edges << Edge.new(
                from_package: pkg,
                to_package:   dep_pkg,
                dep_type:     "recommends",
                constraint:   format_constraint(chosen)
              )
              visit(dep_pkg)
            end
          end
        end

        @visiting.delete(pkg.name)
      end

      def pick_alt(group, source:)
        alts = Array(group)
        return nil if alts.empty?

        # If only one alternative, no ambiguity to record
        chosen = alts.find { |alt| @resolver.find_package(alt["name"]).present? }
        return nil unless chosen

        if alts.size > 1
          key = alts.map { |a| a["name"] }.join(" | ")
          @alternatives_chosen[key] = chosen["name"]
        end
        chosen
      end

      def format_constraint(alt)
        return nil unless alt["op"] && alt["version"]

        "#{alt['op']} #{alt['version']}"
      end
    end
  end
end
