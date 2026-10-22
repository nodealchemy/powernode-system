# frozen_string_literal: true

module System
  module Identity
    # System::Identity::FieldGrammar — the write-time grammar for every value
    # the on-node agent concatenates into /etc/passwd, /etc/group,
    # /etc/shadow, /etc/gshadow or an /etc/sudoers.d drop-in (IMP-01a0f109).
    #
    # Those files are colon-separated and newline-terminated, and a sudoers
    # rule is a line of separators. A ':' shifts a line's fields; a newline
    # starts a NEW line — so a manifest `gecos: "x\ntoor:x:0:0::/root:/bin/bash"`
    # would become a second, uid-0 account on every node carrying the module,
    # and a sudoers command with a newline a second rule for any user. The
    # agent re-checks every field before it renders (etcidentity/validate.go,
    # etcsudoers/check.go) and skips what fails; this is the platform half, so
    # a bad manifest is refused when it is AUTHORED, with an error the author
    # can read, and never reaches a node.
    #
    # Mirrors the agent rules — keep the two in step:
    #   agent/internal/etcidentity/validate.go  (names, gecos, home, shell,
    #                                            privilegedGroups, baseline names)
    #   agent/internal/etcsudoers/check.go      (allowedTags, commandForbidden)
    module FieldGrammar
      # The agent's own baseline accounts (etcidentity.Baseline) plus the
      # well-known system users a service may run as by name
      # (ModuleService::WELL_KNOWN_SYSTEM_USERS). A module may not declare a
      # user by any of these names, nor name one as the user a sudoers grant
      # escalates.
      RESERVED_USERNAMES = (%w[root daemon bin sys sshd pnadmin nobody] +
                            ::System::ModuleService::WELL_KNOWN_SYSTEM_USERS).uniq.freeze

      # Baseline groups a module may not declare, join or add members to:
      # membership is root or root-equivalent (raw disks, kernel memory, the
      # shadow file, %sudo, other users' terminals, system logs) or belongs to
      # the platform's own accounts. Device groups (video, render, kvm, ...)
      # are deliberately absent: granting a workload GPU/KVM access is
      # legitimate. Mirrors etcidentity.privilegedGroups.
      PRIVILEGED_GROUPS = %w[
        root daemon bin sys adm tty disk kmem sudo shadow utmp
        systemd-journal pnadmin nogroup
      ].freeze

      # The built-in accounts whose home is a MANAGED home (/home/*), which the
      # agent's home reconciler chowns to whichever user declares it. A module
      # user may not claim one, nor a home inside one. Mirrors the /home/*
      # entries of etcidentity.Baseline().
      BASELINE_MANAGED_HOMES = { "/home/pnadmin" => "pnadmin" }.freeze

      GECOS_MAX = 256 # system_service_users.gecos limit
      HOME_MAX  = 256 # system_service_users.home limit
      SHELL_MAX = 128 # system_service_users.shell limit

      PATH_RX = %r{\A/[A-Za-z0-9._+@/-]*\z}

      # Sudoers Tag_Spec values a grant may carry (NOPASSWD is always added).
      SUDO_TAGS = %w[
        NOPASSWD SETENV NOSETENV EXEC NOEXEC LOG_INPUT NOLOG_INPUT
        LOG_OUTPUT NOLOG_OUTPUT MAIL NOMAIL FOLLOW NOFOLLOW INTERCEPT NOINTERCEPT
      ].freeze

      # Characters sudoers treats as structure inside a command list.
      SUDO_COMMAND_FORBIDDEN = [ ",", ":", "=", "\\" ].freeze

      # Matches C0 controls, DEL and C1 controls — newline, CR, NUL, ESC, tab...
      CONTROL_RX = /[\u0000-\u001f\u007f-\u009f]/

      module_function

      # Error (string) for a gecos-like free-text field, or nil when safe.
      def text_error(value, max: GECOS_MAX)
        return nil if value.nil?
        return "must be a string" unless value.is_a?(String)
        return "is longer than #{max} bytes" if value.bytesize > max
        return "is not valid UTF-8" unless utf8?(value)

        value = as_utf8(value)
        return "must not contain ':' (it is a field separator in /etc/passwd)" if value.include?(":")
        return "must not contain control characters such as a newline (#{control_char(value)})" if value.match?(CONTROL_RX)

        nil
      end

      # Error for a home or shell path, or nil when safe. Blank is allowed
      # (the allocator fills a default).
      def path_error(value, max:)
        return nil if value.nil? || value == ""
        return "must be a string" unless value.is_a?(String)
        return "is longer than #{max} bytes" if value.bytesize > max
        return "is not valid UTF-8" unless utf8?(value)

        value = as_utf8(value)
        return "must not contain control characters such as a newline (#{control_char(value)})" if value.match?(CONTROL_RX)
        return "must not contain ':' (it is a field separator in /etc/passwd)" if value.include?(":")
        return "must be an absolute path of [A-Za-z0-9._+@/-]" unless value.match?(PATH_RX)
        return "must not contain a '..' component" if value.split("/").include?("..")

        nil
      end

      # The cleaned path when it is a managed home (strictly under /home/), else
      # nil. Matches etcidentity.isManagedHome + filepath.Clean.
      def managed_home(path)
        return nil unless path.is_a?(String) && path.start_with?("/")

        clean = ::Pathname.new(path).cleanpath.to_s
        clean.start_with?("/home/") ? clean : nil
      end

      # The error suffix when a managed home is, or lies inside, a built-in
      # account's home; nil otherwise.
      def baseline_home_error(clean)
        BASELINE_MANAGED_HOMES.each do |home, owner|
          return "belongs to the built-in account #{owner}" if clean == home
          return "lies inside the built-in account #{owner}'s home" if clean.start_with?("#{home}/")
        end
        nil
      end

      def reserved_username?(name)
        RESERVED_USERNAMES.include?(name.to_s)
      end

      def privileged_group?(name)
        PRIVILEGED_GROUPS.include?(name.to_s)
      end

      # Error for one sudoers command, or nil when safe.
      def sudo_command_error(cmd)
        return "must be a string" unless cmd.is_a?(String)
        return "must be an absolute path (starts with /)" unless cmd.start_with?("/")
        return "is not valid UTF-8" unless utf8?(cmd)

        cmd = as_utf8(cmd)
        return "must not contain control characters such as a newline (#{control_char(cmd)})" if cmd.match?(CONTROL_RX)

        bad = SUDO_COMMAND_FORBIDDEN.find { |c| cmd.include?(c) }
        return "must not contain #{bad.inspect} (a sudoers separator)" if bad
        return "contains the literal token ALL (broad grants forbidden)" if cmd.split(/\s+/).include?("ALL")

        nil
      end

      # Error for one sudoers tag flag, or nil when allowed.
      def sudo_flag_error(flag)
        return "must be a string" unless flag.is_a?(String)
        return nil if SUDO_TAGS.include?(flag)

        "#{flag.inspect} is not an allowed sudoers tag (#{SUDO_TAGS.join(', ')})"
      end

      def utf8?(value)
        as_utf8(value).valid_encoding?
      end

      def as_utf8(value)
        value.dup.force_encoding(Encoding::UTF_8)
      end

      def control_char(value)
        value[CONTROL_RX].inspect
      end
    end
  end
end
