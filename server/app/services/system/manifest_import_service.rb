# frozen_string_literal: true

module System
  # Parses a module manifest.yaml and writes its declared spec/lifecycle
  # fields onto an existing NodeModule (and optionally creates a new
  # NodeModuleVersion snapshot). Closes the gap where the manifest_yaml
  # column existed but nothing parsed it — the catalog seed and the
  # example-module repos hand-wrote the same data twice.
  #
  # Manifest schema (v1):
  #   schema_version: 1
  #   name: <module name>             # validated against NodeModule.name
  #   display_name: "Human label"     # optional
  #   description: "..."              # NodeModule.description
  #   license: "MIT"                  # informational; stored verbatim
  #   mask:            [<glob>...]    # NodeModule.mask         (local rsync exclude)
  #   file_spec:       [<glob>...]    # NodeModule.file_spec    (paths shipped in this module's blob)
  #   package_spec:    [<deb>...]     # NodeModule.package_spec (deb packages)
  #   dependency_spec: [<glob>...]    # NodeModule.dependency_spec — the file-spec
  #                                   #   inherited by THIS module's dependant
  #                                   #   children (config / instance varieties
  #                                   #   created via `parent_module: <self>`).
  #                                   #   Subscription-variety bases populate it;
  #                                   #   leaf modules with no dependants leave it
  #                                   #   empty.
  #   protected_spec: [<glob>...]     # NodeModule.protected_spec (cross-neighbor sensitive claim)
  #   dependencies:
  #     requires:  [<repo>@<ver>...]  # resolved to ModuleDependency rows
  #     provides:  [<capability>...]  # informational
  #   init:
  #     start: "..."                  # NodeModule.init_start
  #     stop:  "..."                  # NodeModule.init_stop
  #     restart: "..."                # NodeModule.init_restart
  #   reboot_required: false          # NodeModule.reboot_required
  #   security:
  #     capabilities: [...]           # config.security.capabilities
  #     egress_allow: [...]           # config.security.egress_allow
  #     privileged: false             # config.security.privileged
  #   skills: [...]                   # config.skills (consumed by ModuleSkillRegistrar)
  #   build:
  #     ubuntu_digest: null           # config.build.ubuntu_digest
  #     apt_snapshot:  "..."          # config.build.apt_snapshot
  #
  # Anything not in the schema is preserved on `config` under a
  # `manifest_extras` key, so authors can iterate without us racing
  # to update validation.
  #
  # Reference: Golden Eclipse plan M1 module supply chain; user request
  # 2026-05-02 (manifest YAML import service).
  class ManifestImportService
    Result = Struct.new(:ok?, :error, :node_module, :node_module_version,
                        :validation_errors, :resolved_dependencies,
                        keyword_init: true)

    class ImportError < StandardError; end

    SUPPORTED_SCHEMA_VERSIONS = [1].freeze

    # Top-level keys we recognize; everything else lands in
    # `config.manifest_extras` for forward compatibility.
    KNOWN_TOP_KEYS = %w[
      schema_version name display_name description license
      mask file_spec package_spec dependency_spec protected_spec
      dependencies init reboot_required security skills build
    ].freeze

    SPEC_FIELDS = %w[mask file_spec package_spec dependency_spec protected_spec].freeze

    class << self
      def import!(node_module:, yaml:, create_version: false, version_changelog: nil)
        new.import!(
          node_module: node_module,
          yaml: yaml,
          create_version: create_version,
          version_changelog: version_changelog
        )
      end
    end

    def import!(node_module:, yaml:, create_version: false, version_changelog: nil)
      return failure("node_module required") unless node_module.is_a?(::System::NodeModule)
      return failure("yaml content is blank") if yaml.blank?

      parsed = parse_yaml(yaml)
      return failure("manifest YAML parse failed: #{parsed[:error]}") unless parsed[:ok]

      manifest = parsed[:data]
      validation_errors = validate(manifest, node_module)
      return failure("manifest validation failed", validation_errors: validation_errors) if validation_errors.any?

      ActiveRecord::Base.transaction do
        apply_to_module(node_module, manifest, raw_yaml: yaml)
        node_module.save!

        resolved = resolve_dependencies(node_module, manifest)

        if create_version
          version = snapshot_version(node_module, manifest, version_changelog)
          return Result.new(ok?: true, node_module: node_module, node_module_version: version,
                            validation_errors: [], resolved_dependencies: resolved)
        end

        Result.new(ok?: true, node_module: node_module, node_module_version: nil,
                   validation_errors: [], resolved_dependencies: resolved)
      end
    rescue ActiveRecord::RecordInvalid => e
      failure("save failed: #{e.message}", validation_errors: Array(e.record.errors.full_messages))
    rescue ImportError => e
      failure(e.message)
    end

    private

    def failure(message, validation_errors: [])
      Result.new(ok?: false, error: message, validation_errors: validation_errors,
                 resolved_dependencies: [])
    end

    def parse_yaml(raw)
      data = YAML.safe_load(raw, permitted_classes: [Symbol, Date, Time]) || {}
      return { ok: false, error: "manifest is not a hash" } unless data.is_a?(Hash)
      { ok: true, data: data.with_indifferent_access }
    rescue Psych::SyntaxError => e
      { ok: false, error: e.message }
    end

    def validate(manifest, node_module)
      errors = []

      schema_v = manifest["schema_version"]
      unless schema_v && SUPPORTED_SCHEMA_VERSIONS.include?(schema_v.to_i)
        errors << "schema_version must be one of #{SUPPORTED_SCHEMA_VERSIONS.inspect} (got #{schema_v.inspect})"
      end

      if manifest["name"].present? && manifest["name"] != node_module.name
        errors << "manifest name #{manifest['name'].inspect} does not match NodeModule name #{node_module.name.inspect}"
      end

      SPEC_FIELDS.each do |field|
        value = manifest[field]
        next if value.nil?
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
          errors << "#{field} must be an array of strings"
        end
      end

      if (init = manifest["init"]).is_a?(Hash)
        %w[start stop restart].each do |key|
          v = init[key]
          errors << "init.#{key} must be a string" if v && !v.is_a?(String)
        end
      elsif !manifest["init"].nil?
        errors << "init must be a hash with start/stop/restart keys"
      end

      if (rb = manifest["reboot_required"])
        unless [true, false].include?(rb)
          errors << "reboot_required must be a boolean"
        end
      end

      errors
    end

    def apply_to_module(mod, manifest, raw_yaml:)
      mod.manifest_yaml = raw_yaml

      mod.description = manifest["description"] if manifest.key?("description")

      # Spec fields — pass arrays through encode_spec by joining to
      # newline-strings so the model's encode_specs callback base64-
      # encodes each line on save.
      SPEC_FIELDS.each do |field|
        next unless manifest.key?(field)
        lines = Array(manifest[field])
        mod.public_send("#{field}=", lines.join("\n"))
      end

      if (init = manifest["init"]).is_a?(Hash)
        mod.init_start   = init["start"]   if init.key?("start")
        mod.init_stop    = init["stop"]    if init.key?("stop")
        mod.init_restart = init["restart"] if init.key?("restart")
      end

      mod.reboot_required = manifest["reboot_required"] if manifest.key?("reboot_required")

      # Stash everything else on config so authoring iterations don't
      # require platform schema bumps. Skills, security, and build hints
      # are read by their respective consumers (ModuleSkillRegistrar,
      # the agent's attach-time policy enforcer, the CI workflow) from
      # this same hash.
      mod.config ||= {}
      preserved = mod.config.is_a?(Hash) ? mod.config.deep_dup : {}

      %w[skills security build display_name license].each do |key|
        preserved[key] = manifest[key] if manifest.key?(key)
      end

      extras = manifest.reject { |k, _| KNOWN_TOP_KEYS.include?(k.to_s) }
      preserved["manifest_extras"] = extras.to_h unless extras.empty?

      mod.config = preserved
    end

    # Resolve manifest.dependencies.requires to ModuleDependency rows.
    # Format: "<gitea_full_name>@<version_constraint>" (constraint optional).
    # Modules not yet present in the platform are skipped silently — the
    # webhook ingestion path will re-resolve when their first version
    # publishes. We log + return the unresolved set so callers can surface
    # it to the operator.
    def resolve_dependencies(mod, manifest)
      deps = manifest.dig("dependencies", "requires") || []
      return [] if deps.empty?

      resolved = []
      deps.each do |raw|
        repo, constraint = raw.to_s.split("@", 2)
        next if repo.blank?

        target = ::System::NodeModule
                 .where(account_id: mod.account_id)
                 .where("gitea_repo_full_name = ? OR name = ?", repo, repo.split("/").last)
                 .first

        if target
          dep = ::System::ModuleDependency.find_or_initialize_by(node_module: mod, dependency: target)
          dep.dependency_type    = "requires"
          dep.required           = true
          dep.version_constraint = constraint if constraint.present?
          dep.save!
          resolved << { repo: repo, constraint: constraint, status: "resolved", dependency_id: target.id }
        else
          resolved << { repo: repo, constraint: constraint, status: "unresolved" }
          Rails.logger.info("[ManifestImportService] dependency #{repo.inspect} not yet known on platform; deferring")
        end
      end
      resolved
    end

    def snapshot_version(mod, manifest, changelog)
      next_number = (mod.versions.maximum(:version_number) || 0) + 1

      encoded = ->(arr) {
        Array(arr).map { |line| ::Base64.strict_encode64(line.to_s) }.uniq.sort
      }

      version = ::System::NodeModuleVersion.new(
        node_module:    mod,
        version_number: next_number,
        changelog:      changelog || "Imported from manifest schema_version=#{manifest['schema_version']}",
        mask:            encoded.call(manifest["mask"]),
        file_spec:       encoded.call(manifest["file_spec"]),
        package_spec:    encoded.call(manifest["package_spec"]),
        protected_spec:  encoded.call(manifest["protected_spec"]),
        config: { "manifest_extras" => mod.config["manifest_extras"] || {} },
        promotion_state: "built"
      )
      version.save!
      mod.update!(current_version: version)
      version
    end
  end
end
