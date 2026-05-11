# frozen_string_literal: true

module System
  # Computes the effective set of modules + per-template recommends overrides
  # produced when a NodeTemplate is applied to a Node. Wraps
  # DependencyResolutionService with the per-template recommends_predicate
  # callback so each TemplateModule's `recommends_override` shapes the
  # closure independently.
  #
  # Used at NodeModuleAssignment-creation time (template-apply path) and by
  # compose_preview to preview the closure before applying.
  #
  # Output shape:
  #
  #   expansion.modules                      → Array<NodeModule> in closure
  #   expansion.auto_resolved_ids            → Set<UUID> of modules pulled by closure
  #   expansion.source_template_module_for   → Hash<NodeModule UUID, TemplateModule | nil>
  #                                             (TemplateModule whose override governs inclusion;
  #                                              nil for modules pulled only by transitive walking)
  #   expansion.warnings, expansion.errors   → Array<String>
  class TemplateExpansionService
    Expansion = Struct.new(
      :modules, :auto_resolved_ids, :source_template_module_for,
      :warnings, :errors,
      keyword_init: true
    )

    def initialize(template_modules:, available_modules: nil)
      @template_modules  = Array(template_modules)
      @available_modules = available_modules || default_available_modules
    end

    def expand
      # For each TemplateModule, precompute its effective recommends set.
      # The predicate consults this when deciding whether to follow a
      # `recommends`-type ModuleDependency edge originating from its
      # node_module. Required edges follow unconditionally.
      enabled_tms = @template_modules.respond_to?(:where) ?
                      @template_modules.where(enabled: true).to_a :
                      @template_modules.select(&:enabled)
      tm_by_module_id = enabled_tms.index_by(&:node_module_id)
      effective_recommends = enabled_tms.to_h do |tm|
        [tm.node_module_id, tm.effective_recommends_set]
      end

      # The predicate: returns true if this `recommends` edge should be
      # followed by the resolver. `from_module` is the source of the edge;
      # `to_module` is the candidate target. We honor the from_module's
      # template-level recommends override if one is present.
      recommends_predicate = ->(from_module:, to_module:) {
        rec_set = effective_recommends[from_module.id]
        # If this from_module is not directly in the template (i.e., it
        # was itself pulled in by transitive walking), follow its module-
        # default recommends_chosen via its PackageModuleLink. This makes
        # the closure consistent regardless of intermediate hops.
        return inherits_default_recommends?(from_module, to_module) if rec_set.nil?

        # Match by the to_module's source package name (auto_generated
        # modules carry package_module_link.package_name). For operator-
        # authored modules without a link, fall back to module name.
        candidate_pkg_name = to_module.package_module_link&.package_name || to_module.name
        rec_set.include?(candidate_pkg_name)
      }

      requested = enabled_tms.map(&:node_module)
      service = ::System::DependencyResolutionService.new(
        @available_modules,
        recommends_predicate: recommends_predicate
      )
      result = service.resolve(requested)

      explicit_ids = requested.map(&:id).to_set
      auto_resolved_ids = Set.new
      source_template_module_for = {}

      result.modules.each do |mod|
        if explicit_ids.include?(mod.id)
          source_template_module_for[mod.id] = tm_by_module_id[mod.id]
        else
          auto_resolved_ids.add(mod.id)
          # Trace which explicit module(s) pulled this transitive in.
          # We pick the first explicit ancestor we find in the dependency
          # graph; ties are resolved by template-module priority (highest
          # first) for deterministic source attribution.
          ancestor_tm = find_originating_template_module(
            from: mod,
            explicit_module_ids: explicit_ids,
            tm_by_module_id: tm_by_module_id
          )
          source_template_module_for[mod.id] = ancestor_tm
        end
      end

      Expansion.new(
        modules:                    result.modules,
        auto_resolved_ids:          auto_resolved_ids,
        source_template_module_for: source_template_module_for,
        warnings:                   Array(result.warnings).map { |w| w.is_a?(Hash) ? w[:message] : w.to_s },
        errors:                     Array(result.errors).map  { |e| e.is_a?(Hash) ? e[:message] : e.to_s }
      )
    end

    private

    def default_available_modules
      ::System::NodeModule
        .enabled
        .includes(:module_dependencies, :dependencies, :package_module_link)
    end

    # For transitive modules (not directly in template), follow the
    # module's own package_module_link.recommends_chosen as the default.
    # Operator-authored modules without a link don't have recommends —
    # only `requires`-type edges are followed for them.
    def inherits_default_recommends?(from_module, to_module)
      link = from_module.package_module_link
      return false unless link

      candidate_pkg_name = to_module.package_module_link&.package_name || to_module.name
      Array(link.recommends_chosen).include?(candidate_pkg_name)
    end

    # Walk back from `from` through `dependents` (reverse edges) until we
    # find a module that's in `explicit_module_ids`. Returns the
    # TemplateModule pointing at that explicit module, or nil if no
    # explicit ancestor exists (shouldn't happen — closure must have an
    # explicit root — but defensive).
    def find_originating_template_module(from:, explicit_module_ids:, tm_by_module_id:)
      visited = Set.new
      queue = [from]
      while (current = queue.shift)
        next if visited.include?(current.id)

        visited.add(current.id)
        current.dependents.each do |parent|
          return tm_by_module_id[parent.id] if explicit_module_ids.include?(parent.id)

          queue << parent
        end
      end
      nil
    end
  end
end
