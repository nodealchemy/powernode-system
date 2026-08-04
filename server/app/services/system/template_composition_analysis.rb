# frozen_string_literal: true

module System
  # Account-scoped composition analysis — the one place that answers "what do
  # these modules compose into?". Resolves the dependency closure through
  # DependencyResolutionService and projects it through TemplateComposerService.
  # Persists NOTHING.
  #
  # Extracted from NodeTemplatesController#compose_preview so every surface that
  # needs the answer shares one definition of it:
  #   - the REST compose_preview (Visual Template Composer)
  #   - the system_compose_preview_template MCP action (agents designing a template)
  #   - the assignment write paths (TemplateModulesController#create and the
  #     system_assign_module_to_template MCP action), which refuse the
  #     error-severity conflicts this analysis reports rather than leaving a
  #     disabled React button as the only enforcement.
  #
  # The catalog and resolver are memoized per instance, so a write path gets its
  # before/after comparison for one catalog load rather than two.
  class TemplateCompositionAnalysis
    # A conflict blocks a write unless it explicitly calls itself a warning.
    # Fail closed: a conflict kind added later without a severity refuses the
    # assignment instead of sliding through unnoticed.
    WARNING_SEVERITY = "warning"

    # Eager-loads every association TemplateComposerService reaches for.
    MODULE_INCLUDES = %i[current_version category node_platform
                         module_dependencies dependencies package_module_link].freeze

    # What attaching one module to a template would introduce, split by whether
    # it blocks. `message` is prebuilt because only the analysis can resolve
    # module ids to names.
    Verdict = Struct.new(:blocking, :warnings, :message, keyword_init: true) do
      def blocked?
        blocking.any?
      end
    end

    def initialize(account)
      @account = account
    end

    # The explicitly-requested modules, account-scoped. Empty means the caller
    # asked about nothing that exists here — a 404, not an empty composition.
    def modules_for(module_ids)
      @account.system_node_modules.where(id: Array(module_ids)).includes(*MODULE_INCLUDES).to_a
    end

    # Full compose-preview payload for an explicit module-id list.
    def preview(module_ids)
      preview_for(modules_for(module_ids))
    end

    # Same, for callers that already loaded the records (and needed to check
    # them for emptiness first).
    def preview_for(requested)
      resolution   = resolve(requested)
      composer     = TemplateComposerService.new(resolution.modules)
      explicit_ids = requested.map(&:id).to_set

      {
        modules: composer.serialize_modules(explicit_ids: explicit_ids),
        conflicts: composer.detect_conflicts,
        footprint: composer.footprint,
        dependency_graph: composer.dependency_graph(explicit_ids: explicit_ids),
        warnings: messages(resolution.warnings),
        errors:   messages(resolution.errors)
      }
    end

    # Conflicts that attaching `node_module` to `template` would INTRODUCE.
    #
    # Diffed against the template's current closure deliberately: a template
    # that already composes badly has to stay editable. Judging the whole
    # resulting set instead would 422 every unrelated assignment on such a
    # template, leaving detach-everything as the only way out.
    #
    # Scoped to ENABLED joins, matching TemplateExpansionService's view of what
    # actually ships — a disabled join can't collide with anything.
    def assignment_verdict(template:, node_module:)
      assigned_ids = template.template_modules.enabled.pluck(:node_module_id)
      baseline     = conflicts_for(assigned_ids).map { |c| conflict_key(c) }.to_set
      introduced   = conflicts_for(assigned_ids + [ node_module.id ])
                     .reject { |c| baseline.include?(conflict_key(c)) }

      blocking = introduced.reject { |c| warning?(c) }
      Verdict.new(
        blocking: blocking,
        warnings: introduced.select { |c| warning?(c) },
        message: blocking.any? ? blocking_message(blocking) : nil
      )
    end

    private

    def conflicts_for(module_ids)
      TemplateComposerService.new(resolve(modules_for(module_ids)).modules).detect_conflicts
    end

    def resolve(requested)
      resolver.resolve(Array(requested))
    end

    # One resolver for the instance's lifetime — #resolve resets its own state
    # per call, so the before/after pair reuses a single catalog load.
    def resolver
      @resolver ||= DependencyResolutionService.new(catalog)
    end

    def catalog
      @catalog ||= @account.system_node_modules.enabled
                           .includes(:module_dependencies, :dependencies, :package_module_link).to_a
    end

    def warning?(conflict)
      conflict[:severity].to_s == WARNING_SEVERITY
    end

    # Identity of a conflict, stable across two runs over different module
    # sets. Pairwise kinds keep their direction; `module_ids` is an unordered
    # set, so it sorts.
    def conflict_key(conflict)
      [
        conflict[:kind],
        conflict[:source_id], conflict[:target_id],
        conflict[:claimer_id], conflict[:other_id],
        conflict[:category_id],
        Array(conflict[:module_ids]).sort
      ]
    end

    def blocking_message(conflicts)
      summaries = conflicts.map do |conflict|
        names = module_names(conflict_module_ids(conflict))
        detail = conflict[:detail].presence || conflict[:kind]
        names.any? ? "#{conflict[:kind]} — #{detail} (modules: #{names.join(', ')})" : "#{conflict[:kind]} — #{detail}"
      end

      "Module assignment refused: it would introduce #{conflicts.size} composition " \
        "conflict#{'s' if conflicts.size > 1} — #{summaries.join('; ')}"
    end

    def conflict_module_ids(conflict)
      (conflict.values_at(:source_id, :target_id, :claimer_id, :other_id) +
        Array(conflict[:module_ids])).compact.uniq
    end

    def module_names(ids)
      ids.filter_map { |id| name_lookup[id] }
    end

    def name_lookup
      @name_lookup ||= @account.system_node_modules.pluck(:id, :name).to_h
    end

    def messages(entries)
      Array(entries).map { |e| e.is_a?(Hash) ? e[:message] : e.to_s }
    end
  end
end
