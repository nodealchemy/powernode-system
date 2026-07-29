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
      schema_version name display_name description license category
      mask file_spec package_spec dependency_spec protected_spec
      dependencies init reboot_required security skills build services
      users groups sudoers
    ].freeze

    SPEC_FIELDS = %w[mask file_spec package_spec dependency_spec protected_spec].freeze

    # Per-service schema (manifest.services[*]); see docs/federation/MODULE_MANIFEST_SCHEMA.md.
    SERVICE_KNOWN_KEYS = %w[
      name start_command stop_command restart_policy user working_directory
      env exposed_ports capabilities health dependencies metadata unit_body
    ].freeze

    USER_KNOWN_KEYS    = %w[name shell home gecos primary_group supplementary_groups].freeze
    GROUP_KNOWN_KEYS   = %w[name].freeze
    SUDOERS_KNOWN_KEYS = %w[id user runas commands flags].freeze

    # Matches any file_spec entry that ships (or globs) a path under
    # /home — with or without a leading slash, and whether or not it's
    # the literal directory or a glob underneath it.
    HOME_PATH_RX = %r{\A/?home(/|\z)}i

    # Prefixes/exact paths a manifest's `users[].home` is allowed to
    # point at. This is deliberately broader than the agent's actual
    # runtime home-ownership reconciler (etcidentity.managedHomeRoots,
    # scoped to /home/* only) — it's a manifest-authoring guardrail so a
    # module can't declare a `home` that lands somewhere like /etc or /
    # (either because the agent's reconciler is later widened, or
    # because some other consumer of the `home` field, e.g. a service's
    # HOME env var, would otherwise be pointed at a sensitive shared
    # system path). Every entry here already appears as a `home:` value
    # in a shipped module manifest or extensions/system/agent/internal/
    # etcidentity/baseline.go.
    ALLOWED_HOME_ROOTS = %w[
      /home/ /var/lib/ /run/ /var/run/ /nonexistent /usr/sbin /bin /dev /root /run/sshd
    ].freeze

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

      # Re-runs ONLY the dependency-graph resolution step (resolve_
      # dependencies) against an already-imported node_module — no spec/
      # identity/service writes, no version snapshot. Exists for seeds like
      # db/seeds/powernode_platform_modules.rb that import a whole batch of
      # manifests in one alphabetical pass: a `requires: capability:<tag>`
      # (or a name-based `requires:`) silently defers when the PROVIDING
      # module hasn't been created + imported yet (its `capabilities` /
      # `name` isn't in the DB), so a module that sorts BEFORE its provider
      # (e.g. claude-tmux before runtime-node) ends the pass with an
      # unresolved edge even though the provider exists by the time the
      # whole batch finishes. Calling this a second time, after every
      # module in the batch has been created + imported once, re-resolves
      # any edge that deferred on the first pass. Idempotent — safe to call
      # on a node_module whose deps already fully resolved (upsert_
      # dependency! no-ops on an existing edge).
      def reresolve_dependencies!(node_module:, yaml:)
        new.send(:do_reresolve_dependencies, node_module: node_module, yaml: yaml)
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
        # Suppress NodeModule#auto_create_version for the manifest-import
        # save. This service is the parser/applier for CI-published
        # manifests AND the seed re-import path — it writes file_spec /
        # package_spec / mask AHEAD of the artifact upload (which lands
        # separately via PackageBuildWebhookService). Without this
        # suppression, the after_update callback would create an
        # empty-artifact NodeModuleVersion every import, and then the
        # actual artifact upload creates a SECOND version with the same
        # spec content — paired spec-only / full-artifact rows for every
        # CI publish. Callers that want a version row from this service
        # pass create_version: true (snapshot_version below explicitly
        # builds the snapshot, paired with the manifest content).
        node_module.instance_variable_set(:@skip_auto_version, true)
        begin
          node_module.save!
        ensure
          node_module.instance_variable_set(:@skip_auto_version, false)
        end

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

    def do_reresolve_dependencies(node_module:, yaml:)
      return failure("node_module required") unless node_module.is_a?(::System::NodeModule)
      return failure("yaml content is blank") if yaml.blank?

      parsed = parse_yaml(yaml)
      return failure("manifest YAML parse failed: #{parsed[:error]}") unless parsed[:ok]

      resolved = resolve_dependencies(node_module, parsed[:data])
      Result.new(ok?: true, node_module: node_module, validation_errors: [], resolved_dependencies: resolved)
    rescue ImportError => e
      failure(e.message)
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

      if (cat = manifest["category"]) && !::System::NodeModuleCategory::PLATFORM_TAXONOMY.key?(cat.to_s)
        errors << "category #{cat.inspect} is not a recognized platform taxonomy slug " \
                   "(#{::System::NodeModuleCategory::PLATFORM_TAXONOMY.keys.join(', ')})"
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
      validate_no_shipped_home_paths(manifest, errors)

      errors
    end

    # Rejects file_spec entries that ship (or glob) a path under /home.
    # Home directories are runtime-managed by the agent's identity
    # reconciler (etcidentity) — anything a module ships there via its
    # rootfs/ tree lands root:root under mkfs.erofs --all-root, which is
    # always wrong (the whole point of a home dir is that it's owned by
    # the user that lives there, not by whichever module happened to
    # carve that path first).
    def validate_no_shipped_home_paths(manifest, errors)
      Array(manifest["file_spec"]).each_with_index do |entry, i|
        next unless entry.is_a?(String)
        next unless entry.match?(HOME_PATH_RX)

        errors << "file_spec[#{i}] #{entry.inspect} ships a path under /home — home directories " \
                   "are runtime-managed (owned by the agent's identity reconciler, not the module " \
                   "artifact); remove it from file_spec, or declare the account under `users:` and " \
                   "let the agent create/own its home directory instead"
      end
    end

    def home_root_allowed?(home)
      ALLOWED_HOME_ROOTS.any? do |root|
        normalized = root.end_with?("/") ? root : "#{root}/"
        home == root || home.start_with?(normalized)
      end
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

        home = entry["home"]
        if home.is_a?(String) && home.present? && !home_root_allowed?(home)
          errors << "#{prefix}.home #{home.inspect} is not under an allowed home root " \
                     "(#{ALLOWED_HOME_ROOTS.join(', ')}) — the agent's home reconciler and " \
                     "rendering hints only ever operate on these paths; pick one of them " \
                     "(e.g. \"/var/lib/#{name}\") instead of a shared system path"
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

        has_start_command = svc["start_command"].present?
        has_unit_body     = svc["unit_body"].present?
        if has_start_command && has_unit_body
          errors << "#{prefix}.start_command and #{prefix}.unit_body are mutually exclusive"
        elsif !has_start_command && !has_unit_body
          errors << "#{prefix}.start_command or #{prefix}.unit_body is required"
        elsif has_start_command && !svc["start_command"].is_a?(String)
          errors << "#{prefix}.start_command must be a string"
        elsif has_unit_body
          if !svc["unit_body"].is_a?(String)
            errors << "#{prefix}.unit_body must be a string"
          elsif !svc["unit_body"].include?("[Service]") || !svc["unit_body"].include?("WantedBy=")
            errors << "#{prefix}.unit_body must contain a [Service] section and a WantedBy= line " \
                       "(the agent's offline `systemctl enable` reads [Install]/WantedBy from the body)"
          end
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

      # Layering taxonomy (campaign 019f6084): PREFER the manifest's own
      # `category:` slug over whatever the caller pre-set on `mod` (the
      # platform seed's fallback default) — see NodeModuleCategory::
      # PLATFORM_TAXONOMY. Self-healing: creates the account's triplet for
      # this slug if the categories seed hasn't run yet (e.g. an ad hoc
      # `validate_only`/CI-publish import against a fresh account).
      # `validate` already rejected unrecognized slugs, so a lookup miss
      # here only happens if the categories seed truly hasn't run.
      if manifest.key?("category")
        resolved_category = ::System::NodeModuleCategory.for_platform_slug!(
          account: mod.account, slug: manifest["category"].to_s
        )
        mod.category = resolved_category if resolved_category
      end

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

      # Denormalize dependencies.provides[] into the queryable
      # `capabilities` JSONB column so resolve_dependencies can do
      # capability-based requires lookups without having to scan
      # every module's manifest_yaml blob. Each entry is either bare
      # `<tag>` or `<tag>@<version>`; the @<version> suffix is parsed
      # at constraint-match time by resolve_capability.
      mod.capabilities = Array(manifest.dig("dependencies", "provides")).map(&:to_s).reject(&:empty?)
    end

    # Resolve manifest.dependencies.requires to ModuleDependency rows.
    # Supports two syntaxes per entry:
    #
    #   "<gitea_full_name>@<version_constraint>" — pin to a specific module
    #     by its gitea repo (e.g., "powernode/postgres-primary@^1.0")
    #     or bare name suffix (e.g., "postgres-primary"). Resolves
    #     against NodeModule.gitea_repo_full_name OR NodeModule.name.
    #
    #   "capability:<tag>[@<constraint>]" — match the highest-priority
    #     NodeModule on this account whose capabilities array contains
    #     <tag> (with optional version satisfying <constraint>). Lets
    #     modules declare "I need database.postgres@>=16" without
    #     pinning to a specific module name; any future module that
    #     provides database.postgres@16 satisfies the requirement.
    #
    # Modules / capabilities not yet present in the platform are skipped
    # silently — the webhook ingestion path will re-resolve when the
    # providing module publishes. We log + return the unresolved set so
    # callers can surface it to the operator.
    def resolve_dependencies(mod, manifest)
      deps = manifest.dig("dependencies", "requires") || []
      return [] if deps.empty?

      resolved = []
      deps.each do |raw|
        raw_str = raw.to_s
        if raw_str.start_with?("capability:")
          resolved << resolve_capability_requirement(mod, raw_str)
        else
          resolved << resolve_name_requirement(mod, raw_str)
        end
      end
      resolved.compact
    end

    # Name-based: "<gitea_full_name>@<version>" or bare "<name>".
    def resolve_name_requirement(mod, raw_str)
      repo, constraint = raw_str.split("@", 2)
      return nil if repo.blank?

      target = ::System::NodeModule
               .where(account_id: mod.account_id)
               .where("gitea_repo_full_name = ? OR name = ?", repo, repo.split("/").last)
               .first

      if target
        upsert_dependency!(mod, target, constraint: constraint)
        { repo: repo, constraint: constraint, status: "resolved", dependency_id: target.id }
      else
        ::Rails.logger.info("[ManifestImportService] dependency #{repo.inspect} not yet known on platform; deferring")
        { repo: repo, constraint: constraint, status: "unresolved" }
      end
    end

    # Capability-based: "capability:<tag>[@<constraint>]".
    def resolve_capability_requirement(mod, raw_str)
      spec = raw_str.sub(/\Acapability:/, "")
      tag, constraint = spec.split("@", 2)
      return nil if tag.blank?

      target = resolve_capability(mod, tag, constraint)
      if target
        upsert_dependency!(mod, target, constraint: constraint, capability_tag: tag)
        { capability: tag, constraint: constraint, status: "resolved", dependency_id: target.id }
      else
        ::Rails.logger.info("[ManifestImportService] capability #{tag.inspect} (constraint=#{constraint.inspect}) not satisfied; deferring")
        { capability: tag, constraint: constraint, status: "unresolved" }
      end
    end

    # Finds the highest-priority NodeModule on the account whose
    # capabilities array contains tag (with optional version satisfying
    # constraint). Falls back to highest priority by created_at if
    # multiple candidates tie.
    #
    # Constraint matching:
    #   - blank constraint: any candidate with the bare or versioned tag matches
    #   - non-blank constraint: candidate's <tag>@<version> entry must
    #     satisfy Gem::Requirement(constraint). Bare tags (no @ver) do NOT
    #     satisfy a versioned constraint — that's a manifest-quality signal
    #     (provider should declare its version explicitly).
    # Delegates to the shared resolver. The logic lives there because
    # CapabilityGapSensor reports precisely the requirements this method
    # fails to satisfy — if the two ever disagreed, the sensor would either
    # report gaps that are not real or miss ones that are.
    def resolve_capability(mod, tag, constraint)
      ::System::CapabilityResolver.resolve(
        account_id: mod.account_id,
        tag: tag,
        constraint: constraint,
        exclude_module_id: mod.id
      )
    end

    def upsert_dependency!(mod, target, constraint: nil, capability_tag: nil)
      dep = ::System::ModuleDependency.find_or_initialize_by(node_module: mod, dependency: target)
      dep.dependency_type    = "requires"
      dep.required           = true
      dep.version_constraint = constraint if constraint.present?
      if dep.respond_to?(:metadata=) && capability_tag
        dep.metadata = (dep.metadata || {}).merge("capability_match" => capability_tag)
      end
      dep.save!
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
        record.unit_body     = svc["unit_body"]
        record.stop_command  = svc["stop_command"]
        record.restart_policy = svc.fetch("restart_policy", "always")
        # unit_body's own User= governs when the manifest leaves user:
        # unset — e.g. claude-tmux runs as pnadmin, an agent-baseline
        # identity that isn't a ServiceUser/WELL_KNOWN_SYSTEM_USERS entry
        # and can't be declared under users: without colliding UIDs.
        assign_service_user!(record, mod, svc, identity_index) unless svc["unit_body"].present? && svc["user"].blank?
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
      # Set BOTH the FK and the denormalized number so they never drift (imp
      # 019f6d9a). NodeModule#sync_current_version_number backstops this on save.
      mod.update!(current_version: version, current_version_number: version.version_number)
      version
    end
  end
end
