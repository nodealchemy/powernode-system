# frozen_string_literal: true

module System
  # Performs instance-level maintenance (health/disk/memory/process/network/
  # service checks). Public methods return System::Runtime::Result. Internal
  # task_* helpers stay hash-shaped to carry rich diagnostic data.
  class InstanceMaintenanceService
    class MaintenanceError < StandardError; end

    MAINTENANCE_TASKS = %w[
      health_check
      disk_cleanup
      memory_check
      process_audit
      network_check
      service_status
    ].freeze

    def self.run_maintenance(instance:, tasks: nil, options: {})
      new.run_maintenance(instance: instance, tasks: tasks, options: options)
    end

    def run_maintenance(instance:, tasks: nil, options: {})
      validate_instance!(instance)

      return Runtime::Result.err(error: "Instance is not running") unless instance.active?

      tasks ||= MAINTENANCE_TASKS
      tasks = Array(tasks) & MAINTENANCE_TASKS

      Rails.logger.info("[InstanceMaintenanceService] Running maintenance on #{instance.name}: #{tasks.join(', ')}")

      results = {}
      all_success = true

      tasks.each do |task|
        Rails.logger.info("[InstanceMaintenanceService] Task: #{task}")
        result = send("task_#{task}", instance, options)
        results[task] = result
        all_success = false unless result[:success]
      end

      update_maintenance_record(instance, results)

      data = {
        results: results,
        tasks_run: tasks.count,
        tasks_succeeded: results.count { |_, r| r[:success] },
        tasks_failed: results.count { |_, r| !r[:success] }
      }
      all_success ? Runtime::Result.ok(data: data) : Runtime::Result.err(error: "#{data[:tasks_failed]} task(s) failed", data: data)
    end

    private

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    # Task: Health Check - Comprehensive instance health verification
    def task_health_check(instance, _options)
      Rails.logger.info("[InstanceMaintenanceService] Running health check for #{instance.name}")

      start_time = Time.current
      checks = {}
      issues = []

      ssh_check = check_ssh_connectivity(instance)
      checks[:ssh] = ssh_check[:success]
      issues << "SSH connectivity failed" unless ssh_check[:success]

      return { success: false, error: "Cannot connect to instance", checks: checks } unless ssh_check[:success]

      uptime = get_system_uptime(instance)
      checks[:uptime] = uptime[:success]
      checks[:uptime_seconds] = uptime[:seconds] if uptime[:success]

      load = get_load_average(instance)
      checks[:load] = load[:success]
      if load[:success]
        checks[:load_1m] = load[:load_1m]
        checks[:load_5m] = load[:load_5m]
        checks[:load_15m] = load[:load_15m]

        issues << "High load average: #{load[:load_1m]}" if load[:load_1m] > (get_cpu_count(instance) * 2)
      end

      disk = check_disk_space(instance)
      checks[:disk] = disk[:success]
      if disk[:success] && disk[:partitions]
        critical_partitions = disk[:partitions].select { |p| p[:used_percent] > 90 }
        if critical_partitions.any?
          issues << "Disk space critical: #{critical_partitions.map { |p| "#{p[:mount]} (#{p[:used_percent]}%)" }.join(', ')}"
        end
      end

      memory = check_memory_usage(instance)
      checks[:memory] = memory[:success]
      if memory[:success]
        checks[:memory_used_percent] = memory[:used_percent]
        issues << "Memory usage critical: #{memory[:used_percent]}%" if memory[:used_percent] > 90
      end

      { success: issues.empty?, duration: Time.current - start_time, checks: checks, issues: issues }
    end

    # Task: Disk Cleanup - Free up disk space
    def task_disk_cleanup(instance, options)
      Rails.logger.info("[InstanceMaintenanceService] Running disk cleanup for #{instance.name}")

      start_time = Time.current
      actions = []

      cache_result = ssh_run(instance, cleanup_package_cache_command, sudo: true)
      actions << "Cleaned package cache" if cache_result.success?

      if options[:clean_logs]
        log_result = ssh_run(
          instance,
          "find /var/log -type f -name '*.gz' -mtime +#{options[:log_retention_days] || 30} -delete",
          sudo: true
        )
        actions << "Cleaned old log files" if log_result.success?
      end

      tmp_result = ssh_run(instance, "find /tmp -type f -atime +7 -delete 2>/dev/null || true", sudo: true)
      actions << "Cleaned temp files" if tmp_result.success?

      if options[:clean_old_kernels]
        kernel_result = ssh_run(instance, clean_old_kernels_command, sudo: true)
        actions << "Cleaned old kernels" if kernel_result.success?
      end

      after = check_disk_space(instance)

      {
        success: true,
        duration: Time.current - start_time,
        actions: actions,
        disk_after: after[:partitions]
      }
    end

    # Task: Memory Check - Detailed memory analysis
    def task_memory_check(instance, _options)
      Rails.logger.info("[InstanceMaintenanceService] Running memory check for #{instance.name}")

      start_time = Time.current

      mem_result = ssh_run(instance, "free -m", sudo: false)
      return { success: false, error: "Failed to get memory info" } unless mem_result.success?

      memory_info = parse_free_output(mem_result.data[:stdout])

      swap_result = ssh_run(instance, "cat /proc/swaps", sudo: false)
      swap_info = parse_swap_info(swap_result.data[:stdout]) if swap_result.success?

      top_result = ssh_run(instance, "ps aux --sort=-%mem | head -11", sudo: false)
      top_processes = parse_top_processes(top_result.data[:stdout]) if top_result.success?

      oom_result = ssh_run(instance, "dmesg | grep -i 'out of memory' | tail -5", sudo: true)
      oom_events = oom_result.data[:stdout]&.lines&.count || 0

      recommendations = []
      recommendations << "Consider adding more memory" if memory_info[:used_percent] > 80
      recommendations << "High swap usage - may indicate memory pressure" if swap_info && swap_info[:used_percent] > 50
      recommendations << "OOM killer has been active - review memory allocation" if oom_events > 0

      {
        success: true,
        duration: Time.current - start_time,
        memory: memory_info,
        swap: swap_info,
        top_processes: top_processes&.first(5),
        oom_events: oom_events,
        recommendations: recommendations
      }
    end

    # Task: Process Audit - Check running processes
    def task_process_audit(instance, _options)
      Rails.logger.info("[InstanceMaintenanceService] Running process audit for #{instance.name}")

      start_time = Time.current

      ps_result = ssh_run(instance, "ps aux | wc -l", sudo: false)
      process_count = ps_result.data[:stdout]&.strip&.to_i || 0

      zombie_result = ssh_run(instance, "ps aux | grep -w Z | grep -v grep | wc -l", sudo: false)
      zombie_count = zombie_result.data[:stdout]&.strip&.to_i || 0

      defunct_result = ssh_run(instance, "ps aux | grep defunct | grep -v grep", sudo: false)
      defunct_processes = defunct_result.data[:stdout]&.lines&.map(&:strip) || []

      long_running_result = ssh_run(instance, "ps -eo pid,etime,cmd --sort=-etime | head -11", sudo: false)
      long_running = parse_long_running_processes(long_running_result.data[:stdout]) if long_running_result.success?

      high_cpu_result = ssh_run(instance, "ps aux --sort=-%cpu | head -6", sudo: false)
      high_cpu = parse_top_processes(high_cpu_result.data[:stdout]) if high_cpu_result.success?

      issues = []
      issues << "#{zombie_count} zombie processes detected" if zombie_count > 0
      issues << "#{defunct_processes.count} defunct processes" if defunct_processes.any?

      {
        success: issues.empty?,
        duration: Time.current - start_time,
        process_count: process_count,
        zombie_count: zombie_count,
        defunct_processes: defunct_processes,
        long_running: long_running&.first(5),
        high_cpu_processes: high_cpu&.first(5),
        issues: issues
      }
    end

    # Task: Network Check - Verify network connectivity
    def task_network_check(instance, _options)
      Rails.logger.info("[InstanceMaintenanceService] Running network check for #{instance.name}")

      start_time = Time.current
      checks = {}

      dns_result = ssh_run(instance, "host google.com 2>&1 || nslookup google.com 2>&1", sudo: false)
      checks[:dns] = dns_result.success? && !dns_result.data[:stdout].include?("not found")

      ping_result = ssh_run(instance, "ping -c 3 8.8.8.8 2>&1 || true", sudo: false)
      checks[:internet] = ping_result.data[:stdout]&.include?("bytes from")

      interfaces_result = ssh_run(instance, "ip -o addr show | awk '{print $2, $4}'", sudo: false)
      checks[:interfaces] = parse_interfaces(interfaces_result.data[:stdout]) if interfaces_result.success?

      connections_result = ssh_run(instance, "ss -tuln | wc -l", sudo: false)
      checks[:listening_ports] = connections_result.data[:stdout]&.strip&.to_i || 0

      established_result = ssh_run(instance, "ss -tun state established | wc -l", sudo: false)
      checks[:established_connections] = established_result.data[:stdout]&.strip&.to_i || 0

      issues = []
      issues << "DNS resolution failed" unless checks[:dns]
      issues << "No internet connectivity" unless checks[:internet]

      { success: issues.empty?, duration: Time.current - start_time, checks: checks, issues: issues }
    end

    # Task: Service Status - Check critical services
    def task_service_status(instance, options)
      Rails.logger.info("[InstanceMaintenanceService] Checking service status for #{instance.name}")

      start_time = Time.current

      services_to_check = options[:services] || %w[sshd cron]

      node = instance.node
      if node
        node.node_module_assignments.includes(node_module: :node_module_copy_paths).each do |assignment|
          mod = assignment.node_module
          if mod.file_spec.is_a?(Hash) && mod.file_spec["services"]
            services_to_check += mod.file_spec["services"]
          end
        end
      end

      services_to_check.uniq!

      service_statuses = {}
      failed_services = []

      services_to_check.each do |service|
        result = ssh_run(
          instance,
          "systemctl is-active #{service} 2>/dev/null || service #{service} status 2>/dev/null",
          sudo: true
        )

        status = if result.data[:stdout]&.strip == "active"
                   "running"
                 elsif result.success?
                   "running"
                 else
                   "stopped"
                 end

        service_statuses[service] = status
        failed_services << service if status == "stopped"
      end

      restarted = []
      if options[:auto_restart] && failed_services.any?
        failed_services.each do |service|
          result = ssh_run(
            instance,
            "systemctl start #{service} 2>/dev/null || service #{service} start 2>/dev/null",
            sudo: true
          )
          restarted << service if result.success?
        end
      end

      {
        success: failed_services.empty? || restarted.count == failed_services.count,
        duration: Time.current - start_time,
        services: service_statuses,
        failed: failed_services,
        restarted: restarted
      }
    end

    # ---- Helper methods (hash-shaped, internal-only) ----

    def ssh_run(instance, command, sudo:)
      SshExecutionService.execute(instance: instance, command: command, sudo: sudo)
    end

    def check_ssh_connectivity(instance)
      result = ssh_run(instance, "echo connected", sudo: false)
      { success: result.success? && result.data[:stdout]&.include?("connected") }
    end

    def get_system_uptime(instance)
      result = ssh_run(instance, "cat /proc/uptime | awk '{print $1}'", sudo: false)
      return { success: false } unless result.success?
      { success: true, seconds: result.data[:stdout].strip.to_f }
    end

    def get_load_average(instance)
      result = ssh_run(instance, "cat /proc/loadavg", sudo: false)
      return { success: false } unless result.success?

      parts = result.data[:stdout].strip.split
      {
        success: true,
        load_1m: parts[0].to_f,
        load_5m: parts[1].to_f,
        load_15m: parts[2].to_f
      }
    end

    def get_cpu_count(instance)
      result = ssh_run(instance, "nproc", sudo: false)
      result.data[:stdout]&.strip&.to_i || 1
    end

    def check_disk_space(instance)
      result = ssh_run(instance, "df -h --output=target,size,used,avail,pcent", sudo: false)
      return { success: false } unless result.success?
      { success: true, partitions: parse_df_output(result.data[:stdout]) }
    end

    def check_memory_usage(instance)
      result = ssh_run(instance, "free -m | grep Mem | awk '{print $2, $3, $4}'", sudo: false)
      return { success: false } unless result.success?

      parts = result.data[:stdout].strip.split
      total = parts[0].to_i
      used = parts[1].to_i
      {
        success: true,
        total_mb: total,
        used_mb: used,
        free_mb: parts[2].to_i,
        used_percent: total > 0 ? ((used.to_f / total) * 100).round(1) : 0
      }
    end

    def parse_df_output(output)
      return [] unless output

      output.lines.drop(1).map do |line|
        parts = line.strip.split
        next if parts.length < 5

        {
          mount: parts[0],
          size: parts[1],
          used: parts[2],
          available: parts[3],
          used_percent: parts[4].to_i
        }
      end.compact
    end

    def parse_free_output(output)
      return {} unless output

      mem_line = output.lines.find { |l| l.start_with?("Mem:") }
      return {} unless mem_line

      parts = mem_line.split
      total = parts[1].to_i
      used = parts[2].to_i

      {
        total_mb: total,
        used_mb: used,
        free_mb: parts[3].to_i,
        shared_mb: parts[4].to_i,
        buff_cache_mb: parts[5].to_i,
        available_mb: parts[6].to_i,
        used_percent: total > 0 ? ((used.to_f / total) * 100).round(1) : 0
      }
    end

    def parse_swap_info(output)
      return nil unless output

      lines = output.lines.drop(1)
      return nil if lines.empty?

      parts = lines.first.split
      return nil if parts.length < 4

      size = parts[2].to_i
      used = parts[3].to_i

      {
        device: parts[0],
        type: parts[1],
        size_kb: size,
        used_kb: used,
        used_percent: size > 0 ? ((used.to_f / size) * 100).round(1) : 0
      }
    end

    def parse_top_processes(output)
      return [] unless output

      output.lines.drop(1).map do |line|
        parts = line.split
        next if parts.length < 11

        {
          user: parts[0],
          pid: parts[1].to_i,
          cpu_percent: parts[2].to_f,
          mem_percent: parts[3].to_f,
          command: parts[10..-1].join(" ")
        }
      end.compact
    end

    def parse_long_running_processes(output)
      return [] unless output

      output.lines.drop(1).map do |line|
        parts = line.split
        next if parts.length < 3

        { pid: parts[0].to_i, elapsed: parts[1], command: parts[2..-1].join(" ") }
      end.compact
    end

    def parse_interfaces(output)
      return [] unless output

      output.lines.map do |line|
        parts = line.strip.split
        next if parts.length < 2
        { interface: parts[0], address: parts[1] }
      end.compact
    end

    def cleanup_package_cache_command
      "apt-get clean 2>/dev/null || yum clean all 2>/dev/null || dnf clean all 2>/dev/null || true"
    end

    def clean_old_kernels_command
      "apt-get autoremove -y 2>/dev/null || package-cleanup --oldkernels --count=2 -y 2>/dev/null || true"
    end

    def update_maintenance_record(instance, results)
      config = instance.config || {}
      config["last_maintenance"] = {
        "ran_at" => Time.current.iso8601,
        "tasks" => results.keys,
        "success" => results.values.all? { |r| r[:success] }
      }

      instance.update!(config: config)
    end
  end
end
