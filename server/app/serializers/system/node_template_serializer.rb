# frozen_string_literal: true

module System
  class NodeTemplateSerializer
    def initialize(template)
      @template = template
    end

    def as_json
      {
        id: @template.id,
        name: @template.name,
        description: @template.description,
        enabled: @template.enabled,
        public: @template.public,
        admin_user: @template.admin_user,
        config: @template.config,
        node_platform_id: @template.node_platform_id,
        # Field names match the frontend SystemNodeTemplate type
        # (extensions/system/frontend/src/features/system/types/system.types.ts).
        # Earlier these were `platform_name` / `nodes_count` which the UI
        # silently fell back to '-' / 0 for, since neither name resolved.
        node_platform_name: @template.node_platform&.name,
        node_count: @template.nodes.size,
        # Module assignments — embedded so the list page can show counts +
        # the first few module names without an N+1 fetch per template.
        # The detail modal still calls /node_templates/:id/modules for the
        # full NodeModule payload; this is the lightweight summary.
        module_count: @template.template_modules.size,
        modules: serialized_template_modules,
        created_at: @template.created_at,
        updated_at: @template.updated_at
      }
    end

    private

    # Returns a compact ordered list of {id, name, priority} entries —
    # enough for the list page to render module chips, but cheap enough
    # to ship in every template row. Uses .size + memoization so eager-
    # loaded collections don't trigger extra queries.
    def serialized_template_modules
      @template.template_modules
               .sort_by { |tm| tm.priority || 0 }
               .map do |tm|
        next unless tm.node_module
        {
          id: tm.node_module.id,
          name: tm.node_module.name,
          variety: tm.node_module.variety,
          priority: tm.priority,
          template_module_id: tm.id
        }
      end.compact
    end
  end
end
