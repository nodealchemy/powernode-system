# frozen_string_literal: true

module System
  # Service for resolving module dependencies with support for:
  # - Recursive dependency resolution
  # - Circular dependency detection
  # - Priority-based ordering
  # - Required vs optional dependency handling
  # - Conflict detection
  class DependencyResolutionService
    class DependencyError < StandardError; end
    class CircularDependencyError < DependencyError; end
    class MissingDependencyError < DependencyError; end
    class ConflictError < DependencyError; end

    # Result object for resolution
    ResolutionResult = Struct.new(:modules, :warnings, :errors, :resolution_order, keyword_init: true) do
      def success?
        errors.empty?
      end

      def has_warnings?
        warnings.any?
      end
    end

    attr_reader :available_modules, :options, :recommends_predicate

    # Initialize with available modules and options
    # @param available_modules [Array<System::NodeModule>] modules available for resolution
    # @param options [Hash] resolution options
    # @option options [Boolean] :include_optional (true) whether to include optional dependencies
    # @option options [Boolean] :fail_on_missing (false) whether to raise on missing dependencies
    # @option options [Boolean] :detect_conflicts (true) whether to detect module conflicts
    # @param recommends_predicate [Proc] optional callable invoked per non-required
    #   (recommends/optional) edge to decide inclusion. Signature:
    #     ->(from_module:, to_module:) { Boolean }
    #   When nil (default), the existing :include_optional boolean governs
    #   inclusion. When set, an edge is followed only if (a) :include_optional
    #   is true AND (b) the predicate returns true. Used by TemplateExpansionService
    #   to apply per-template recommends overrides.
    def initialize(available_modules, recommends_predicate: nil, **kwargs)
      @available_modules = available_modules.to_a
      @available_module_ids = Set.new(@available_modules.map(&:id))
      @options = {
        include_optional: true,
        fail_on_missing: false,
        detect_conflicts: true
      }.merge(kwargs)
      @recommends_predicate = recommends_predicate
    end

    # Resolve dependencies for a set of requested modules
    # @param requested_modules [Array<System::NodeModule>] modules to resolve dependencies for
    # @return [ResolutionResult] result containing ordered modules and any issues
    def resolve(requested_modules)
      @resolved = []
      @visited = Set.new
      @in_progress = Set.new
      @warnings = []
      @errors = []
      @resolution_order = []

      # First, detect any conflicts
      detect_conflicts(requested_modules) if options[:detect_conflicts]

      # Resolve each requested module
      requested_modules.each do |mod|
        resolve_module(mod)
      end

      # Order by priority (higher first) then by resolution order
      ordered_modules = order_by_priority(@resolved)

      ResolutionResult.new(
        modules: ordered_modules,
        warnings: @warnings,
        errors: @errors,
        resolution_order: @resolution_order
      )
    end

    # Resolve dependencies for a single module
    # @param node_module [System::NodeModule] module to resolve
    # @return [ResolutionResult] result for single module
    def resolve_single(node_module)
      resolve([ node_module ])
    end

    # Check if adding a module would create a circular dependency
    # @param node_module [System::NodeModule] module to check
    # @param potential_dependency [System::NodeModule] potential new dependency
    # @return [Boolean] true if would create circular dependency
    def would_create_circular?(node_module, potential_dependency)
      # Check if potential_dependency already depends on node_module
      deps = get_all_dependencies(potential_dependency)
      deps.any? { |d| d.id == node_module.id }
    end

    # Get all dependencies recursively (without ordering)
    # @param node_module [System::NodeModule] module to get dependencies for
    # @return [Array<System::NodeModule>] all dependencies
    def get_all_dependencies(node_module)
      visited = Set.new
      collect_dependencies(node_module, visited)
    end

    # Validate that all required dependencies are available
    # @param requested_modules [Array<System::NodeModule>] modules to validate
    # @return [Hash] validation result with :valid, :missing_required, :missing_optional
    def validate_dependencies(requested_modules)
      missing_required = []
      missing_optional = []

      requested_modules.each do |mod|
        mod.module_dependencies.each do |dep_record|
          dependency = dep_record.dependency
          unless @available_module_ids.include?(dependency.id)
            if dep_record.required?
              missing_required << { module: mod, dependency: dependency, record: dep_record }
            else
              missing_optional << { module: mod, dependency: dependency, record: dep_record }
            end
          end
        end
      end

      {
        valid: missing_required.empty?,
        missing_required: missing_required,
        missing_optional: missing_optional
      }
    end

    # Generate a dependency tree structure
    # @param node_module [System::NodeModule] root module
    # @return [Hash] tree structure with :module, :dependencies
    def dependency_tree(node_module)
      build_tree(node_module, Set.new)
    end

    private

    def resolve_module(node_module, depth = 0)
      return if @visited.include?(node_module.id)

      # Check for circular dependency
      if @in_progress.include?(node_module.id)
        cycle = detect_cycle_path(node_module)
        error_msg = "Circular dependency detected: #{cycle.map(&:name).join(' -> ')}"
        @errors << { type: :circular_dependency, module: node_module, message: error_msg }
        raise CircularDependencyError, error_msg if options[:fail_on_missing]
        return
      end

      # Check if module is available
      unless @available_module_ids.include?(node_module.id)
        @warnings << { type: :unavailable, module: node_module, message: "Module #{node_module.name} is not in available modules" }
        return
      end

      @in_progress.add(node_module.id)

      # Resolve dependencies first (depth-first)
      node_module.module_dependencies.includes(:dependency).each do |dep_record|
        dependency = dep_record.dependency

        # Skip optional dependencies if configured
        if !dep_record.required?
          next unless options[:include_optional]

          # Per-edge recommends override (set by TemplateExpansionService)
          if @recommends_predicate
            keep = @recommends_predicate.call(from_module: node_module, to_module: dependency)
            next unless keep
          end
        end

        check_constraint_drift(node_module, dep_record, dependency)

        if @available_module_ids.include?(dependency.id)
          resolve_module(dependency, depth + 1)
        elsif dep_record.required?
          error_msg = "Required dependency #{dependency.name} for #{node_module.name} is not available"
          @errors << { type: :missing_required, module: node_module, dependency: dependency, message: error_msg }
          raise MissingDependencyError, error_msg if options[:fail_on_missing]
        else
          @warnings << { type: :missing_optional, module: node_module, dependency: dependency, message: "Optional dependency #{dependency.name} is not available" }
        end
      end

      @in_progress.delete(node_module.id)
      @visited.add(node_module.id)
      @resolved << node_module
      @resolution_order << { module: node_module, depth: depth, order: @resolution_order.size }
    end

    # ManifestImportService matches a `capability:<tag>@<constraint>` requirement
    # once, at import, and records the constraint on the edge. Nothing re-read it
    # afterwards, so a provider re-imported at a lower version left every later
    # resolution treating the edge as satisfied. This re-checks it.
    #
    # Advisory only — the module still resolves into the closure. Dropping a
    # provider from a live node's module set over a constraint the platform has
    # never once enforced would be a far larger behaviour change than the drift
    # being reported.
    #
    # Two deliberate silences, both to avoid warnings that say nothing true:
    #
    #   * An unparseable constraint is skipped. Every module-to-module pin in
    #     this repo is npm caret (`@^1.0`), which Gem::Requirement rejects, and
    #     the platform has no module semver to check it against anyway
    #     (NodeModuleVersion#version_number is an integer counter). Warning here
    #     would fire on nearly every edge in the fleet.
    #   * A provider advertising no versioned capability is skipped — there is
    #     nothing to compare, which is the normal shape of a name-pinned edge.
    #
    # The check is tag-blind: the edge does not record WHICH capability tag
    # produced it (system_module_dependencies has no metadata column), so a
    # provider counts as satisfying the constraint if any of its versioned tags
    # does. That can miss a drift the operator would care about when a provider
    # advertises several versioned tags; it cannot invent one.
    def check_constraint_drift(node_module, dep_record, dependency)
      # A constraint on a `conflicts` edge means "conflicts with these versions",
      # the opposite reading — satisfying it is the problem, not the fix.
      return if dep_record.conflicts?

      constraint = dep_record.version_constraint
      return if constraint.blank?
      return unless ::System::CapabilityResolver.constraint_valid?(constraint)

      versioned_tags = Array(dependency.capabilities).filter_map do |cap|
        tag, version = cap.to_s.split("@", 2)
        tag if version.present?
      end.uniq
      return if versioned_tags.empty?

      return if versioned_tags.any? { |tag| ::System::CapabilityResolver.satisfied_by?(dependency, tag, constraint) }

      @warnings << {
        type: :constraint_drift,
        module: node_module,
        dependency: dependency,
        message: "Dependency #{dependency.name} for #{node_module.name} no longer satisfies " \
                 "its recorded version constraint #{constraint} (provides: #{Array(dependency.capabilities).join(', ')})"
      }
    end

    def detect_cycle_path(target_module)
      # Find the cycle path for error reporting
      path = []
      current = target_module

      loop do
        path << current
        deps = current.dependencies.select { |d| @in_progress.include?(d.id) }
        break if deps.empty?
        current = deps.first
        break if current.id == target_module.id
      end

      path << target_module
      path
    end

    def detect_conflicts(modules)
      # Group modules by conflict declarations
      modules.each do |mod|
        mod.module_dependencies.conflicts.each do |conflict_record|
          conflicting = conflict_record.dependency

          if modules.any? { |m| m.id == conflicting.id }
            error_msg = "Module #{mod.name} conflicts with #{conflicting.name}"
            @errors << { type: :conflict, module: mod, conflicting: conflicting, message: error_msg }
          end
        end
      end
    end

    def order_by_priority(modules)
      # Sort by priority (descending) then by name (ascending) for stable ordering
      modules.sort_by { |m| [ -m.priority, m.name ] }
    end

    def collect_dependencies(node_module, visited)
      return [] if visited.include?(node_module.id)
      visited.add(node_module.id)

      dependencies = []
      node_module.dependencies.each do |dep|
        if @available_module_ids.include?(dep.id)
          dependencies << dep
          dependencies.concat(collect_dependencies(dep, visited))
        end
      end

      dependencies
    end

    def build_tree(node_module, visited)
      return { module: node_module, circular: true } if visited.include?(node_module.id)

      visited.add(node_module.id)

      children = node_module.module_dependencies.includes(:dependency).map do |dep_record|
        {
          dependency: build_tree(dep_record.dependency, visited.dup),
          required: dep_record.required?,
          type: dep_record.dependency_type
        }
      end

      {
        module: {
          id: node_module.id,
          name: node_module.name,
          priority: node_module.priority,
          variety: node_module.variety
        },
        dependencies: children
      }
    end

    class << self
      # Convenience method to resolve for a node
      # @param node [System::Node] node to resolve modules for
      # @param options [Hash] resolution options
      # @return [ResolutionResult]
      def resolve_for_node(node, options = {})
        available = node.node_modules.enabled.includes(:module_dependencies, :dependencies)
        requested = available.to_a

        new(available, **options).resolve(requested)
      end

      # Convenience method to resolve for a template
      # @param template [System::NodeTemplate] template to resolve modules for
      # @param options [Hash] resolution options
      # @return [ResolutionResult]
      def resolve_for_template(template, options = {})
        available = template.node_modules.enabled.includes(:module_dependencies, :dependencies)
        requested = available.to_a

        new(available, **options).resolve(requested)
      end

      # Check if a set of modules can be resolved without errors
      # @param modules [Array<System::NodeModule>] modules to check
      # @return [Boolean]
      def resolvable?(modules)
        result = new(modules).resolve(modules)
        result.success?
      end
    end
  end
end
