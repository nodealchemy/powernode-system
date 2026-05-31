# frozen_string_literal: true

module System
  class NodePlatformSerializer
    def initialize(platform)
      @platform = platform
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
        templates_count: @platform.node_templates.count,
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
  end
end
