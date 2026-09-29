# frozen_string_literal: true

module System
  # The SERVER half of the read-only node inspection task, probe.node_inspect
  # (IMP-52762a704a3d): the fixed collector set, the argument rules, and the
  # option hash the agent receives.
  #
  # The routine sibling of system_out_of_band_exec (IMP-9ce0ed39c557), and
  # deliberately shares nothing with it. That verb runs an operator's arbitrary
  # command over ssh behind an approval and is human-only; this one runs one of
  # seven FIXED collectors on the node's own agent, takes no command, flag or
  # free-form path, and is governed auto_approve
  # (PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS["probe.node_inspect"]).
  #
  # THE AGENT IS AUTHORITATIVE. It re-validates every value in package taskguard
  # (extensions/system/agent/internal/taskguard/inspect.go) because a task row
  # can be written by anything that reaches System::Task, and it alone knows
  # what exists on the node (a unit that must exist, a path's symlink target).
  # This class refuses the same values BEFORE a row exists, and is what
  # System::Task's validation runs on a row minted any other way. The two lists
  # are kept identical by node_inspection_spec.rb, which reads the Go source.
  #
  # file_stat's PATH POLICY is an ALLOW-LIST of trees with a secret-location
  # deny inside it, not a deny-list alone. A deny-list is open by default, so
  # every secret location nobody has thought of stays readable; an allow-list is
  # closed by default and its failure mode is an operator asking for a tree to
  # be added. file_stat returns stat, sha256 and mtime and never contents, but
  # the sha256 of a low-entropy secret is an offline oracle for it, so the
  # secret locations are refused too. /proc, /sys, /dev, /root, /home, /tmp and
  # /persist/volumes are outside the allow-list, so /proc/<pid>/environ is
  # refused by omission rather than by a rule that could be edited out.
  class NodeInspection
    class Invalid < ArgumentError; end

    COMMAND = "probe.node_inspect"

    # collector => the argument keys it accepts. MUST mirror the agent's
    # nodeInspectCollectors (probe_node_inspect.go). A collector added here is a
    # new read primitive on a root agent behind an auto_approve verb: re-derive
    # the verb before shipping it.
    COLLECTORS = {
      "wg_status" => %w[interface].freeze,
      "routes" => [].freeze,
      "nft" => %w[scope].freeze,
      "journal" => %w[unit lines].freeze,
      "unit" => %w[unit].freeze,
      "caps" => %w[unit].freeze,
      "file_stat" => %w[path].freeze
    }.freeze

    # Every argument key any collector takes. A key a collector does not declare
    # is REFUSED when it carries a value, not ignored.
    ARGUMENT_KEYS = COLLECTORS.values.flatten.uniq.freeze

    NFT_SCOPES = %w[ruleset chains].freeze
    NFT_DEFAULT_SCOPE = "ruleset"

    JOURNAL_DEFAULT_LINES = 100
    JOURNAL_MAX_LINES = 500

    INTERFACE_MAX_LENGTH = 15
    # `wg show all` prints every interface (and, with dump, every key);
    # `wg show interfaces` lists them. Neither is an interface name.
    RESERVED_INTERFACES = %w[all interfaces].freeze

    UNIT_MAX_LENGTH = 255
    UNIT_SUFFIXES = %w[.service .socket .target .timer .mount .automount .path .slice .scope .swap .device].freeze

    PATH_MAX_LENGTH = 4096
    ALLOWED_PATH_PREFIXES = %w[
      /etc /usr /boot /persist/var/lib/powernode /persist/cache/modules /var/lib/powernode /run/powernode
    ].freeze
    DENIED_PATH_SEGMENTS = %w[
      pki private secrets secret keys credentials credstore vault wireguard security .ssh .gnupg
    ].freeze
    DENIED_NAME_SUBSTRINGS = %w[
      shadow opasswd priv secret token password passphrase credential htpasswd netrc pgpass
    ].freeze
    DENIED_NAME_SUFFIXES = %w[.key _key -key -key.pem _key.pem .p12 .pfx .jks .keystore .env].freeze
    DENIED_NAME_PREFIXES = %w[id_rsa id_dsa id_ecdsa id_ed25519 .env].freeze

    class << self
      # Builds the task options from a caller's params (symbol or string keys):
      # the collector's declared arguments only, validated, string-keyed, with
      # the journal line count as an Integer. Raises Invalid.
      def options_from(params)
        params = params.to_h
        fetch = ->(key) { params[key.to_sym].nil? ? params[key.to_s] : params[key.to_sym] }

        collector = fetch.call(:collector)
        check_collector!(collector)
        declared = COLLECTORS.fetch(collector)

        (ARGUMENT_KEYS - declared).each do |key|
          next if fetch.call(key).blank?

          raise Invalid, "#{key} is not accepted by the #{collector} collector"
        end

        args = declared.to_h { |key| [ key, fetch.call(key) ] }
        options = { "collector" => collector }
        declared.each do |key|
          value = args[key]
          value = normalize_lines(value) if key == "lines"
          options[key] = value unless value.nil? && optional?(key)
        end
        apply_defaults!(options)
        validate!(options)
        options
      end

      # Validates an option hash exactly as the agent will (string keys, the
      # types the agent reads). Raises Invalid.
      def validate!(options)
        raise Invalid, "options must be an object" unless options.is_a?(Hash)

        options = options.to_h.stringify_keys
        collector = options["collector"]
        check_collector!(collector)
        declared = COLLECTORS.fetch(collector)

        (options.keys - [ "collector" ] - declared).each do |key|
          raise Invalid, "#{key} is not accepted by the #{collector} collector"
        end

        declared.each do |key|
          case key
          when "interface" then check_interface!(options["interface"])
          when "unit"      then check_unit!(options["unit"])
          when "path"      then check_path!(options["path"])
          when "scope"     then check_scope!(options["scope"]) if options.key?("scope")
          when "lines"     then check_lines!(options["lines"]) if options.key?("lines")
          end
        end
        true
      end

      private

      def optional?(key)
        %w[scope lines].include?(key)
      end

      def check_collector!(collector)
        raise Invalid, "collector is required" if collector.nil? || collector == ""
        raise Invalid, "collector must be a string" unless collector.is_a?(String)
        return if COLLECTORS.key?(collector)

        raise Invalid, "collector must be one of #{COLLECTORS.keys.join(', ')}"
      end

      # A blank scope or line count means "use the default", like an absent key.
      def apply_defaults!(options)
        options["scope"] = NFT_DEFAULT_SCOPE if options["collector"] == "nft" && options["scope"].blank?
        options["lines"] = JOURNAL_DEFAULT_LINES if options["collector"] == "journal" && options["lines"].nil?
      end

      # The MCP layer may hand an integer as a string. Anything that is not a
      # plain integer is left as it is for check_lines! to refuse.
      def normalize_lines(value)
        return nil if value == ""
        return Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

        value
      end

      def check_lines!(lines)
        raise Invalid, "lines must be a whole number" unless lines.is_a?(Integer)
        return if lines.between?(1, JOURNAL_MAX_LINES)

        raise Invalid, "lines must be between 1 and #{JOURNAL_MAX_LINES}"
      end

      def check_scope!(scope)
        return if scope.is_a?(String) && NFT_SCOPES.include?(scope)

        raise Invalid, "scope must be one of #{NFT_SCOPES.join(', ')}"
      end

      def check_interface!(name)
        raise Invalid, "interface is required and must be a string" unless name.is_a?(String) && !name.empty?
        raise Invalid, "interface is longer than #{INTERFACE_MAX_LENGTH} characters" if name.length > INTERFACE_MAX_LENGTH
        raise Invalid, "interface must not begin with a dash or dot" if name.start_with?("-", ".")
        raise Invalid, "interface may contain only letters, digits, '-', '_' and '.'" unless name.match?(/\A[A-Za-z0-9_.-]+\z/)
        raise Invalid, "interface #{name.inspect} is a reserved word, not an interface name" if RESERVED_INTERFACES.include?(name.downcase)
      end

      def check_unit!(name)
        raise Invalid, "unit is required and must be a string" unless name.is_a?(String) && !name.empty?
        raise Invalid, "unit is longer than #{UNIT_MAX_LENGTH} characters" if name.length > UNIT_MAX_LENGTH
        raise Invalid, "unit must not begin with a dot or dash" if name.start_with?(".", "-")
        raise Invalid, "unit contains a character not allowed in a unit name" unless name.match?(/\A[A-Za-z0-9_.@:-]+\z/)
        return if UNIT_SUFFIXES.any? { |suffix| name.end_with?(suffix) && name.length > suffix.length }

        raise Invalid, "unit must be a full unit name ending in #{UNIT_SUFFIXES.join(', ')}"
      end

      def check_path!(path)
        raise Invalid, "path is required and must be a string" unless path.is_a?(String) && !path.empty?
        raise Invalid, "path exceeds the maximum length" if path.length > PATH_MAX_LENGTH
        raise Invalid, "path must not contain control characters" if path.match?(/[\u0000-\u001f\u007f]/)
        raise Invalid, "path must not contain a space" if path.include?(" ")
        raise Invalid, "path must be absolute" unless path.start_with?("/")

        body = path.delete_suffix("/")
        parts = body.delete_prefix("/").split("/", -1)
        if parts.any? { |part| part.empty? || part == "." || part == ".." } && body != ""
          raise Invalid, "path must be canonical (no '..', '.', or redundant separators)"
        end
        unless ALLOWED_PATH_PREFIXES.any? { |prefix| body == prefix || body.start_with?("#{prefix}/") }
          raise Invalid, "path is not under a tree file_stat may inspect (#{ALLOWED_PATH_PREFIXES.join(', ')})"
        end

        parts.each_with_index do |part, index|
          lower = part.downcase
          raise Invalid, "path is a secret location" if DENIED_PATH_SEGMENTS.include?(lower)
          raise Invalid, "path is a secret location" if index == parts.length - 1 && secret_name?(lower)
        end
      end

      def secret_name?(lower)
        DENIED_NAME_SUBSTRINGS.any? { |s| lower.include?(s) } ||
          DENIED_NAME_SUFFIXES.any? { |s| lower.end_with?(s) } ||
          DENIED_NAME_PREFIXES.any? { |s| lower.start_with?(s) }
      end
    end
  end
end
