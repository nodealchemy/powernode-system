# frozen_string_literal: true

module System
  # Builds a portable JSON bundle for a System::NodeTemplate including its
  # platform reference and module assignments. Output is intentionally
  # account-agnostic: IDs are kept only as same-instance re-import hints,
  # while names + variety act as the canonical cross-instance keys.
  #
  # Returns System::Runtime::Result wrapping the bundle hash on success.
  class TemplateExporter
    BUNDLE_FORMAT_VERSION = "1.0"
    BUNDLE_KIND = "system.node_template"

    def self.export(template:)
      new.export(template: template)
    end

    def export(template:)
      validate_template!(template)

      Rails.logger.info("[TemplateExporter] Exporting template #{template.name}")

      bundle = {
        format_version: BUNDLE_FORMAT_VERSION,
        kind: BUNDLE_KIND,
        exported_at: Time.current.iso8601,
        template: serialize_template(template),
        platform: serialize_platform(template.node_platform),
        modules: serialize_modules(template)
      }

      Runtime::Result.ok(data: { bundle: bundle, filename: filename_for(template) })
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[TemplateExporter] Export failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    private

    def validate_template!(template)
      raise ArgumentError, "Template required" unless template
      raise ArgumentError, "Template must be a System::NodeTemplate" unless template.is_a?(::System::NodeTemplate)
    end

    def serialize_template(template)
      {
        id: template.id,
        name: template.name,
        description: template.description,
        enabled: template.enabled,
        public: template.public,
        admin_user: template.admin_user,
        config: template.config || {}
      }
    end

    def serialize_platform(platform)
      return nil unless platform

      {
        id: platform.id,
        name: platform.name,
        architecture_name: platform.node_architecture&.name
      }
    end

    def serialize_modules(template)
      template.template_modules.includes(node_module: :node_platform).order(priority: :desc).map do |tm|
        mod = tm.node_module
        {
          module_id: mod&.id,
          module_name: mod&.name,
          module_variety: mod&.variety,
          module_platform_name: mod&.node_platform&.name,
          priority: tm.priority,
          enabled: tm.enabled,
          config: tm.config || {}
        }
      end
    end

    def filename_for(template)
      "system-template-#{template.name.parameterize}-#{Time.current.strftime('%Y%m%d%H%M%S')}.json"
    end
  end
end
