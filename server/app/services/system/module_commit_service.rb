# frozen_string_literal: true

require "open3"
require "fileutils"
require "shellwords"

module System
  # Commits (deploys) node modules to instances by staging files locally,
  # transferring them via SCP, then running install/configure/activate
  # scripts. Public methods return System::Runtime::Result. Internal
  # stage_* helpers stay hash-shaped to track per-stage timing/diagnostics.
  class ModuleCommitService
    class CommitError < StandardError; end
    class TransferError < StandardError; end

    COMMIT_STAGES = %w[prepare transfer install configure activate].freeze

    def self.commit(node_module:, instance:, options: {})
      new.commit(node_module: node_module, instance: instance, options: options)
    end

    def self.commit_to_node(node_module:, node:, options: {})
      new.commit_to_node(node_module: node_module, node: node, options: options)
    end

    def commit(node_module:, instance:, options: {})
      validate_module!(node_module)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Module is disabled") unless node_module.enabled?
      return Runtime::Result.err(error: "Instance is not running") unless instance.active?

      Rails.logger.info("[ModuleCommitService] Committing #{node_module.name} to #{instance.name}")

      commit_id = generate_commit_id
      staging_dir = prepare_staging_directory(node_module, instance, commit_id)

      begin
        results = {}

        COMMIT_STAGES.each do |stage|
          Rails.logger.info("[ModuleCommitService] Stage: #{stage}")
          result = send("stage_#{stage}", node_module, instance, staging_dir, options)

          unless result[:success]
            rollback_commit(node_module, instance, staging_dir, stage, results)
            return Runtime::Result.err(
              error: "Commit failed at #{stage}: #{result[:error]}",
              data: { stage: stage, results: results }
            )
          end

          results[stage] = result
        end

        record_commit(node_module, instance, commit_id, results)
        cleanup_staging(staging_dir)

        Runtime::Result.ok(data: {
          commit_id: commit_id,
          duration: calculate_duration(results),
          stages: results
        })
      rescue ArgumentError
        cleanup_staging(staging_dir)
        raise
      rescue StandardError => e
        Rails.logger.error("[ModuleCommitService] Commit failed: #{e.message}")
        cleanup_staging(staging_dir)
        Runtime::Result.err(error: e.message)
      end
    end

    def commit_to_node(node_module:, node:, options: {})
      validate_module!(node_module)
      validate_node!(node)

      instances = node.node_instances.where(status: "running")

      return Runtime::Result.err(error: "No running instances for node") if instances.empty?

      Rails.logger.info("[ModuleCommitService] Committing #{node_module.name} to #{instances.count} instances")

      results = []
      all_success = true

      instances.find_each do |instance|
        result = commit(node_module: node_module, instance: instance, options: options)
        results << {
          instance_id: instance.id,
          instance_name: instance.name,
          success: result.success?,
          data: result.data,
          error: result.error
        }
        all_success = false unless result.success?
      end

      data = {
        results: results,
        total: instances.count,
        succeeded: results.count { |r| r[:success] },
        failed: results.count { |r| !r[:success] }
      }
      all_success ? Runtime::Result.ok(data: data) : Runtime::Result.err(error: "#{data[:failed]} instance(s) failed", data: data)
    end

    private

    def validate_module!(node_module)
      raise ArgumentError, "Module required" unless node_module
      raise ArgumentError, "Module must be a System::NodeModule" unless node_module.is_a?(::System::NodeModule)
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_node!(node)
      raise ArgumentError, "Node required" unless node
      raise ArgumentError, "Node must be a System::Node" unless node.is_a?(::System::Node)
    end

    def generate_commit_id
      "commit-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}"
    end

    def prepare_staging_directory(node_module, _instance, commit_id)
      dir = File.join(Rails.root, "tmp", "commits", commit_id)
      FileUtils.mkdir_p(dir)
      FileUtils.mkdir_p(File.join(dir, "files"))
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      dir
    end

    def cleanup_staging(staging_dir)
      FileUtils.rm_rf(staging_dir) if staging_dir && File.exist?(staging_dir)
    rescue StandardError => e
      Rails.logger.warn("[ModuleCommitService] Cleanup failed: #{e.message}")
    end

    # Stage: Prepare - Set up files for transfer
    #
    # Module data extraction is deferred — see the equivalent comment in
    # ModuleBuildService#stage_prepare. Until NodeModule gains a
    # data_file_object_id FK to FileManagement::Object, deployment relies on
    # node_module_copy_paths plus generated install/configure scripts;
    # there is no module-level tarball to extract here.
    def stage_prepare(node_module, _instance, staging_dir, _options)
      Rails.logger.info("[ModuleCommitService] Preparing commit files")

      start_time = Time.current

      copy_paths = node_module.node_module_copy_paths.to_a
      Rails.logger.info("[ModuleCommitService] Processing #{copy_paths.count} copy paths")

      scripts = generate_install_scripts(node_module, staging_dir)

      {
        success: true,
        duration: Time.current - start_time,
        files_count: copy_paths.count,
        scripts: scripts
      }
    end

    # Stage: Transfer - Copy files to instance via SCP.
    # Pack the entire staging directory into one tarball, scp it once, then
    # untar on the instance. Single-tarball transfer is dramatically faster
    # than per-file scp for typical config modules with many small files,
    # and avoids partial-state issues if the connection drops mid-transfer.
    def stage_transfer(_node_module, instance, staging_dir, _options)
      Rails.logger.info("[ModuleCommitService] Transferring files to instance")

      start_time = Time.current
      ssh_ip = instance.ssh_ip_address

      return { success: false, error: "No SSH IP address available" } unless ssh_ip.present?
      return { success: false, error: "tar binary not found on platform host" } unless tar_available?

      remote_staging = "/tmp/module-staging"
      local_tarball = File.join(File.dirname(staging_dir), "#{File.basename(staging_dir)}-transfer.tar.gz")

      begin
        _pack_stdout, pack_stderr, pack_status = Open3.capture3("tar", "-czf", local_tarball, "-C", staging_dir, ".")
        return { success: false, error: "Failed to pack staging tarball: #{pack_stderr.strip}" } unless pack_status.success?

        prep = SshExecutionService.execute(
          instance: instance,
          command: "rm -rf #{remote_staging} && mkdir -p #{remote_staging}",
          sudo: true
        )
        unless prep.success?
          return { success: false, error: "Failed to prepare #{remote_staging}: #{prep.data[:stderr] || prep.error}" }
        end

        remote_tarball = "#{remote_staging}/_transfer.tar.gz"
        transfer = SshExecutionService.scp_file(
          instance: instance,
          local_path: local_tarball,
          remote_path: remote_tarball
        )
        unless transfer.success?
          return {
            success: false,
            error: "SCP transfer failed (exit #{transfer.data[:exit_code]}): #{transfer.data[:stderr] || transfer.error}"
          }
        end

        extract = SshExecutionService.execute(
          instance: instance,
          command: "tar -xzf #{remote_tarball} -C #{remote_staging} && rm #{remote_tarball}",
          sudo: true
        )
        unless extract.success?
          return { success: false, error: "Remote untar failed: #{extract.data[:stderr] || extract.error}" }
        end

        {
          success: true,
          duration: Time.current - start_time,
          destination: remote_staging,
          tarball_size: File.size(local_tarball)
        }
      ensure
        File.delete(local_tarball) if local_tarball && File.exist?(local_tarball)
      end
    end

    def tar_available?
      system("which", "tar", out: File::NULL, err: File::NULL)
    end

    # Stage: Install - Run installation commands
    def stage_install(node_module, instance, _staging_dir, _options)
      Rails.logger.info("[ModuleCommitService] Installing module on instance")

      start_time = Time.current

      node_module.node_module_copy_paths.each do |copy_path|
        copy_result = execute_copy_path(instance, copy_path)
        unless copy_result.success?
          return { success: false, error: "Failed to copy #{copy_path.source_path}: #{copy_result.error}" }
        end
      end

      if node_module.file_spec&.dig("install_script").present?
        result = SshExecutionService.execute(
          instance: instance,
          command: "/tmp/module-staging/install.sh",
          sudo: true
        )

        return { success: false, error: "Install script failed: #{result.error}" } unless result.success?
      end

      { success: true, duration: Time.current - start_time }
    end

    # Stage: Configure - Apply configuration
    def stage_configure(node_module, instance, _staging_dir, _options)
      Rails.logger.info("[ModuleCommitService] Configuring module")

      start_time = Time.current
      mask_summary = nil

      if node_module.mask.present?
        mask_summary = apply_mask_configuration(node_module, instance)
        if mask_summary[:errors].any?
          details = mask_summary[:errors].map { |e| "#{e[:path]} (#{e[:error]})" }.join("; ")
          return {
            success: false,
            error: "Mask apply failed for #{mask_summary[:errors].size} file(s): #{details}"
          }
        end
      end

      if node_module.file_spec&.dig("config_script").present?
        result = SshExecutionService.execute(
          instance: instance,
          command: "/tmp/module-staging/configure.sh",
          sudo: true
        )

        return { success: false, error: "Config script failed: #{result.error}" } unless result.success?
      end

      {
        success: true,
        duration: Time.current - start_time,
        mask_files_applied: mask_summary&.dig(:masked)&.size.to_i
      }
    end

    # Stage: Activate - Enable and start services
    def stage_activate(node_module, instance, _staging_dir, options)
      Rails.logger.info("[ModuleCommitService] Activating module")

      start_time = Time.current

      if options[:reload_systemd] || node_module.file_spec&.dig("systemd_units").present?
        result = SshExecutionService.execute(instance: instance, command: "systemctl daemon-reload", sudo: true)
        Rails.logger.info("[ModuleCommitService] Systemd reload: #{result.success?}")
      end

      services = node_module.file_spec&.dig("services") || []
      services.each do |service|
        result = SshExecutionService.execute(
          instance: instance,
          command: "systemctl enable --now #{service}",
          sudo: true
        )
        Rails.logger.warn("[ModuleCommitService] Failed to start service #{service}") unless result.success?
      end

      SshExecutionService.execute(instance: instance, command: "rm -rf /tmp/module-staging", sudo: true)

      { success: true, duration: Time.current - start_time, services_activated: services }
    end

    def rollback_commit(node_module, instance, staging_dir, failed_stage, results)
      Rails.logger.info("[ModuleCommitService] Rolling back commit at stage #{failed_stage}")

      completed_stages = COMMIT_STAGES.take_while { |s| s != failed_stage }

      completed_stages.reverse_each do |stage|
        rollback_stage(stage, node_module, instance, staging_dir, results[stage])
      end
    end

    def rollback_stage(stage, node_module, instance, _staging_dir, _stage_result)
      case stage
      when "activate"
        services = node_module.file_spec&.dig("services") || []
        services.each do |service|
          SshExecutionService.execute(instance: instance, command: "systemctl stop #{service}", sudo: true)
        end
      when "install"
        node_module.node_module_copy_paths.each do |copy_path|
          SshExecutionService.execute(
            instance: instance,
            command: "rm -rf #{copy_path.destination_path}",
            sudo: true
          )
        end
      end
    rescue StandardError => e
      Rails.logger.error("[ModuleCommitService] Rollback failed for #{stage}: #{e.message}")
    end

    def execute_copy_path(instance, copy_path)
      cmd = if copy_path.recursive?
              "cp -r /tmp/module-staging/#{copy_path.source_path} #{copy_path.destination_path}"
            else
              "cp /tmp/module-staging/#{copy_path.source_path} #{copy_path.destination_path}"
            end

      dest_dir = File.dirname(copy_path.destination_path)
      SshExecutionService.execute(instance: instance, command: "mkdir -p #{dest_dir}", sudo: true)

      SshExecutionService.execute(instance: instance, command: cmd, sudo: true)
    end

    # Apply per-file template substitutions over SSH using sed.
    #
    # Mask shape: { file_path => { "KEY" => "VALUE", ... } }
    # Each KEY is treated as a {{KEY}} placeholder embedded in the target
    # file. We build one `sed -i -e ... -e ...` invocation per file so a
    # bad pattern fails the file, not the whole stage.
    def apply_mask_configuration(node_module, instance)
      mask = node_module.mask
      return { masked: [], errors: [] } if mask.blank?

      masked = []
      errors = []

      mask.each do |file_path, values|
        next unless values.is_a?(Hash) && values.any?

        # Build sed -e clauses; each replaces {{KEY}} → escaped VALUE globally.
        # Delimiter `|` is uncommon in config values and avoids the clash with
        # paths that `/` would create.
        sed_args = values.flat_map do |key, value|
          ["-e", "s|{{#{sed_escape_search(key.to_s)}}}|#{sed_escape_replacement(value.to_s)}|g"]
        end

        # Shellwords.escape every arg so the remote shell can't reinterpret
        # special characters embedded in operator-supplied values.
        cmd = (
          ["sed", "-i"] + sed_args + [file_path]
        ).map { |a| Shellwords.escape(a) }.join(" ")

        result = ::System::SshExecutionService.execute(instance: instance, command: cmd, sudo: true)
        if result.success?
          masked << file_path
          Rails.logger.info("[ModuleCommitService] Mask applied to #{file_path} (#{values.size} substitution(s))")
        else
          stderr = result.respond_to?(:data) ? result.data&.dig(:stderr) : nil
          errors << { path: file_path, error: stderr.presence || result.error }
          Rails.logger.warn("[ModuleCommitService] Mask apply failed for #{file_path}: #{errors.last[:error]}")
        end
      end

      { masked: masked, errors: errors }
    end

    # Escape regex metacharacters in the search side of sed `s|...|...|`.
    # Sed treats `{` `}` `(` `)` `|` `?` `+` literally in BRE — only `.` `*`
    # `[` `]` `^` `$` `\` and the chosen delimiter need escaping.
    def sed_escape_search(pattern)
      pattern.gsub(/([.\*\[\]\^\$\\\|])/) { "\\#{Regexp.last_match(1)}" }
    end

    # Escape sed's replacement-side specials. Order matters: backslash first,
    # then the delimiter, then `&` (which sed expands to the matched substring).
    # Block-form gsub is critical here — Ruby would otherwise interpret `\\`
    # in the replacement string as a back-reference.
    def sed_escape_replacement(value)
      value
        .gsub("\\") { "\\\\" }
        .gsub("|")  { "\\|" }
        .gsub("&")  { "\\&" }
        .gsub("\n") { "\\n" }
    end

    def generate_install_scripts(node_module, staging_dir)
      scripts = []
      scripts_dir = File.join(staging_dir, "scripts")

      install_script = generate_install_script(node_module)
      install_path = File.join(scripts_dir, "install.sh")
      File.write(install_path, install_script)
      File.chmod(0o755, install_path)
      scripts << install_path

      if node_module.mask.present?
        config_script = generate_config_script(node_module)
        config_path = File.join(scripts_dir, "configure.sh")
        File.write(config_path, config_script)
        File.chmod(0o755, config_path)
        scripts << config_path
      end

      scripts
    end

    def generate_install_script(node_module)
      <<~BASH
        #!/bin/bash
        set -e

        echo "Installing module: #{node_module.name}"
        echo "Priority: #{node_module.priority}"

        # Module-specific installation logic would go here
        # Based on file_spec configuration

        echo "Installation complete"
      BASH
    end

    def generate_config_script(node_module)
      <<~BASH
        #!/bin/bash
        set -e

        echo "Configuring module: #{node_module.name}"

        # Apply mask configurations
        # Template substitution logic would go here

        echo "Configuration complete"
      BASH
    end

    def record_commit(node_module, instance, commit_id, _results)
      assignment = ::System::NodeModuleAssignment.find_or_create_by!(
        node: instance.node,
        node_module: node_module
      )

      config = assignment.config || {}
      config["last_commit"] = {
        "commit_id" => commit_id,
        "instance_id" => instance.id,
        "committed_at" => Time.current.iso8601,
        "success" => true
      }

      assignment.update!(config: config)
    end

    def calculate_duration(results)
      results.values.sum { |r| r[:duration] || 0 }
    end
  end
end
