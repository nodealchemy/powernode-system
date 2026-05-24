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
  #   services:                       # → ModuleService rows (Decentralized Federation plan §A)
  #     - name: rails
  #       start_command: "bundle exec puma -C config/puma.rb"
  #       stop_command:  "kill -SIGTERM $MAINPID"  # optional
  #       restart_policy: always       # always | on-failure | never
  #       user: powernode              # optional
  #       working_directory: /opt/...  # optional
  #       env: { RAILS_ENV: production }
  #       exposed_ports:
  #         - { port: 3000, protocol: tcp, name: http }
  #       capabilities: []             # Linux capabilities to retain
  #       health:
  #         endpoint: /up              # optional; nil = no HTTP health
  #         method: GET                # GET | POST | PUT
  #         interval_seconds: 30
  #         timeout_seconds: 5
  #         initial_delay_seconds: 10
  #       dependencies:
  #         - { service: postgres, kind: requires_health }  # start_before | requires_health | softdep
  #       metadata: {}
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

    SUPPORTED_SCHEMA_VERSIONS = [ 1 ].freeze

    # Top-level keys we recognize; everything else lands in
    # `config.manifest_extras` for forward compatibility.
    KNOWN_TOP_KEYS = %w[
      schema_version name display_name description license
      mask file_spec package_spec dependency_spec protected_spec
      dependencies init reboot_required security skills build services
      users groups sudoers
    ].freeze

    SPEC_FIELDS = %w[mask file_spec package_spec dependency_spec protected_spec].freeze

    # Per-service schema (manifest.services[*]); see docs/federation/MODULE_MANIFEST_SCHEMA.md.
    SERVICE_KNOWN_KEYS = %w[
      name start_command stop_command restart_policy user working_directory
      env exposed_ports capabilities health dependencies metadata
    ].freeze

    USER_KNOWN_KEYS    = %w[name shell home gecos primary_group supplementary_groups].freeze
    GROUP_KNOWN_KEYS   = %w[name].freeze
    SUDOERS_KNOWN_KEYS = %w[id user runas commands flags].freeze

    class << self
      def import!(node_module:, yaml:, create_version: false, version_changelog: nil)
        new.import!(
          node_module: node_module,
          yaml: yaml,
          create_version: create_version,
          version_changelog: version_changelog
        )
      end

      # Pure validation — no DB writes, no file system access. Operator
      # passes raw yaml + an existing NodeModule (to validate manifest.name
      # matches). Returns a Result with validation_errors. Used by the MCP
      # `system_validate_module_manifest` action so operators can lint a
      # manifest before pushing to CI.
      def validate_only(yaml:, node_module:)
        new.send(:do_validate_only, yaml: yaml, node_module: node_module)
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
        identity_index = apply_identities(node_module, manifest)
        apply_services(node_module, manifest, identity_index)
        apply_sudoers_grants(node_module, manifest, identity_index)

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

    def do_validate_only(yaml:, node_module:)
      return failure("node_module required") unless node_module.is_a?(::System::NodeModule)
      return failure("yaml content is blank") if yaml.blank?

      parsed = parse_yaml(yaml)
      return failure("manifest YAML parse failed: #{parsed[:error]}") unless parsed[:ok]

      errors = validate(parsed[:data], node_module)
      if errors.any?
        Result.new(ok?: false, error: "manifest validation failed",
                   validation_errors: errors, resolved_dependencies: [])
      else
        Result.new(ok?: true, validation_errors: [], resolved_dependencies: [])
      end
    end

    def failure(message, validation_errors: [])
      Result.new(ok?: false, error: message, validation_errors: validation_errors,
                 resolved_dependencies: [])
    end

    def parse_yaml(raw)
      data = YAML.safe_load(raw, permitted_classes: [ Symbol, Date, Time ]) || {}
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
        unless [ true, false ].include?(rb)
          errors << "reboot_required must be a boolean"
        end
      end

      validate_services(manifest, errors)
      validate_groups(manifest, errors)
      validate_users(manifest, errors)
      validate_sudoers(manifest, errors)

      errors
    end

    # Validates `users:` key (fleet-managed Unix users). Caught here so
    # the operator sees the full error set in one round-trip.
    def validate_users(manifest, errors)
      users = manifest["users"]
      return if users.nil?

      unless users.is_a?(Array)
        errors << "users must be an array"
        return
      end

      group_names = Array(manifest["groups"]).filter_map { |g| g.is_a?(Hash) ? g["name"] : nil }.to_set
      seen = Set.new
      users.each_with_index do |entry, i|
        prefix = "users[#{i}]"
        unless entry.is_a?(Hash)
          errors << "#{prefix} must be a hash"
          next
        end

        name = entry["name"]
        if name.blank?
          errors << "#{prefix}.name is required"
        elsif !name.is_a?(String) || !name.match?(::System::ServiceUser::USERNAME_RX)
          errors << "#{prefix}.name #{name.inspect} must match #{::System::ServiceUser::USERNAME_RX.inspect}"
        elsif seen.include?(name)
          errors << "#{prefix}.name #{name.inspect} duplicates an earlier user"
        else
          seen << name
        end

        %w[shell home gecos].each do |k|
          v = entry[k]
          errors << "#{prefix}.#{k} must be a string" if v && !v.is_a?(String)
        end

        pg = entry["primary_group"]
        if pg && !pg.is_a?(String)
          errors << "#{prefix}.primary_group must be a string"
        elsif pg && pg != name && !group_names.include?(pg) &&
              !::System::ServiceGroup.live.exists?(groupname: pg)
          errors << "#{prefix}.primary_group #{pg.inspect} is not declared in this manifest and not allocated platform-wide"
        end

        Array(entry["supplementary_groups"]).each_with_index do |sg, j|
          ref = "#{prefix}.supplementary_groups[#{j}]"
          if !sg.is_a?(String) || !sg.match?(::System::ServiceGroup::GROUPNAME_RX)
            errors << "#{ref} #{sg.inspect} must match #{::System::ServiceGroup::GROUPNAME_RX.inspect}"
          elsif !group_names.include?(sg) && !::System::ServiceGroup.live.exists?(groupname: sg)
            errors << "#{ref} #{sg.inspect} is not declared in this manifest and not allocated platform-wide"
          end
        end
      end
    end

    def validate_groups(manifest, errors)
      groups = manifest["groups"]
      return if groups.nil?

      unless groups.is_a?(Array)
        errors << "groups must be an array"
        return
      end

      seen = Set.new
      groups.each_with_index do |entry, i|
        prefix = "groups[#{i}]"
        unless entry.is_a?(Hash)
          errors << "#{prefix} must be a hash"
          next
        end

        name = entry["name"]
        if name.blank?
          errors << "#{prefix}.name is required"
        elsif !name.is_a?(String) || !name.match?(::System::ServiceGroup::GROUPNAME_RX)
          errors << "#{prefix}.name #{name.inspect} must match #{::System::ServiceGroup::GROUPNAME_RX.inspect}"
        elsif seen.include?(name)
          errors << "#{prefix}.name #{name.inspect} duplicates an earlier group"
        else
          seen << name
        end
      end
    end

    def validate_sudoers(manifest, errors)
      grants = manifest["sudoers"]
      return if grants.nil?

      unless grants.is_a?(Array)
        errors << "sudoers must be an array"
        return
      end

      user_names = Array(manifest["users"]).filter_map { |u| u.is_a?(Hash) ? u["name"] : nil }.to_set
      seen_ids = Set.new
      grants.each_with_index do |entry, i|
        prefix = "sudoers[#{i}]"
        unless entry.is_a?(Hash)
          errors << "#{prefix} must be a hash"
          next
        end

        gid = entry["id"]
        if gid.blank?
          errors << "#{prefix}.id is required"
        elsif !gid.is_a?(String) || !gid.match?(::System::SudoersGrant::GRANT_ID_RX)
          errors << "#{prefix}.id #{gid.inspect} must match #{::System::SudoersGrant::GRANT_ID_RX.inspect}"
        elsif seen_ids.include?(gid)
          errors << "#{prefix}.id #{gid.inspect} duplicates an earlier grant"
        else
          seen_ids << gid
        end

        u = entry["user"]
        if u.blank?
          errors << "#{prefix}.user is required"
        elsif !u.is_a?(String)
          errors << "#{prefix}.user must be a string"
        elsif !user_names.include?(u) && !::System::ServiceUser.live.exists?(username: u)
          errors << "#{prefix}.user #{u.inspect} is not declared in this manifest and not allocated platform-wide"
        end

        cmds = entry["commands"]
        if !cmds.is_a?(Array) || cmds.empty?
          errors << "#{prefix}.commands must be a non-empty array"
        else
          cmds.each_with_index do |cmd, j|
            cref = "#{prefix}.commands[#{j}]"
            if !cmd.is_a?(String)
              errors << "#{cref} must be a string"
            elsif !cmd.start_with?("/")
              errors << "#{cref} must be an absolute path (starts with /)"
            elsif cmd.split(/[\s,]+/).include?("ALL")
              errors << "#{cref} contains the literal token ALL (broad grants forbidden)"
            end
          end
        end
      end
    end

    # Validates `services:` key. Catches schema issues before any DB writes
    # so the operator sees the full error set in one round-trip.
    def validate_services(manifest, errors)
      services = manifest["services"]
      return if services.nil?

      unless services.is_a?(Array)
        errors << "services must be an array"
        return
      end

      seen_names = Set.new
      services.each_with_index do |svc, i|
        prefix = "services[#{i}]"
        unless svc.is_a?(Hash)
          errors << "#{prefix} must be a hash"
          next
        end

        name = svc["name"]
        if name.blank?
          errors << "#{prefix}.name is required"
        elsif !name.is_a?(String)
          errors << "#{prefix}.name must be a string"
        elsif seen_names.include?(name)
          errors << "#{prefix}.name #{name.inspect} duplicates an earlier service"
        else
          seen_names << name
        end

        if svc["start_command"].blank?
          errors << "#{prefix}.start_command is required"
        elsif !svc["start_command"].is_a?(String)
          errors << "#{prefix}.start_command must be a string"
        end

        if (rp = svc["restart_policy"]) && !::System::ModuleService::RESTART_POLICIES.include?(rp)
          errors << "#{prefix}.restart_policy must be one of #{::System::ModuleService::RESTART_POLICIES.inspect}"
        end

        if (health = svc["health"])
          unless health.is_a?(Hash)
            errors << "#{prefix}.health must be a hash"
          else
            if (m = health["method"]) && !::System::ModuleService::HEALTH_METHODS.include?(m)
              errors << "#{prefix}.health.method must be one of #{::System::ModuleService::HEALTH_METHODS.inspect}"
            end
          end
        end

        if (deps = svc["dependencies"])
          unless deps.is_a?(Array)
            errors << "#{prefix}.dependencies must be an array"
          else
            deps.each_with_index do |dep, j|
              dep_prefix = "#{prefix}.dependencies[#{j}]"
              unless dep.is_a?(Hash)
                errors << "#{dep_prefix} must be a hash"
                next
              end
              errors << "#{dep_prefix}.service is required" if dep["service"].blank?
              if (k = dep["kind"]) && !::System::ModuleServiceDependency::KINDS.include?(k)
                errors << "#{dep_prefix}.kind must be one of #{::System::ModuleServiceDependency::KINDS.inspect}"
              end
            end
          end
        end
      end
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

    # Upserts ModuleService rows from manifest.services[]. Idempotent:
    # re-importing with the same services updates fields without churn;
    # services declared in the DB but absent from the manifest are deleted
    # (manifest_yaml is the authoritative source for service definitions).
    # Cross-service dependencies are resolved within this manifest only.
    #
    # identity_index is the {users:, groups:} hash returned by
    # apply_identities — used to resolve svc["user"] to a ServiceUser FK.
    # A service whose declared user is neither in this manifest nor
    # already allocated platform-wide raises ImportError (the manifest
    # is incomplete).
    def apply_services(mod, manifest, identity_index = { users: {}, groups: {} })
      services_yaml = Array(manifest["services"])
      declared_names = services_yaml.map { |s| s["name"] }.compact

      mod.module_services.where.not(name: declared_names).destroy_all if declared_names.any?
      mod.module_services.destroy_all if services_yaml.empty?

      service_records_by_name = {}

      services_yaml.each do |svc|
        record = ::System::ModuleService.find_or_initialize_by(node_module: mod, name: svc["name"])
        record.account = mod.account
        record.start_command = svc["start_command"]
        record.stop_command  = svc["stop_command"]
        record.restart_policy = svc.fetch("restart_policy", "always")
        assign_service_user!(record, mod, svc, identity_index)
        record.working_directory = svc["working_directory"]
        record.env           = svc["env"] || {}
        record.exposed_ports = svc["exposed_ports"] || []
        record.capabilities  = svc["capabilities"] || []
        record.metadata      = svc["metadata"] || {}

        health = svc["health"] || {}
        record.health_endpoint              = health["endpoint"]
        record.health_method                = health.fetch("method", "GET")
        record.health_interval_seconds      = health.fetch("interval_seconds", 30)
        record.health_timeout_seconds       = health.fetch("timeout_seconds", 5)
        record.health_initial_delay_seconds = health.fetch("initial_delay_seconds", 10)

        record.save!
        service_records_by_name[svc["name"]] = record
      end

      # Resolve cross-service dependencies. References must resolve within
      # the same node_module (the model's same_node_module validation enforces
      # this; here we surface a clear error for missing names rather than
      # passing a nil to the validation).
      services_yaml.each do |svc|
        source = service_records_by_name[svc["name"]]
        existing_targets = source.outgoing_dependencies.pluck(:depends_on_module_service_id)
        declared_targets = []

        Array(svc["dependencies"]).each do |dep|
          target = service_records_by_name[dep["service"]]
          unless target
            raise ImportError, "services[#{svc['name']}].dependencies references unknown service #{dep['service'].inspect}"
          end
          edge = ::System::ModuleServiceDependency.find_or_initialize_by(
            module_service: source,
            depends_on_module_service: target
          )
          edge.kind = dep.fetch("kind", "requires_health")
          edge.save!
          declared_targets << target.id
        end

        (existing_targets - declared_targets).each do |stale_id|
          source.outgoing_dependencies.where(depends_on_module_service_id: stale_id).destroy_all
        end
      end
    end

    # Allocates ServiceGroup + ServiceUser rows for everything declared
    # in manifest["groups"] and manifest["users"], reconciles the
    # ModuleUserDeclaration join rows for this module, and returns an
    # index callers can use to resolve names without re-hitting the DB.
    #
    # Groups are allocated FIRST so user.primary_group_id can be
    # satisfied without a second pass. Auto-creation of a same-name
    # primary group lives inside UserAllocator (debian USERGROUPS_ENAB
    # behavior); explicit primary_group references must resolve to a
    # group declared here or already allocated platform-wide
    # (validation enforces this).
    def apply_identities(mod, manifest)
      index = { users: {}, groups: {} }
      groups_yaml = Array(manifest["groups"])
      users_yaml  = Array(manifest["users"])

      groups_yaml.each do |entry|
        group = ::System::Identity::GroupAllocator.allocate!(groupname: entry["name"])
        index[:groups][entry["name"]] = group
      end

      users_yaml.each do |entry|
        primary = if entry["primary_group"].present?
                    index[:groups][entry["primary_group"]] ||
                      ::System::ServiceGroup.live.find_by!(groupname: entry["primary_group"])
                  end
        user = ::System::Identity::UserAllocator.allocate!(
          username:             entry["name"],
          primary_group:        primary,
          shell:                entry["shell"],
          home:                 entry["home"],
          gecos:                entry["gecos"].to_s,
          supplementary_groups: Array(entry["supplementary_groups"]).map do |sg|
            index[:groups][sg] ||
              ::System::ServiceGroup.live.find_by!(groupname: sg)
          end
        )
        index[:users][entry["name"]] = user
        # Auto-created primary group from UserAllocator isn't in the
        # manifest's groups: list — capture it in the index so apply_
        # sudoers_grants and serializers can find it.
        index[:groups][user.primary_groupname] ||= user.primary_group
      end

      reconcile_module_declarations!(mod, index)

      index
    end

    # Track the set of (module, identity) declarations so the reaper can
    # tell when no module still claims a given user/group. Adds rows for
    # the current manifest; destroys rows that no longer match. The
    # ModuleUserDeclaration#before_destroy hook starts a 24h drain on
    # any identity left without a declarer.
    def reconcile_module_declarations!(mod, index)
      desired_user_ids  = index[:users].values.map(&:id).to_set
      desired_group_ids = index[:groups].values.map(&:id).to_set

      mod.module_user_declarations
         .where.not(service_user_id: nil)
         .where.not(service_user_id: desired_user_ids.to_a)
         .destroy_all
      mod.module_user_declarations
         .where.not(service_group_id: nil)
         .where.not(service_group_id: desired_group_ids.to_a)
         .destroy_all

      desired_user_ids.each do |uid|
        ::System::ModuleUserDeclaration.find_or_create_by!(node_module_id: mod.id, service_user_id: uid)
      end
      desired_group_ids.each do |gid|
        ::System::ModuleUserDeclaration.find_or_create_by!(node_module_id: mod.id, service_group_id: gid)
      end
    end

    # Assigns the right user-source field on a ModuleService row from
    # the manifest's `services[].user:` value. There are two paths:
    #
    #   1. Well-known system users (root, nobody, daemon, etc.) live
    #      outside System::ServiceUser's 70_000+ allocation range and
    #      already exist on every Linux rootfs — these go in the
    #      `system_user` string column and leave service_user_id NULL.
    #      No ModuleUserDeclaration: the agent never renders these to
    #      /etc/passwd, so there's nothing for the reaper to keep alive.
    #
    #   2. Module-declared users (allocated via manifest's `users:`
    #      block, surfaced through identity_index) get an FK to the
    #      matching System::ServiceUser plus a ModuleUserDeclaration
    #      so the reaper treats consumer references as keep-alive —
    #      without that join, uninstalling the *declaring* module
    #      would orphan running services that consume the identity.
    def assign_service_user!(record, mod, svc, identity_index)
      raw = svc["user"]
      raise ImportError, "services[#{svc['name']}].user is required" if raw.blank?

      if ::System::ModuleService::WELL_KNOWN_SYSTEM_USERS.include?(raw)
        record.system_user  = raw
        record.service_user = nil
        return
      end

      user = identity_index[:users][raw] ||
             ::System::ServiceUser.live.find_by(username: raw)
      raise ImportError,
            "services[#{svc['name']}].user #{raw.inspect} is not declared in this manifest and not allocated platform-wide" unless user

      ::System::ModuleUserDeclaration.find_or_create_by!(
        node_module_id:  mod.id,
        service_user_id: user.id
      )
      record.service_user = user
      record.system_user  = nil
    end

    # Upserts SudoersGrant rows from manifest.sudoers[]. Idempotent
    # per (module, grant_id). Removed grants are destroyed immediately
    # (no drain) — see plan §8: sudo is a runtime check with no
    # persistent state, so revocation MUST be effective on the next
    # reconcile tick. Model validations enforce absolute paths +
    # rejection of the ALL keyword; the agent runs visudo -cf before
    # writing each file to catch anything model validation misses.
    def apply_sudoers_grants(mod, manifest, identity_index)
      grants_yaml = Array(manifest["sudoers"])
      declared_ids = grants_yaml.filter_map { |g| g["id"] }

      mod.sudoers_grants.where.not(grant_id: declared_ids).destroy_all if declared_ids.any?
      mod.sudoers_grants.destroy_all if grants_yaml.empty?

      grants_yaml.each do |entry|
        user = identity_index[:users][entry["user"]] ||
               ::System::ServiceUser.live.find_by(username: entry["user"])
        raise ImportError,
              "sudoers[#{entry['id']}].user #{entry['user'].inspect} is not declared in this manifest and not allocated platform-wide" unless user

        record = ::System::SudoersGrant.find_or_initialize_by(
          node_module_id: mod.id, grant_id: entry["id"]
        )
        record.service_user = user
        record.runas_user   = entry["runas"].presence || "root"
        record.runas_group  = nil
        record.commands     = Array(entry["commands"])
        record.flags        = Array(entry["flags"])
        record.state        = "active"
        record.save!
      end
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
