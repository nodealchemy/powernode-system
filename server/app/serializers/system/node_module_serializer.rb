# frozen_string_literal: true

module System
  class NodeModuleSerializer
    def initialize(node_module)
      @node_module = node_module
    end

    def as_json
      {
        id: @node_module.id,
        name: @node_module.name,
        description: @node_module.description,
        variety: @node_module.variety,
        enabled: @node_module.enabled,
        public: @node_module.public,
        priority: @node_module.priority,
        # Spec fields — wire shape is jsonb arrays of base64-encoded glob
        # lines. Frontend should decode via the same convention as the
        # model's decode_spec when displaying. The *_text variants emit
        # plain newline-joined strings for textarea rendering.
        mask:            @node_module.mask,
        mask_text:       @node_module.mask_text,
        file_spec:       @node_module.file_spec,
        file_spec_text:  @node_module.file_spec_text,
        package_spec:    @node_module.package_spec,
        package_spec_text: @node_module.package_spec_text,
        dependency_spec: @node_module.dependency_spec,
        dependency_spec_text: @node_module.dependency_spec_text,
        protected_spec:  @node_module.protected_spec,
        protected_spec_text: @node_module.protected_spec_text,
        # Lifecycle / lock state
        lock_spec:       @node_module.lock_spec,
        init_start:      @node_module.init_start,
        init_stop:       @node_module.init_stop,
        init_restart:    @node_module.init_restart,
        reboot_required: @node_module.reboot_required,
        config: @node_module.config,
        node_platform_id: @node_module.node_platform_id,
        node_platform_name: @node_module.node_platform&.name,
        category_id: @node_module.category_id,
        category_name: @node_module.category&.name,
        copy_path_id: @node_module.copy_path_id,
        copy_path_name: @node_module.copy_path&.name,
        dependencies_count: @node_module.module_dependencies.count,
        dependents_count: @node_module.dependent_relationships.count,
        assignments_count: @node_module.node_module_assignments.count,
        templates_count: @node_module.template_modules.count,
        created_at: @node_module.created_at,
        updated_at: @node_module.updated_at
      }
    end
  end
end
