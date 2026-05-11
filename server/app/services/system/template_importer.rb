# frozen_string_literal: true

module System
  # Reverses TemplateExporter — consumes a JSON bundle and creates a
  # NodeTemplate + TemplateModule rows in the target account. Modules
  # are resolved by (name, variety) within the account; if any are
  # missing, the import is refused with the list so operators can
  # author them first.
  #
  # Bundle format: System::TemplateExporter::BUNDLE_FORMAT_VERSION ("1.0",
  # kind: "system.node_template"). Mismatched format_version or kind
  # is refused.
  #
  # Same-account import is the common case (clone-by-rename); cross-
  # account imports work but require the target account to have the
  # named platform + every referenced module.
  class TemplateImporter
    class ImportError < StandardError; end

    Result = Struct.new(
      :ok, :template, :template_modules_count, :missing_modules, :warnings, :errors,
      keyword_init: true
    ) do
      alias_method :ok?, :ok
    end

    SUPPORTED_FORMAT_VERSIONS = %w[1.0].freeze
    SUPPORTED_KIND            = "system.node_template"

    def initialize(account)
      @account = account
    end

    # bundle — Hash parsed from the exporter's JSON.
    # new_name — optional override; defaults to bundle.template.name.
    def import!(bundle:, new_name: nil)
      bundle = bundle.is_a?(Hash) ? bundle.with_indifferent_access : raise(ImportError, "bundle must be a Hash")
      validate_bundle!(bundle)

      platform = resolve_platform!(bundle[:platform])
      modules_payload = Array(bundle[:modules])
      modules_by_key  = resolve_modules(modules_payload)

      missing = modules_payload.reject do |m|
        modules_by_key.key?(module_key(m))
      end.map { |m| { name: m[:module_name], variety: m[:module_variety] } }

      if missing.any?
        return Result.new(
          ok: false, template: nil, template_modules_count: 0,
          missing_modules: missing, warnings: [],
          errors: [ "missing modules in target account: #{missing.size}" ]
        )
      end

      tmpl_attrs = bundle[:template].slice(:description, :enabled, :public, :admin_user, :config)
      target_name = (new_name.presence || bundle[:template][:name]).to_s
      raise ImportError, "template name required" if target_name.blank?

      template = nil
      tm_count = 0
      ActiveRecord::Base.transaction do
        template = ::System::NodeTemplate.create!(
          tmpl_attrs.merge(
            account: @account,
            node_platform: platform,
            name: target_name
          )
        )

        modules_payload.each do |m|
          node_module = modules_by_key.fetch(module_key(m))
          ::System::TemplateModule.create!(
            node_template: template,
            node_module: node_module,
            priority: m[:priority].to_i,
            enabled: m.fetch(:enabled, true) != false,
            config: m[:config] || {}
          )
          tm_count += 1
        end
      end

      Result.new(
        ok: true, template: template, template_modules_count: tm_count,
        missing_modules: [], warnings: [], errors: []
      )
    rescue ImportError => e
      Result.new(ok: false, template: nil, template_modules_count: 0,
                 missing_modules: [], warnings: [], errors: [ e.message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, template: nil, template_modules_count: 0,
                 missing_modules: [], warnings: [], errors: [ e.message ])
    end

    private

    def validate_bundle!(bundle)
      unless SUPPORTED_FORMAT_VERSIONS.include?(bundle[:format_version].to_s)
        raise ImportError, "unsupported format_version: #{bundle[:format_version].inspect}"
      end
      unless bundle[:kind].to_s == SUPPORTED_KIND
        raise ImportError, "unsupported kind: #{bundle[:kind].inspect} (expected #{SUPPORTED_KIND})"
      end
      raise ImportError, "bundle.template required" unless bundle[:template].is_a?(Hash)
      raise ImportError, "bundle.platform required" unless bundle[:platform].is_a?(Hash)
    end

    def resolve_platform!(platform_payload)
      name = platform_payload[:name].to_s
      raise ImportError, "platform.name required" if name.blank?

      platform = @account.system_node_platforms.find_by(name: name)
      raise ImportError, "platform not found in account: #{name}" unless platform
      platform
    end

    # Returns Hash<[name, variety], NodeModule>
    def resolve_modules(modules_payload)
      keys = modules_payload.map { |m| module_key(m) }
      return {} if keys.empty?

      names = keys.map(&:first).uniq
      @account.system_node_modules
              .where(name: names)
              .index_by { |m| [ m.name, m.variety ] }
    end

    def module_key(payload)
      [ payload[:module_name].to_s, payload[:module_variety].to_s ]
    end
  end
end
