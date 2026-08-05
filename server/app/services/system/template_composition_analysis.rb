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
  #   - the other TemplateModule writers, which used to bypass that guard
  #     entirely and so could land a conflict as permanent BASELINE — which
  #     the delta then treats as acceptable forever after. Gitops::ApplyService
  #     and ModuleSmokeVerifyExecutor author, so they refuse (#additions_verdict);
  #     TemplateCloneService and TemplateImporter reproduce state that already
  #     exists, so they report (#set_verdict). The whole set is judged once
  #     more at apply time (TemplateExpansionService), where a poisoned
  #     baseline would otherwise reach real nodes.
  #
  # The catalog and resolver are memoized per instance, so a write path gets its
  # before/after comparison for one catalog load rather than two.
  class TemplateCompositionAnalysis
    # A conflict blocks a write unless it explicitly calls itself a warning.
    # Fail closed: a conflict kind added later without a severity refuses the
    # assignment instead of sliding through unnoticed.
    WARNING_SEVERITY = "warning"

    # Severity stamped on the entries that DO block. The three conflict kinds
    # TemplateComposerService#detect_conflicts emits each declare their own
    # `severity`, but the fail-closed rule in #warning? means a kind added
    # later WITHOUT one still lands in `blocking` — and would then report a nil
    # severity, leaving a caller exactly as unable to classify it as the
    # untyped `warnings` key this replaces. #report_entries therefore stamps
    # the severity rather than passing the declared value through.
    BLOCKING_SEVERITY = "error"

    # Eager-loads every association TemplateComposerService reaches for.
    MODULE_INCLUDES = %i[current_version category node_platform
                         module_dependencies dependencies package_module_link].freeze

    # What a write would introduce (or, for #set_verdict, what a module set
    # composes into), split by whether it blocks. `message` is prebuilt
    # because only the analysis can resolve module ids to names.
    Verdict = Struct.new(:blocking, :warnings, :message, keyword_init: true) do
      def blocked?
        blocking.any?
      end

      # Self-describing projection for the surfaces that REPORT a verdict
      # instead of enforcing it (TemplateCloneService, TemplateImporter).
      #
      # Those two used to hand their caller `[verdict.message]` — a bare String
      # — under a key named `warnings`, the same key the ENFORCING surfaces use
      # for genuinely advisory conflicts. One key, opposite contracts: a caller
      # holding the payload could not tell a blocking verdict it must act on
      # from an advisory one it may ignore (IMP-493db0e5c398).
      #
      # Every entry states its OWN severity, so one classifier works on any
      # surface's payload without knowing which surface produced it. Making the
      # element TYPE uniform without carrying severity would keep the trap.
      #
      # Both halves are included deliberately. The reporting surfaces used to
      # drop `warnings` entirely (message is nil unless something blocks), so a
      # key called `warnings` was the one place actual warnings never appeared;
      # emitting only the blocking half would also make `severity` a constant
      # and the classification vacuous. Enforcement is untouched either way —
      # these entries are a report, not a verdict the surface acts on.
      def report_entries
        blocking.map { |c| c.merge(severity: BLOCKING_SEVERITY) } +
          warnings.map { |c| c.merge(severity: WARNING_SEVERITY) }
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
    def assignment_verdict(template:, node_module:)
      additions_verdict(template: template, node_modules: [ node_module ])
    end

    # Same, for writers that attach SEVERAL modules in one shot (a smoke
    # pairing composes base-os + target together, so neither is in the
    # baseline when the other is judged — checking them one at a time would
    # miss a collision between them).
    #
    # Diffed against the template's current closure deliberately: a template
    # that already composes badly has to stay editable. Judging the whole
    # resulting set instead would 422 every unrelated assignment on such a
    # template, leaving detach-everything as the only way out.
    #
    # Scoped to ENABLED joins, matching TemplateExpansionService's view of what
    # actually ships — a disabled join can't collide with anything.
    def additions_verdict(template:, node_modules:)
      assigned_ids = template.template_modules.enabled.pluck(:node_module_id)
      baseline     = conflicts_for(assigned_ids).map { |c| conflict_key(c) }.to_set
      introduced   = conflicts_for(assigned_ids + ids_for(node_modules))
                     .reject { |c| baseline.include?(conflict_key(c)) }

      verdict(introduced) { |blocking| blocking_message(blocking) }
    end

    # Verdict over a module set judged WHOLE, with no baseline to diff
    # against. For writers that materialize an entire template in one shot
    # (TemplateCloneService, TemplateImporter): there is no earlier state to
    # charge a conflict to, so everything the resulting closure contains
    # belongs to that write. Accepts records or ids.
    #
    # The diff the assignment paths apply is what makes a poisoned baseline
    # possible in the first place — whatever lands here becomes the baseline
    # every later assignment is then obliged to treat as acceptable.
    def set_verdict(node_modules)
      verdict(conflicts_for(ids_for(node_modules))) { |blocking| set_message(blocking) }
    end

    private

    def verdict(conflicts)
      blocking = conflicts.reject { |c| warning?(c) }
      Verdict.new(
        blocking: blocking,
        warnings: conflicts.select { |c| warning?(c) },
        message: blocking.any? ? yield(blocking) : nil
      )
    end

    def ids_for(node_modules)
      Array(node_modules).map { |m| m.respond_to?(:id) ? m.id : m }
    end

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
      "Module assignment refused: it would introduce #{conflicts.size} composition " \
        "conflict#{'s' if conflicts.size > 1} — #{summarize(conflicts)}"
    end

    def set_message(conflicts)
      "Template composition has #{conflicts.size} error-severity " \
        "conflict#{'s' if conflicts.size > 1} — #{summarize(conflicts)}"
    end

    def summarize(conflicts)
      conflicts.map do |conflict|
        names = module_names(conflict_module_ids(conflict))
        detail = conflict[:detail].presence || conflict[:kind]
        names.any? ? "#{conflict[:kind]} — #{detail} (modules: #{names.join(', ')})" : "#{conflict[:kind]} — #{detail}"
      end.join("; ")
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
