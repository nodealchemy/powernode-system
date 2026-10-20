# frozen_string_literal: true

module System
  class NodeArchitectureSerializer
    def initialize(architecture)
      @architecture = architecture
    end

    def as_json
      {
        id: @architecture.id,
        name: @architecture.name,
        apt_name: @architecture.apt_name,
        rpm_name: @architecture.rpm_name,
        display_name: @architecture.display_name,
        family: @architecture.family,
        description: @architecture.description,
        kernel_options: @architecture.kernel_options,
        aliases: Array(@architecture.aliases),
        enabled: @architecture.enabled,
        public: @architecture.public,
        is_canonical: @architecture.is_canonical,
        usage: {
          node_platforms: @architecture.node_platform_count,
          package_repositories: @architecture.package_repository_count,
          packages: @architecture.package_count
        },
        # Kept as a top-level field for callers that read it directly.
        platforms_count: @architecture.node_platform_count,
        created_at: @architecture.created_at,
        updated_at: @architecture.updated_at
      }
    end
  end
end
