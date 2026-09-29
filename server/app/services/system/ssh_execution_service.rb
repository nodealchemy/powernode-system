# frozen_string_literal: true

module System
  # Executes commands and file transfers on node instances via SSH/SCP.
  # Public methods return System::Runtime::Result. Internal helpers return
  # plain hashes (process-level shape: stdout/stderr/exit_code) which the
  # boundary wraps into Result.ok / Result.err based on exit status.
  class SshExecutionService
    class SshError < StandardError; end

    # F5-01 — argv safety: the ssh/scp destination is built as
    # "#{user}@#{host}"; a value with a leading '-' would be parsed by
    # ssh/scp as an OPTION (e.g. -oProxyCommand=... → command execution).
    # admin_user is operator-settable JSONB config, so both are validated
    # before any argv is built.
    SSH_USER_FORMAT = /\A[a-zA-Z0-9_][a-zA-Z0-9_.\-]*\z/
    SSH_HOST_FORMAT = /\A[a-zA-Z0-9][a-zA-Z0-9_.:\-]*\z/

    # IMP-190834701b0a — host identity verification. Every path used to
    # connect with StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null,
    # so a root command ran on whatever host answered at the recorded
    # address, and VMID/IP reuse is routine in this fleet. Now:
    #
    #   * a node WITH a recorded host key (NodeInstance#ssh_host_keys, which
    #     its agent reports on heartbeat) is always verified strictly, on
    #     every path. The verification uses a per-call 0600 known_hosts
    #     tempfile holding only that node's keys, StrictHostKeyChecking=yes,
    #     and the global known_hosts disabled. HostKeyAlias keys the entry on
    #     the INSTANCE rather than the address, so an IP change does not break
    #     the match, and a different host at the same IP cannot pass it;
    #   * out-of-band exec (#execute_bounded) REFUSES a node with no key;
    #   * the legacy callers (#execute, #scp_file, #sync) connect to a node
    #     with no key unverified, as before, with a warning and a fleet event,
    #     until REQUIRE_HOST_KEY_SETTING is turned on, after which they refuse
    #     too. See docs/design/ssh-host-key-verification.md for the migration
    #     order.
    REQUIRE_HOST_KEY_SETTING   = "system.ssh.require_host_key"
    UNVERIFIED_HOST_EVENT_KIND = "system.instance.ssh_host_unverified"
    HOST_KEY_ALIAS_PREFIX      = "powernode-node-instance-"
    # One unverified-host event per instance per window. The legacy callers
    # can run a dozen commands per operation, and the event is a coverage
    # signal, not a per-connection log.
    UNVERIFIED_EVENT_WINDOW = 1.hour

    # The pre-verification options, kept ONLY for a legacy caller reaching a
    # node that has not reported a key while REQUIRE_HOST_KEY_SETTING is off.
    UNVERIFIED_HOST_OPTIONS = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null"
    ].freeze

    # Whether legacy callers refuse a node with no recorded host key. Default
    # OFF. A read failure answers true (refuse): an unreadable setting is not
    # an operator's decision to connect unverified.
    def self.require_host_key?
      raw = ::SiteSetting.get(REQUIRE_HOST_KEY_SETTING)
      return raw if raw == true || raw == false

      %w[true 1 yes on].include?(raw.to_s.strip.downcase)
    rescue StandardError => e
      Rails.logger.error("[SshExecutionService] could not read #{REQUIRE_HOST_KEY_SETTING}: #{e.class} — refusing unverified hosts")
      true
    end

    def self.execute(instance:, command:, sudo: true, operation_id: nil)
      new.execute(instance: instance, command: command, sudo: sudo, operation_id: operation_id)
    end

    def self.sync(instance:)
      new.sync(instance: instance)
    end

    # IMP-9ce0ed39c557 — the opt-in bounded runner for out-of-band exec (see
    # #execute_bounded below). Same key/host validation as #execute, but
    # never used by any of that method's ~40 in-process callers.
    def self.execute_bounded(instance:, command:, sudo: true, timeout_seconds:, max_output_bytes:)
      new.execute_bounded(instance: instance, command: command, sudo: sudo,
                          timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes)
    end

    # Copy a local file to a remote instance via SCP.
    # Mirrors the same auth + key-file + Open3 mechanism as #execute, so the
    # behavior under SYSTEM_SSH_ENABLED=false is identical (mock fallback).
    def self.scp_file(instance:, local_path:, remote_path:, mode: nil, recursive: false)
      new.scp_file(
        instance: instance,
        local_path: local_path,
        remote_path: remote_path,
        mode: mode,
        recursive: recursive
      )
    end

    def execute(instance:, command:, sudo: true, operation_id: nil)
      validate_instance!(instance)

      ssh_ip = instance.ssh_ip_address
      admin_user = instance.admin_user || "pnadmin"
      ssh_key = get_ssh_key(instance)

      return Runtime::Result.err(error: "No SSH IP address available", data: { exit_code: -1 }) unless ssh_ip.present?
      return Runtime::Result.err(error: "No SSH key available", data: { exit_code: -1 }) unless ssh_key.present?
      if (endpoint_err = endpoint_error(admin_user, ssh_ip))
        return Runtime::Result.err(error: endpoint_err, data: { exit_code: -1 })
      end
      host_keys, host_key_err = host_key_policy(instance, always_require: false)
      return Runtime::Result.err(error: host_key_err, data: { exit_code: -1 }) if host_key_err

      full_command = sudo ? "sudo #{command}" : command

      Rails.logger.info(
        "[SshExecutionService] Executing command on #{instance.name}: " \
        "#{ShellOutputSanitizer.redact(command[0..100])}..."
      )

      raw = execute_ssh_command(host: ssh_ip, user: admin_user, key: ssh_key, command: full_command,
                                host_keys: host_keys, host_alias: host_key_alias(instance))

      build_exec_result(raw)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[SshExecutionService] SSH execution failed: #{ShellOutputSanitizer.redact(e.message)}")
      Runtime::Result.err(error: e.message, data: { exit_code: -1 })
    end

    # IMP-9ce0ed39c557 — the OPT-IN bounded runner for out-of-band exec.
    # Every existing caller of #execute (~40 in-process services) is
    # untouched: this is a separate method with no shared call graph, so
    # nothing already in production gains a timeout or an output cap it
    # never asked for. Only System::OutOfBandExecService calls this.
    #
    # Shares #execute's host/key resolution and argv-injection guards
    # (F5-01) — those protect the destination, not the command, and apply
    # identically here. What differs: the actual ssh invocation is bounded
    # by System::BoundedCommandRunner (a deadline + a per-stream output cap)
    # instead of Open3.capture3, and two more OpenSSH options are set:
    # BatchMode=yes (never prompt — a hung passphrase/host-key prompt would
    # otherwise sit past the timeout without ssh itself ever giving up) and
    # ServerAliveInterval (so a black-holed connection is detected and torn
    # down by ssh's own keepalive rather than relying solely on the outer
    # deadline to kill it).
    def execute_bounded(instance:, command:, sudo: true, timeout_seconds:, max_output_bytes:)
      validate_instance!(instance)

      ssh_ip = instance.ssh_ip_address
      admin_user = instance.admin_user || "pnadmin"
      ssh_key = get_ssh_key(instance)

      return Runtime::Result.err(error: "No SSH IP address available", data: { exit_code: -1 }) unless ssh_ip.present?
      return Runtime::Result.err(error: "No SSH key available", data: { exit_code: -1 }) unless ssh_key.present?
      if (endpoint_err = endpoint_error(admin_user, ssh_ip))
        return Runtime::Result.err(error: endpoint_err, data: { exit_code: -1 })
      end
      # Out-of-band exec never connects to a host it cannot verify, whatever
      # REQUIRE_HOST_KEY_SETTING says (System::OutOfBandExecService refuses
      # the same case earlier, before anything is parked for approval).
      host_keys, host_key_err = host_key_policy(instance, always_require: true)
      return Runtime::Result.err(error: host_key_err, data: { exit_code: -1 }) if host_key_err

      # The command text is NEVER logged here (review finding — the previous
      # version logged a redacted/truncated preview of it, which still
      # contradicts this class's and the design doc's "never logs the
      # command" claim for the out-of-band-exec path specifically: that
      # claim has to hold for every sink, not just the audit rows). What
      # gets run is under System::OutOfBandExecService's own STARTED/FINISHED
      # AuditLog rows instead — this line only records that a call happened,
      # against which instance, under what bounds.
      Rails.logger.info(
        "[SshExecutionService] Executing bounded command on instance #{instance.id} " \
        "(timeout=#{timeout_seconds}s, cap=#{max_output_bytes}B)"
      )

      # `command` and `sudo` are passed through RAW (not pre-joined into one
      # string here, unlike #execute) — #execute_ssh_command_bounded builds
      # the remote `timeout -k` wrapper around `command` FIRST and applies
      # `sudo` around the whole thing, so the ordering is `sudo timeout -k 5
      # N sh -c '<command>'`: timeout runs AS ROOT and supervises a root
      # shell, rather than sudo wrapping an already-bounded (but unrooted)
      # timeout invocation.
      raw = execute_ssh_command_bounded(
        host: ssh_ip, user: admin_user, key: ssh_key, command: command, sudo: sudo,
        timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes,
        host_keys: host_keys, host_alias: host_key_alias(instance)
      )

      Rails.logger.info(
        "[SshExecutionService] Bounded command on instance #{instance.id} finished " \
        "exit_code=#{raw[:exit_code].inspect} timed_out=#{raw[:timed_out]} truncated=#{raw[:truncated]}"
      )

      build_bounded_result(raw)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[SshExecutionService] Bounded SSH execution failed: #{ShellOutputSanitizer.redact(e.message)}")
      Runtime::Result.err(error: e.message, data: { exit_code: -1, timed_out: false, truncated: false })
    end

    def sync(instance:)
      validate_instance!(instance)

      platform = instance.node&.node_template&.node_platform
      return Runtime::Result.ok(data: { message: "No sync script configured" }) unless platform&.sync_script.present?

      execute(instance: instance, command: "ipn sync", sudo: true)
    end

    def scp_file(instance:, local_path:, remote_path:, mode: nil, recursive: false)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Local file not found: #{local_path}", data: { exit_code: -1 }) unless File.exist?(local_path)

      ssh_ip = instance.ssh_ip_address
      admin_user = instance.admin_user || "pnadmin"
      ssh_key = get_ssh_key(instance)

      return Runtime::Result.err(error: "No SSH IP address available", data: { exit_code: -1 }) unless ssh_ip.present?
      return Runtime::Result.err(error: "No SSH key available", data: { exit_code: -1 }) unless ssh_key.present?
      if (endpoint_err = endpoint_error(admin_user, ssh_ip))
        return Runtime::Result.err(error: endpoint_err, data: { exit_code: -1 })
      end
      host_keys, host_key_err = host_key_policy(instance, always_require: false)
      return Runtime::Result.err(error: host_key_err, data: { exit_code: -1 }) if host_key_err

      Rails.logger.info("[SshExecutionService] SCP #{local_path} -> #{admin_user}@#{ssh_ip}:#{remote_path}")

      raw = execute_scp_command(
        host: ssh_ip,
        user: admin_user,
        key: ssh_key,
        local_path: local_path,
        remote_path: remote_path,
        recursive: recursive,
        host_keys: host_keys,
        host_alias: host_key_alias(instance)
      )

      # Optional chmod after a successful transfer. Done as a separate exec
      # because scp doesn't accept a mode flag uniformly across BSD/OpenSSH.
      if mode && raw[:exit_code] == 0
        execute(instance: instance, command: "chmod #{mode} #{remote_path}", sudo: true)
      end

      build_exec_result(raw)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[SshExecutionService] SCP failed: #{ShellOutputSanitizer.redact(e.message)}")
      Runtime::Result.err(error: e.message, data: { exit_code: -1 })
    end

    private

    def build_exec_result(raw)
      data = { stdout: raw[:stdout], stderr: raw[:stderr], exit_code: raw[:exit_code] }
      if raw[:exit_code] == 0
        Runtime::Result.ok(data: data)
      else
        Runtime::Result.err(error: "Command exited with status #{raw[:exit_code]}", data: data)
      end
    end

    # `truncated` never affects success/failure on its own — the command may
    # have completed and exited 0 with more output than the cap allows, and
    # that is still a successful run whose output was clipped, not a failed
    # one. `timed_out` always means failure: the caller's exit_code is nil
    # (the process was killed, not "finished with a code"), so there is no
    # exit status to report success from.
    # stdout/stderr are redacted (ShellOutputSanitizer, the same scrubber
    # every other log line in this class already uses) before they leave
    # this method — the caller-supplied command can print anything,
    # including material that looks like a credential, and this is the one
    # place both bounded streams converge regardless of caller (audit, REST,
    # MCP all read this same Result).
    #
    # NOTE the deviation from that class's own header ("primarily a LOGGING
    # redactor, not a content rewriter... a caller that hands the sanitized
    # text back to a machine consumer parsing the original output would
    # silently corrupt it"): out-of-band exec is explicitly a HUMAN
    # diagnostic surface, not a machine-parsed API response, and review
    # direction was to prefer redacted-but-safe content over byte-perfect
    # fidelity here. A future caller that needs the unredacted bytes for
    # machine parsing must not reuse this method's output for that purpose.
    def build_bounded_result(raw)
      data = {
        stdout: ShellOutputSanitizer.redact(raw[:stdout].to_s),
        stderr: ShellOutputSanitizer.redact(raw[:stderr].to_s),
        exit_code: raw[:exit_code],
        timed_out: raw[:timed_out], truncated: raw[:truncated]
      }
      if raw[:timed_out]
        Runtime::Result.err(error: "Command timed out", data: data)
      elsif raw[:exit_code] == 0
        Runtime::Result.ok(data: data)
      else
        Runtime::Result.err(error: "Command exited with status #{raw[:exit_code]}", data: data)
      end
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    # F5-01 argv-injection guard — returns an error message or nil.
    def endpoint_error(user, host)
      return "SSH user #{user.inspect} is not a valid username" unless user.to_s.match?(SSH_USER_FORMAT)
      return "SSH host #{host.inspect} is not a valid host" unless host.to_s.match?(SSH_HOST_FORMAT)

      nil
    end

    # Returns [host_keys, nil] to connect (host_keys nil = unverified legacy
    # connection) or [nil, message] to refuse. See REQUIRE_HOST_KEY_SETTING.
    def host_key_policy(instance, always_require:)
      host_keys = ::System::SshHostKeys.recorded_for(instance)
      return [ host_keys, nil ] if host_keys.any?

      if always_require
        return [ nil, no_host_key_message(instance, "out-of-band exec never connects to an unverified host") ]
      end
      if self.class.require_host_key?
        return [ nil, no_host_key_message(instance, "#{REQUIRE_HOST_KEY_SETTING} is on") ]
      end

      note_unverified_host(instance)
      [ nil, nil ]
    end

    def no_host_key_message(instance, why)
      "No SSH host key recorded for instance #{instance.id} — refusing to connect, because the " \
        "host's identity cannot be verified (#{why}). The node's agent reports its host key on " \
        "heartbeat; confirm the agent is current and heartbeating, then retry."
    end

    def note_unverified_host(instance)
      Rails.logger.warn(
        "[SshExecutionService] No SSH host key recorded for instance #{instance.id} — connecting " \
        "WITHOUT host verification (#{REQUIRE_HOST_KEY_SETTING} is off)"
      )
      return unless Rails.cache.write("system:ssh_host_unverified:#{instance.id}", true,
                                      unless_exist: true, expires_in: UNVERIFIED_EVENT_WINDOW)

      ::System::Fleet::EventBroadcaster.emit!(
        account: instance.account,
        kind: UNVERIFIED_HOST_EVENT_KIND,
        severity: :medium,
        payload: { instance_id: instance.id, require_host_key: false },
        source: "system/ssh_execution_service",
        node_instance_id: instance.id
      )
    rescue StandardError => e
      Rails.logger.warn("[SshExecutionService] unverified-host event failed for #{instance.id}: #{e.class}")
    end

    def host_key_alias(instance)
      "#{HOST_KEY_ALIAS_PREFIX}#{instance.id}"
    end

    # Yields the host-verification ssh/scp options. With recorded keys, it
    # writes them to a per-call 0600 known_hosts tempfile, removed in ensure
    # whether the call succeeds or raises. CheckHostIP=no and
    # UpdateHostKeys=no keep ssh from adding its own entries to that file.
    # With no keys (the legacy, setting-off case only), it yields the old
    # unverified options.
    def with_host_verification(host_keys, host_alias)
      return yield(UNVERIFIED_HOST_OPTIONS.dup) if host_keys.blank?

      known_hosts = Tempfile.new([ "known_hosts", "" ])
      begin
        File.chmod(0o600, known_hosts.path)
        known_hosts.write(::System::SshHostKeys.known_hosts(host_alias, host_keys))
        known_hosts.close
        yield [
          "-o", "StrictHostKeyChecking=yes",
          "-o", "UserKnownHostsFile=#{known_hosts.path}",
          "-o", "GlobalKnownHostsFile=/dev/null",
          "-o", "HostKeyAlias=#{host_alias}",
          "-o", "CheckHostIP=no",
          "-o", "UpdateHostKeys=no"
        ]
      ensure
        known_hosts.close!
      end
    end

    def get_ssh_key(instance)
      return instance.key if instance.key.present?
      instance.node&.ssh_key
    end

    def execute_ssh_command(host:, user:, key:, command:, host_keys: nil, host_alias: nil)
      unless ssh_available?
        Rails.logger.warn("[SshExecutionService] SSH not available - returning mock response")
        return mock_ssh_response(command)
      end

      require "open3"
      require "tempfile"

      key_file = Tempfile.new([ "ssh_key", ".pem" ])
      begin
        key_file.write(key)
        key_file.close
        File.chmod(0o600, key_file.path)

        with_host_verification(host_keys, host_alias) do |host_options|
          ssh_options = [
            *host_options,
            "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=30",
            "-i", key_file.path
          ]

          ssh_command = [ "ssh", *ssh_options, "#{user}@#{host}", command ]

          stdout, stderr, status = Open3.capture3(*ssh_command)
          { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
        end
      ensure
        key_file.unlink
      end
    end

    # Remote-side deadline (review finding): the LOCAL kill in
    # BoundedCommandRunner only ever bounds the `ssh` client on THIS host.
    # Without a pty, sshd sends the remote command no signal at all when the
    # client disconnects/dies — a plain `ssh host 'sudo <command>'` whose
    # local ssh is killed leaves that `sudo <command>` running as root on the
    # node indefinitely. Wrapping the remote command in GNU coreutils
    # `timeout -k 5 <N>` makes the REMOTE side enforce its own bound,
    # independent of what happens to the local ssh client: `timeout` starts
    # the wrapped command in its own process group and kills that whole
    # group on expiry (`-k 5` gives it 5s after the initial TERM before
    # escalating to KILL) — this is the AUTHORITATIVE bound; the local
    # BoundedCommandRunner kill is a second, LOCAL-only layer, not a
    # substitute for it. `sh -c` + Shellwords.escape wraps the whole command
    # (which may itself contain shell operators — `&&`, pipes, redirects) as
    # ONE argument, so `timeout` supervises the entire thing rather than
    # racing only its first word. `sudo` wraps the outside: `sudo timeout -k
    # 5 N sh -c '<command>'` runs `timeout` itself as root, which is what
    # lets it signal a root-owned command's process group.
    def execute_ssh_command_bounded(host:, user:, key:, command:, sudo:, timeout_seconds:, max_output_bytes:,
                                    host_keys:, host_alias:)
      unless ssh_available?
        Rails.logger.warn("[SshExecutionService] SSH not available - returning mock bounded response")
        return mock_ssh_response(command).merge(timed_out: false, truncated: false)
      end

      require "tempfile"
      require "shellwords"

      key_file = Tempfile.new([ "ssh_key", ".pem" ])
      begin
        key_file.write(key)
        key_file.close
        File.chmod(0o600, key_file.path)

        with_host_verification(host_keys, host_alias) do |host_options|
          ssh_options = [
            *host_options,
            "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=30",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=10",
            "-i", key_file.path
          ]

          bounded_command = "timeout -k 5 #{timeout_seconds.to_i} sh -c #{Shellwords.escape(command)}"
          remote_command = sudo ? "sudo #{bounded_command}" : bounded_command

          ssh_command = [ "ssh", *ssh_options, "#{user}@#{host}", remote_command ]

          result = ::System::BoundedCommandRunner.run(
            ssh_command, timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes
          )
          { stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code,
            timed_out: result.timed_out?, truncated: result.truncated? }
        end
      ensure
        key_file.unlink
      end
    end

    # Public class-level form (review finding S6) — lets a caller check
    # BEFORE invoking #execute_bounded whether this would take the mock path
    # at all, rather than discovering it after the fact from the shape of the
    # response. OutOfBandExecService uses this to refuse outright rather than
    # audit a mocked run as if it were a real one: unlike #execute's ~40
    # in-process callers (routine housekeeping, where a test-env mock is a
    # harmless convenience), out-of-band-exec's entire point is proof a
    # specific command really ran, so a silent mock success there is actively
    # misleading, not merely inert.
    def self.ssh_enabled?
      ENV["SYSTEM_SSH_ENABLED"] != "false"
    end

    # Returns true when real SSH execution is enabled. Default is on; set
    # SYSTEM_SSH_ENABLED=false to disable. Outside the test environment we
    # treat the disabled state as a misconfiguration rather than silently
    # mocking — see #mock_ssh_response.
    def ssh_available?
      self.class.ssh_enabled?
    end

    # In test env (CI/RSpec), returning a synthetic exit_code: 0 lets specs
    # exercise SSH-dependent code paths without needing real keys/network.
    # In any other env, silently mocking would mask real misconfigurations
    # — a deploy that thinks it's "succeeded" while no commands ever ran.
    # We raise loudly instead so the operator sees the cause.
    def mock_ssh_response(command)
      unless Rails.env.test?
        Rails.logger.error(
          "[SshExecutionService] SSH disabled outside test env — refusing to mock. Set SYSTEM_SSH_ENABLED=true or unset it to enable."
        )
        raise SshError, "SSH is disabled (SYSTEM_SSH_ENABLED=false) outside the test environment"
      end

      Rails.logger.info("[SshExecutionService] Mock SSH execution: #{ShellOutputSanitizer.redact(command)}")
      { stdout: "Mock execution of: #{command}", stderr: "", exit_code: 0 }
    end

    def execute_scp_command(host:, user:, key:, local_path:, remote_path:, recursive:, host_keys: nil, host_alias: nil)
      unless ssh_available?
        Rails.logger.warn("[SshExecutionService] SSH not available - returning mock SCP response")
        return mock_ssh_response("scp #{local_path} -> #{user}@#{host}:#{remote_path}")
      end

      require "open3"
      require "tempfile"

      key_file = Tempfile.new([ "ssh_key", ".pem" ])
      begin
        key_file.write(key)
        key_file.close
        File.chmod(0o600, key_file.path)

        with_host_verification(host_keys, host_alias) do |host_options|
          scp_options = [
            *host_options,
            "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=30",
            "-i", key_file.path
          ]
          scp_options << "-r" if recursive

          scp_command = [ "scp", *scp_options, local_path, "#{user}@#{host}:#{remote_path}" ]
          stdout, stderr, status = Open3.capture3(*scp_command)

          { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
        end
      ensure
        key_file.unlink
      end
    end
  end
end
