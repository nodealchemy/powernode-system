# frozen_string_literal: true

module System
  class NodeModuleSerializer
    # include_webhook_secret: when true, the module's DERIVED webhook signing
    # secret is added to the output. SECURITY: this is signing material — the
    # caller MUST gate it (show-only + module-manager permission). Defaults
    # false so index/list and unprivileged callers never receive it.
    def initialize(node_module, include_webhook_secret: false)
      @node_module = node_module
      @include_webhook_secret = include_webhook_secret
    end

    def as_json
      base = {
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
        # Dependant-module hierarchy (legacy parent_module restoration).
        # When parent_module_id is present, this module is a dependant
        # config-variety or instance-variety override and inherits its
        # `file_spec` from the parent's `dependency_spec`. The frontend
        # uses these to render dependants with a "Inherited from <parent>"
        # note on file_spec, since editing the column has no effect.
        parent_module_id:   @node_module.parent_module_id,
        parent_module_name: @node_module.parent_module&.name,
        dependant:          @node_module.parent_module_id.present?,
        dependencies_count: @node_module.module_dependencies.count,
        dependents_count: @node_module.dependent_relationships.count,
        assignments_count: @node_module.node_module_assignments.count,
        templates_count: @node_module.template_modules.count,
        created_at: @node_module.created_at,
        updated_at: @node_module.updated_at,
        # Latest version snapshot — used by the operator UI's per-node module
        # detail view to surface version_number + promotion_state at a glance.
        # Returns nil when the module has no versions yet (e.g. brand-new
        # module before its first publish round-trip).
        latest_version: latest_version_summary
      }

      # Derived per-module webhook signing secret — SHOW-ONLY, gated by the
      # caller to module-managers. Operators copy this into the module's
      # Gitea repo webhook config + the repo's POWERNODE_WEBHOOK_SECRET
      # Actions secret so module-publish and SBOM callbacks verify under
      # POWERNODE_MODULE_WEBHOOK_ENFORCE. nil in prod when no server root
      # secret is configured. NEVER logged.
      base[:webhook_secret] = @node_module.derived_webhook_secret if @include_webhook_secret

      base
    end

    private

    def latest_version_summary
      return nil unless defined?(::System::NodeModuleVersion)
      v = ::System::NodeModuleVersion
            .where(node_module_id: @node_module.id)
            .order(created_at: :desc)
            .first
      return nil unless v
      {
        id: v.id,
        version_number: v.version_number,
        promotion_state: v.promotion_state,
        oci_digest: v.oci_digest,
        blessed_at: v.blessed_at,
        live_at: v.live_at,
        created_at: v.created_at
      }
    end
  end
end
