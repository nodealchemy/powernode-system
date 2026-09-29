# frozen_string_literal: true

module System
  # IMP-9951cbf20bb0 — the ONE author of what system_apply_unit_dropin may write
  # on a node, and of the unit.dropin task and its audit row.
  #
  # The write is a runtime systemd drop-in,
  # /run/systemd/system/<unit>.d/zz-operator-<name>.conf: /run is tmpfs, so a
  # reboot reverts it, and the zz- prefix sorts it after every drop-in a module
  # ships. A revert removes that one file and nothing else. Neither restarts the
  # unit; a caller who wants the change live restarts it with
  # system_restart_unit, a separate governed act.
  #
  # WHICH units: exactly the ones system_restart_unit may restart.
  # System::UnitRestartService#target_refusal is called, not copied, so the two
  # verbs cannot drift apart on the agent's unit, the node-scoped INV-1 fence or
  # the silent-agent check.
  #
  # WHAT may be written: a fixed allow-list of directives, each with a strict
  # value grammar, rendered here under a single [Service] header from validated
  # pairs. A drop-in line is a directive, so one newline in a value would make
  # this verb exec by another name (ExecStartPre=...); control characters,
  # backslashes (a trailing one continues the line), brackets (a section
  # header), double quotes and %-specifiers are refused in every key and value
  # before any grammar is consulted. The agent's UnitDropinHandler validates
  # every field again, independently; the shared table in
  # agent/internal/runtime/tasks/handlers/testdata/unit_dropin_cases.json holds
  # both sides to the same answers.
  #
  # A refusal is a MESSAGE (nil means "would proceed"), like
  # System::UnitRestartService#refusal, so the gate context can ask without
  # writing.
  class UnitDropinService
    class Refused < StandardError; end
    class Invalid < StandardError; end

    COMMAND = "unit.dropin"
    ACTION_CATEGORY = "system.instance.unit_dropin"
    AUDIT_ACTION = "system.instance.unit_dropin"
    AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze

    # The noun System::UnitRestartService#target_refusal puts in its messages.
    ACT = "drop-in override"

    DROPIN_ROOT = "/run/systemd/system"
    FILE_PREFIX = "zz-operator-"
    NAME_SHAPE = /\A[a-z0-9-]{1,32}\z/

    TASK_OPTION_KEYS = %w[unit name revert directives].freeze

    MAX_DIRECTIVES = 32
    MAX_KEY_LENGTH = 64
    MAX_VALUE_LENGTH = 1024
    MAX_PATHS = 16

    ALLOWED_DIRECTIVES = %w[
      Environment MemoryMax CPUQuota TasksMax LimitNOFILE
      AmbientCapabilities CapabilityBoundingSet ReadWritePaths
    ].freeze

    # Rendered as "reset, then the list": a capability line in a drop-in is
    # UNIONED with the unit's own, so without the reset a drop-in could only
    # widen. An empty value renders the reset alone, i.e. no capabilities —
    # the zero-caps trial.
    CAPABILITY_DIRECTIVES = %w[AmbientCapabilities CapabilityBoundingSet].freeze

    # The only directives whose grammar admits a "%" (a trailing percentage).
    # Everywhere else a "%" is a systemd specifier and is refused.
    PERCENT_DIRECTIVES = %w[MemoryMax CPUQuota TasksMax].freeze

    VALUE_GRAMMARS = {
      "MemoryMax" => /\A(?:infinity|[1-9][0-9]{0,14}[KMGT]?|(?:[1-9][0-9]?|100)%)\z/,
      "CPUQuota" => /\A[1-9][0-9]{0,4}%\z/,
      "TasksMax" => /\A(?:infinity|[1-9][0-9]{0,6}|(?:[1-9][0-9]?|100)%)\z/
    }.freeze
    LIMIT_PART = /\A(?:infinity|[1-9][0-9]{0,9})\z/

    ENV_NAME = /\A[A-Z][A-Z0-9_]{0,127}\z/

    # ReadWritePaths only ever relaxes a unit's sandbox, so it may name a path
    # strictly BENEATH one of these and nothing else.
    READ_WRITE_ROOTS = %w[/persist /run/powernode].freeze
    PATH_SHAPE = %r{\A(?:/[A-Za-z0-9._-]+)+\z}

    # Why a directive off the allow-list is refused, for the ones a caller is
    # most likely to try. Everything else gets the allow-list itself.
    REFUSAL_REASONS = [
      [ /\AExec/, "runs a command" ],
      [ /\A(?:User|Group|DynamicUser|SupplementaryGroups)\z/, "changes the identity the unit runs as" ],
      [ /\A(?:NoNewPrivileges|PermissionsStartOnly|SecureBits|RestrictSUIDSGID|RemoveIPC|KeyringMode)\z/,
        "relaxes the unit's privilege controls" ],
      [ /(?:File|Credential|Credentials|Directory)\z|\A(?:LoadCredential|SetCredential|ImportCredential|BindPaths|BindReadOnlyPaths)/,
        "references a file" ]
    ].freeze

    MASK = ::Ai::SensitiveParams::MASK

    class << self
      # nil when the name is acceptable; else the refusal.
      def name_refusal(name)
        return nil if name.is_a?(String) && name.match?(NAME_SHAPE)

        "name must match #{NAME_SHAPE.source} (1 to 32 lowercase letters, digits or dashes): it becomes " \
          "#{FILE_PREFIX}<name>.conf, the only file this verb writes or removes"
      end

      def dropin_path(unit, name)
        ::File.join(DROPIN_ROOT, "#{unit}.d", "#{FILE_PREFIX}#{name}.conf")
      end

      # Validates caller-supplied directives, an Array of { key:, value: }, and
      # returns them as [key, value] String pairs in the caller's order. Raises
      # Invalid naming the entry. An Environment VALUE is never echoed.
      def normalize_directives(directives)
        raise Invalid, "directives must be a list of { key, value } entries" unless directives.is_a?(Array)
        raise Invalid, "directives must not be empty: name at least one directive, or revert" if directives.empty?
        if directives.size > MAX_DIRECTIVES
          raise Invalid, "directives may hold at most #{MAX_DIRECTIVES} entries (got #{directives.size})"
        end

        seen_keys = {}
        seen_env = {}
        directives.each_with_index.map do |entry, index|
          key, value = entry_pair(entry, index)
          check_characters!(key, value, index)
          check_key!(key, index)
          if key == "Environment"
            check_environment!(value, index, seen_env)
          else
            raise Invalid, "directives[#{index}]: #{key} is given more than once" if seen_keys[key]

            seen_keys[key] = true
            check_value!(key, value, index)
          end
          [ key, value ]
        end
      end

      # The exact file the agent writes (its renderDropin must agree byte for
      # byte; the shared table pins it).
      def render(name, pairs)
        header(name) + pairs.flat_map { |key, value| lines_for(key, value) }.join
      end

      # The same file with every Environment VALUE masked, for the audit row.
      def masked_render(name, pairs)
        render(name, pairs.map { |key, value| key == "Environment" ? [ key, "#{value.split('=', 2).first}=#{MASK}" ] : [ key, value ] })
      end

      # The model's re-check (System::Task#unit_dropin_governed): the options a
      # unit.dropin row may carry, whoever minted it. Raises Invalid.
      def validate_task_options!(options)
        raise Invalid, "options must be an object" unless options.is_a?(Hash)

        opts = options.stringify_keys
        extra = opts.keys - TASK_OPTION_KEYS
        raise Invalid, "options #{extra.inspect} are not accepted" if extra.any?

        missing = TASK_OPTION_KEYS - opts.keys
        raise Invalid, "options #{missing.inspect} are required" if missing.any?

        raise Invalid, "revert must be true or false" unless [ true, false ].include?(opts["revert"])
        if (message = name_refusal(opts["name"]))
          raise Invalid, message
        end

        unit = opts["unit"]
        unless unit.is_a?(String) && unit.match?(::System::UnitRestartService::MANAGED_UNIT_SHAPE) &&
               !unit.downcase.start_with?(::System::UnitRestartService::AGENT_UNIT_PREFIX)
          raise Invalid, "unit must be a managed powernode-<module-id>-<service>.service that is not the agent's"
        end

        if opts["revert"]
          raise Invalid, "a revert takes no directives" unless opts["directives"] == []
        else
          normalize_directives(opts["directives"])
        end
        true
      end

      private

      def header(name)
        "# Managed by Powernode: operator drop-in \"#{name}\" (system_apply_unit_dropin).\n" \
          "# Runtime only: /run is tmpfs, so a reboot removes this file.\n" \
          "[Service]\n"
      end

      def lines_for(key, value)
        return [ "Environment=\"#{value}\"\n" ] if key == "Environment"
        return [ "#{key}=\n" ] + (value.empty? ? [] : [ "#{key}=#{value}\n" ]) if CAPABILITY_DIRECTIVES.include?(key)

        [ "#{key}=#{value}\n" ]
      end

      def entry_pair(entry, index)
        raise Invalid, "directives[#{index}] must be an object with key and value" unless entry.is_a?(Hash)

        entry = entry.to_h.transform_keys(&:to_s)
        extra = entry.keys - %w[key value]
        raise Invalid, "directives[#{index}] accepts only key and value (got #{extra.inspect})" if extra.any?

        key = entry["key"]
        value = entry["value"]
        raise Invalid, "directives[#{index}].key must be a string" unless key.is_a?(String)
        raise Invalid, "directives[#{index}].value must be a string" unless value.is_a?(String)
        raise Invalid, "directives[#{index}].key is too long" if key.length > MAX_KEY_LENGTH
        raise Invalid, "directives[#{index}].value is too long (at most #{MAX_VALUE_LENGTH})" if value.length > MAX_VALUE_LENGTH

        [ key, value ]
      end

      # The rule that keeps one value one line. Checked on the key AND the value
      # before anything else looks at either.
      def check_characters!(key, value, index)
        { "key" => key, "value" => value }.each do |field, text|
          problem = unsafe_character(text)
          raise Invalid, "directives[#{index}].#{field} contains #{problem}" if problem
        end
        return unless value.include?("%") && !PERCENT_DIRECTIVES.include?(key)

        raise Invalid, "directives[#{index}].value contains '%': systemd expands %-specifiers in #{key}"
      end

      def unsafe_character(text)
        return "invalid UTF-8" unless text.valid_encoding?

        text.each_char do |c|
          o = c.ord
          return "a control character (a line break or NUL would start another directive)" if o < 0x20 || o == 0x7f
          return "a non-ASCII character" if o > 0x7e
          return "a backslash (a trailing one continues the line into the next)" if c == "\\"
          return "'#{c}' (a section header would start another section)" if c == "[" || c == "]"
          return "a double quote" if c == '"'
        end
        nil
      end

      def check_key!(key, index)
        return if ALLOWED_DIRECTIVES.include?(key)

        reason = REFUSAL_REASONS.find { |pattern, _| key.match?(pattern) }&.last
        reason = "is not on the allow-list (#{ALLOWED_DIRECTIVES.join(', ')})" if reason.nil?
        reason = "is refused: it #{reason}" unless reason.start_with?("is not")
        raise Invalid, "directives[#{index}]: #{key.inspect} #{reason}"
      end

      def check_environment!(value, index, seen)
        name, separator, rest = value.partition("=")
        unless separator == "=" && name.match?(ENV_NAME)
          raise Invalid, "directives[#{index}]: Environment must be NAME=value with NAME matching #{ENV_NAME.source}"
        end
        raise Invalid, "directives[#{index}]: Environment #{name} is given more than once" if seen[name]

        seen[name] = true
        return unless ::System::ShellOutputSanitizer.secret_shaped?(value) ||
                      ::System::ShellOutputSanitizer.secret_shaped?(rest)

        raise Invalid, "directives[#{index}]: Environment #{name} looks like a secret and is refused " \
                       "(a drop-in under /run is world-readable, and its value would sit in the task row)"
      end

      def check_value!(key, value, index)
        ok =
          case key
          when "LimitNOFILE" then limit_ok?(value)
          when *CAPABILITY_DIRECTIVES then capabilities_ok?(value)
          when "ReadWritePaths" then paths_ok?(value)
          else value.match?(VALUE_GRAMMARS.fetch(key))
          end
        return if ok

        raise Invalid, "directives[#{index}]: #{key}=#{value.inspect} is refused: #{grammar_hint(key)}"
      end

      def limit_ok?(value)
        parts = value.split(":", -1)
        return false unless parts.size.between?(1, 2) && parts.all? { |p| p.match?(LIMIT_PART) }
        return true if parts.size == 1

        soft, hard = parts
        return hard == "infinity" if soft == "infinity"
        return true if hard == "infinity"

        soft.to_i <= hard.to_i
      end

      def capabilities_ok?(value)
        return true if value.empty?

        names = value.split(/ /, -1)
        names.all? { |n| ::System::ModuleConfigValidator::KNOWN_CAPABILITIES.include?(n) } && names.uniq.size == names.size
      end

      def paths_ok?(value)
        paths = value.split(/ /, -1)
        return false if paths.empty? || paths.size > MAX_PATHS

        paths.all? do |path|
          path.match?(PATH_SHAPE) &&
            path.split("/").none? { |segment| %w[. ..].include?(segment) } &&
            READ_WRITE_ROOTS.any? { |root| path.start_with?("#{root}/") }
        end
      end

      def grammar_hint(key)
        case key
        when "MemoryMax" then "a byte count with an optional K/M/G/T suffix, 1% to 100%, or infinity"
        when "CPUQuota" then "a whole percentage, 1% or more"
        when "TasksMax" then "a positive count, 1% to 100%, or infinity"
        when "LimitNOFILE" then "N or SOFT:HARD (positive, SOFT <= HARD) or infinity"
        when *CAPABILITY_DIRECTIVES then "space-separated CAP_* names from the known list, each once (empty means none)"
        when "ReadWritePaths" then "space-separated absolute, clean paths strictly beneath #{READ_WRITE_ROOTS.join(' or ')}"
        end
      end
    end

    # nil when the drop-in (or its revert) would proceed; else the refusal text,
    # authored for the caller. Read-only.
    def refusal(instance:, unit:, name:, directives:, revert:)
      self.class.name_refusal(name) || directives_refusal(directives, revert) ||
        ::System::UnitRestartService.new.target_refusal(instance: instance, unit: unit, act: ACT)
    end

    # Re-checks, then creates the task and its audit row in ONE transaction: a
    # drop-in whose audit cannot be written is never queued. Returns the task.
    def apply!(instance:, unit:, name:, directives:, revert:, initiated_by: nil, agent_id: nil,
               deferred_operation_id: nil, call_origin: nil)
      unit = unit.to_s.strip
      message = refusal(instance: instance, unit: unit, name: name, directives: directives, revert: revert)
      raise Refused, message if message

      pairs = revert ? [] : self.class.normalize_directives(directives)
      path = self.class.dropin_path(unit, name)

      ::ActiveRecord::Base.transaction do
        task = ::System::Task.new(
          account: instance.account, operable: instance, command: COMMAND, status: "pending",
          initiated_by: initiated_by,
          description: revert ? "revert drop-in #{FILE_PREFIX}#{name}.conf on #{unit}" : "drop-in #{FILE_PREFIX}#{name}.conf on #{unit}",
          options: {
            "unit" => unit, "name" => name, "revert" => revert,
            "directives" => pairs.map { |key, value| { "key" => key, "value" => value } }
          }
        )
        task.governed_unit_dropin = true
        task.save!
        write_audit!(instance: instance, unit: unit, name: name, path: path, revert: revert,
                     diff: audit_diff(path, name, pairs, revert), task: task, initiated_by: initiated_by,
                     agent_id: agent_id, deferred_operation_id: deferred_operation_id, call_origin: call_origin)
        task
      end
    end

    private

    def directives_refusal(directives, revert)
      unless [ true, false ].include?(revert)
        return "revert must be true or false"
      end
      if revert
        return nil if directives.nil? || directives == []

        return "a revert takes no directives: it removes #{FILE_PREFIX}<name>.conf and nothing else"
      end

      self.class.normalize_directives(directives)
      nil
    rescue Invalid => e
      e.message
    end

    # The control plane cannot see the node's current file, so the "before"
    # side is labelled as untracked rather than guessed at. Environment values
    # are masked; keys stay readable.
    def audit_diff(path, name, pairs, revert)
      if revert
        return "--- #{path}\n+++ /dev/null (removed by revert)\n"
      end

      body = self.class.masked_render(name, pairs).lines.map { |line| "+#{line}" }.join
      "--- #{path} (before: not tracked by the control plane)\n+++ #{path}\n#{body}"
    end

    def write_audit!(instance:, unit:, name:, path:, revert:, diff:, task:, initiated_by:, agent_id:,
                     deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: instance.account,
        user: initiated_by,
        action: AUDIT_ACTION,
        resource_type: "System::NodeInstance",
        resource_id: instance.id.to_s,
        source: "system",
        metadata: {
          unit: unit, name: name, path: path, revert: revert, diff: diff, task_id: task.id,
          agent_id: agent_id, deferred_operation_id: deferred_operation_id, call_origin: call_origin
        }.compact
      )
    end
  end
end
