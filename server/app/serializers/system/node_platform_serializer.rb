# frozen_string_literal: true

module System
  class NodePlatformSerializer
    # template_count / module_count may be supplied pre-computed by the caller
    # (see NodePlatformsController#serialize_collection, which batches both
    # counts across the whole page in two grouped queries to avoid an N+1).
    # When omitted — e.g. the single-record show/create/update paths — they
    # fall back to per-record queries. `nil` means "not provided"; a real 0
    # from a batched hash is preserved (0 is truthy in Ruby).
    def initialize(platform, template_count: nil, module_count: nil)
      @platform = platform
      @template_count = template_count
      @module_count = module_count
    end

    def as_json
      {
        id: @platform.id,
        name: @platform.name,
        description: @platform.description,
        enabled: @platform.enabled,
        public: @platform.public,
        node_architecture_id: @platform.node_architecture_id,
        architecture_name: @platform.node_architecture&.name,
        build_script: @platform.build_script,
        init_script: @platform.init_script,
        sync_script: @platform.sync_script,
        template_count: template_count,
        # Distinct modules across all templates on this platform. There is no
        # direct platform→module association — modules attach to templates via
        # TemplateModule — so this collapses shared modules to one.
        module_count: module_count,
        # Disk image (claim-flow / fleet generic image) — populated by the
        # disk-image publication processor when CI builds + uploads an .img.
        # The UI uses disk_image_publication_status to offer "Download image";
        # the bytes come from the disk_image member action.
        disk_image_file_object_id:     @platform.disk_image_file_object_id,
        disk_image_sha256:             @platform.disk_image_sha256,
        disk_image_size_bytes:         @platform.disk_image_size_bytes,
        disk_image_built_at:           @platform.disk_image_built_at,
        disk_image_oci_ref:            @platform.disk_image_oci_ref,
        disk_image_git_sha:            @platform.disk_image_git_sha,
        disk_image_publication_status: @platform.disk_image_publication_status,
        disk_image_publication_error:  @platform.disk_image_publication_error,
        disk_image_retention_count:    @platform.disk_image_retention_count,
        cosign_identity_regexp:        @platform.cosign_identity_regexp,
        cosign_issuer_regexp:          @platform.cosign_issuer_regexp,
        created_at: @platform.created_at,
        updated_at: @platform.updated_at
      }
    end

    private

    def template_count
      @template_count ||= @platform.node_templates.count
    end

    def module_count
      @module_count ||= System::TemplateModule
                        .where(node_template_id: @platform.node_templates.select(:id))
                        .distinct.count(:node_module_id)
    end
  end
end
