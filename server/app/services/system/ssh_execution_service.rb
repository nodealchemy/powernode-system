# frozen_string_literal: true

module System
  # Executes commands and file transfers on node instances via SSH/SCP.
  # Public methods return System::Runtime::Result. Internal helpers return
  # plain hashes (process-level shape: stdout/stderr/exit_code) which the
  # boundary wraps into Result.ok / Result.err based on exit status.
  class SshExecutionService
    class SshError < StandardError; end

    def self.execute(instance:, command:, sudo: true, operation_id: nil)
      new.execute(instance: instance, command: command, sudo: sudo, operation_id: operation_id)
    end

    def self.sync(instance:)
      new.sync(instance: instance)
    end

    def self.cleanse(instance:)
      new.cleanse(instance: instance)
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
      admin_user = instance.admin_user || "root"
      ssh_key = get_ssh_key(instance)

      return Runtime::Result.err(error: "No SSH IP address available", data: { exit_code: -1 }) unless ssh_ip.present?
      return Runtime::Result.err(error: "No SSH key available", data: { exit_code: -1 }) unless ssh_key.present?

      full_command = sudo ? "sudo #{command}" : command

      Rails.logger.info("[SshExecutionService] Executing command on #{instance.name}: #{command[0..100]}...")

      raw = execute_ssh_command(host: ssh_ip, user: admin_user, key: ssh_key, command: full_command)

      build_exec_result(raw)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[SshExecutionService] SSH execution failed: #{e.message}")
      Runtime::Result.err(error: e.message, data: { exit_code: -1 })
    end

    def sync(instance:)
      validate_instance!(instance)

      platform = instance.node&.node_template&.node_platform
      return Runtime::Result.ok(data: { message: "No sync script configured" }) unless platform&.sync_script.present?

      execute(instance: instance, command: "ipn sync", sudo: true)
    end

    def cleanse(instance:)
      validate_instance!(instance)
      execute(instance: instance, command: "ipn cleanse", sudo: true)
    end

    def scp_file(instance:, local_path:, remote_path:, mode: nil, recursive: false)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Local file not found: #{local_path}", data: { exit_code: -1 }) unless File.exist?(local_path)

      ssh_ip = instance.ssh_ip_address
      admin_user = instance.admin_user || "root"
      ssh_key = get_ssh_key(instance)

      return Runtime::Result.err(error: "No SSH IP address available", data: { exit_code: -1 }) unless ssh_ip.present?
      return Runtime::Result.err(error: "No SSH key available", data: { exit_code: -1 }) unless ssh_key.present?

      Rails.logger.info("[SshExecutionService] SCP #{local_path} -> #{admin_user}@#{ssh_ip}:#{remote_path}")

      raw = execute_scp_command(
        host: ssh_ip,
        user: admin_user,
        key: ssh_key,
        local_path: local_path,
        remote_path: remote_path,
        recursive: recursive
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
      Rails.logger.error("[SshExecutionService] SCP failed: #{e.message}")
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

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def get_ssh_key(instance)
      return instance.key if instance.key.present?
      instance.node&.ssh_key
    end

    def execute_ssh_command(host:, user:, key:, command:)
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

        ssh_options = [
          "-o", "StrictHostKeyChecking=no",
          "-o", "UserKnownHostsFile=/dev/null",
          "-o", "PasswordAuthentication=no",
          "-o", "ConnectTimeout=30",
          "-i", key_file.path
        ]

        ssh_command = [ "ssh", *ssh_options, "#{user}@#{host}", command ]

        stdout, stderr, status = Open3.capture3(*ssh_command)
        { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
      ensure
        key_file.unlink
      end
    end

    # Returns true when real SSH execution is enabled. Default is on; set
    # SYSTEM_SSH_ENABLED=false to disable. Outside the test environment we
    # treat the disabled state as a misconfiguration rather than silently
    # mocking — see #mock_ssh_response.
    def ssh_available?
      ENV["SYSTEM_SSH_ENABLED"] != "false"
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

      Rails.logger.info("[SshExecutionService] Mock SSH execution: #{command}")
      { stdout: "Mock execution of: #{command}", stderr: "", exit_code: 0 }
    end

    def execute_scp_command(host:, user:, key:, local_path:, remote_path:, recursive:)
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

        scp_options = [
          "-o", "StrictHostKeyChecking=no",
          "-o", "UserKnownHostsFile=/dev/null",
          "-o", "PasswordAuthentication=no",
          "-o", "ConnectTimeout=30",
          "-i", key_file.path
        ]
        scp_options << "-r" if recursive

        scp_command = [ "scp", *scp_options, local_path, "#{user}@#{host}:#{remote_path}" ]
        stdout, stderr, status = Open3.capture3(*scp_command)

        { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
      ensure
        key_file.unlink
      end
    end
  end
end
