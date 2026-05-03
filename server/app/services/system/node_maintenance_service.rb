# frozen_string_literal: true

require "concurrent"

module System
  # Performs node-level maintenance (health, cleanup, security updates,
  # config sync, log rotation, cert renewal). Public methods return
  # System::Runtime::Result. Internal task_* helpers stay hash-shaped so
  # they can carry per-task structured data (issues, counts, durations).
  #
  # Per-instance loops inside the task helpers run in parallel via a bounded
  # thread pool — see `parallel_each_instance`. This turns an O(N × ssh_rtt)
  # sweep into O(ceil(N / pool_size) × ssh_rtt) for fleets above the pool
  # size. Pool default is 8; override via options[:max_threads].
  class NodeMaintenanceService
    class MaintenanceError < StandardError; end

    MAINTENANCE_TASKS = %w[
      health_check
      resource_cleanup
      security_update
      config_sync
      log_rotation
      certificate_renewal
    ].freeze

    DEFAULT_MAX_THREADS = 8

    def self.run_maintenance(node:, tasks: nil, options: {})
      new.run_maintenance(node: node, tasks: tasks, options: options)
    end

    def self.run_account_maintenance(account:, tasks: nil, options: {})
      new.run_account_maintenance(account: account, tasks: tasks, options: options)
    end

    def run_maintenance(node:, tasks: nil, options: {})
      validate_node!(node)

      return Runtime::Result.err(error: "Node is disabled") unless node.enabled?

      tasks ||= MAINTENANCE_TASKS
      tasks = Array(tasks) & MAINTENANCE_TASKS

      Rails.logger.info("[NodeMaintenanceService] Running maintenance on #{node.name}: #{tasks.join(', ')}")

      results = {}
      all_success = true

      tasks.each do |task|
        Rails.logger.info("[NodeMaintenanceService] Task: #{task}")
        result = send("task_#{task}", node, options)
        results[task] = result
        all_success = false unless result[:success]
      end

      update_maintenance_record(node, results)

      data = {
        results: results,
        tasks_run: tasks.count,
        tasks_succeeded: results.count { |_, r| r[:success] },
        tasks_failed: results.count { |_, r| !r[:success] }
      }
      all_success ? Runtime::Result.ok(data: data) : Runtime::Result.err(error: "#{data[:tasks_failed]} task(s) failed", data: data)
    end

    def run_account_maintenance(account:, tasks: nil, options: {})
      nodes = ::System::Node.where(account: account, enabled: true)

      return Runtime::Result.ok(data: { message: "No enabled nodes for account" }) if nodes.empty?

      Rails.logger.info("[NodeMaintenanceService] Running maintenance on #{nodes.count} nodes for account #{account.id}")

      results = []
      all_success = true

      nodes.find_each do |node|
        result = run_maintenance(node: node, tasks: tasks, options: options)
        results << { node_id: node.id, node_name: node.name, success: result.success?, data: result.data, error: result.error }
        all_success = false unless result.success?
      end

      data = {
        results: results,
        total_nodes: nodes.count,
        nodes_succeeded: results.count { |r| r[:success] },
        nodes_failed: results.count { |r| !r[:success] }
      }
      all_success ? Runtime::Result.ok(data: data) : Runtime::Result.err(error: "#{data[:nodes_failed]} node(s) failed maintenance", data: data)
    end

    private

    def validate_node!(node)
      raise ArgumentError, "Node required" unless node
      raise ArgumentError, "Node must be a System::Node" unless node.is_a?(::System::Node)
    end

    # Task: Health Check - Verify node and instance health
    def task_health_check(node, options)
      Rails.logger.info("[NodeMaintenanceService] Running health check for #{node.name}")

      start_time = Time.current
      issues = []

      issues << "No SSH key configured" if node.ssh_key.blank?

      instances = node.node_instances
      running = instances.where(status: "running").count
      total = instances.count

      stuck = instances.where(status: %w[starting stopping rebooting]).where("updated_at < ?", 30.minutes.ago)
      issues << "#{stuck.count} instances stuck in transitional state" if stuck.any?

      reachability = parallel_each_instance(instances.where(status: "running"), options) do |instance|
        ping_result = check_instance_connectivity(instance)
        { name: instance.name, reachable: ping_result[:success] }
      end

      reachability.each do |r|
        issues << "Instance #{r[:name]} not reachable" unless r[:reachable]
      end

      {
        success: issues.empty?,
        duration: Time.current - start_time,
        running_instances: running,
        total_instances: total,
        issues: issues
      }
    end

    # Task: Resource Cleanup - Clean up orphaned resources
    def task_resource_cleanup(node, options)
      Rails.logger.info("[NodeMaintenanceService] Running resource cleanup for #{node.name}")

      start_time = Time.current
      cleaned = []

      retention_days = options[:retention_days] || 30
      cutoff = retention_days.days.ago

      terminated = node.node_instances.where(status: "terminated").where("updated_at < ?", cutoff)
      terminated_count = terminated.count

      if terminated_count > 0 && options[:delete_terminated]
        terminated.destroy_all
        cleaned << "Deleted #{terminated_count} old terminated instances"
      elsif terminated_count > 0
        cleaned << "Found #{terminated_count} terminated instances eligible for cleanup"
      end

      orphaned_volumes = find_orphaned_volumes(node)
      cleaned << "Found #{orphaned_volumes.count} orphaned volumes" if orphaned_volumes.any?

      failed_ops = ::System::Task.where(operable: node).where(status: "failed").where("completed_at < ?", cutoff)

      if failed_ops.any? && options[:clean_failed_operations]
        failed_count = failed_ops.count
        failed_ops.delete_all
        cleaned << "Cleaned #{failed_count} old failed operations"
      end

      { success: true, duration: Time.current - start_time, actions: cleaned }
    end

    # Task: Security Update - Check for and apply security updates
    def task_security_update(node, options)
      Rails.logger.info("[NodeMaintenanceService] Checking security updates for #{node.name}")

      start_time = Time.current

      per_instance = parallel_each_instance(node.node_instances.where(status: "running"), options) do |instance|
        result = SshExecutionService.execute(
          instance: instance,
          command: check_updates_command(instance),
          sudo: true
        )
        next nil unless result.success? && result.data[:stdout].present?

        updates = parse_updates(result.data[:stdout])
        next nil if updates.empty?

        applied = if options[:apply_updates]
                    apply_result = apply_security_updates(instance)
                    apply_result[:success] ? instance.name : nil
        end

        { needed: { instance: instance.name, count: updates.count }, applied: applied }
      end

      collected = per_instance.compact
      updates_needed = collected.map { |h| h[:needed] }
      updates_applied = collected.map { |h| h[:applied] }.compact

      {
        success: true,
        duration: Time.current - start_time,
        updates_needed: updates_needed,
        updates_applied: updates_applied
      }
    end

    # Task: Config Sync - Sync node configuration to instances
    def task_config_sync(node, options)
      Rails.logger.info("[NodeMaintenanceService] Syncing configuration for #{node.name}")

      start_time = Time.current

      per_instance = parallel_each_instance(node.node_instances.where(status: "running"), options) do |instance|
        result = SshExecutionService.sync(instance: instance)
        result.success? ? { synced: instance.name } : { failed: { instance: instance.name, error: result.error } }
      end

      synced = per_instance.map { |h| h[:synced] }.compact
      failed = per_instance.map { |h| h[:failed] }.compact

      { success: failed.empty?, duration: Time.current - start_time, synced: synced, failed: failed }
    end

    # Task: Log Rotation - Trigger log rotation on instances
    def task_log_rotation(node, options)
      Rails.logger.info("[NodeMaintenanceService] Running log rotation for #{node.name}")

      start_time = Time.current

      per_instance = parallel_each_instance(node.node_instances.where(status: "running"), options) do |instance|
        result = SshExecutionService.execute(
          instance: instance,
          command: "logrotate -f /etc/logrotate.conf",
          sudo: true
        )
        result.success? ? instance.name : nil
      end

      rotated = per_instance.compact

      { success: true, duration: Time.current - start_time, rotated: rotated }
    end

    # Task: Certificate Renewal - Check and renew SSL certificates
    def task_certificate_renewal(node, options)
      Rails.logger.info("[NodeMaintenanceService] Checking certificates for #{node.name}")

      start_time = Time.current
      threshold_days = options[:cert_threshold_days] || 30

      per_instance = parallel_each_instance(node.node_instances.where(status: "running"), options) do |instance|
        cert_result = check_certificates(instance, threshold_days)
        next nil if cert_result[:expiring].empty?

        renewed = if options[:auto_renew]
                    renew_result = renew_certificates(instance)
                    renew_result[:success] ? instance.name : nil
        end

        { expiring: { instance: instance.name, certs: cert_result[:expiring] }, renewed: renewed }
      end

      collected = per_instance.compact
      expiring = collected.map { |h| h[:expiring] }
      renewed = collected.map { |h| h[:renewed] }.compact

      {
        success: true,
        duration: Time.current - start_time,
        expiring_certificates: expiring,
        renewed: renewed
      }
    end

    def check_instance_connectivity(instance)
      ssh_ip = instance.ssh_ip_address
      return { success: false, error: "No SSH IP" } unless ssh_ip.present?

      result = SshExecutionService.execute(instance: instance, command: "echo pong", sudo: false)

      { success: result.success? && result.data[:stdout]&.include?("pong") }
    end

    def find_orphaned_volumes(node)
      instance_ids = node.node_instances.pluck(:id)

      ::System::ProviderVolumeMember
        .where.not(node_instance_id: instance_ids)
        .includes(:provider_volume)
        .map(&:provider_volume)
        .compact
    end

    def check_updates_command(_instance)
      # Detect package manager and generate appropriate command
      "apt list --upgradable 2>/dev/null || yum check-update 2>/dev/null || true"
    end

    def parse_updates(output)
      output.lines.select { |l| l.include?("/") || l.include?("updates") }
    end

    def apply_security_updates(instance)
      result = SshExecutionService.execute(
        instance: instance,
        command: "apt-get update && apt-get upgrade -y --only-upgrade 2>/dev/null || yum update -y 2>/dev/null || true",
        sudo: true
      )

      { success: result.success? }
    end

    def check_certificates(instance, threshold_days)
      result = SshExecutionService.execute(
        instance: instance,
        command: "find /etc/letsencrypt/live -name 'cert.pem' -exec openssl x509 -in {} -checkend #{threshold_days * 86400} \\; 2>/dev/null || true",
        sudo: true
      )

      expiring = []
      expiring << "letsencrypt" if result.data[:stdout]&.include?("Certificate will expire")
      { expiring: expiring }
    end

    def renew_certificates(instance)
      result = SshExecutionService.execute(instance: instance, command: "certbot renew --quiet", sudo: true)
      { success: result.success? }
    end

    # Run a block per instance with bounded concurrency. Each future runs on
    # a fixed thread pool, with its own AR connection checked out from the
    # pool so callers can safely touch ActiveRecord. Block exceptions are
    # logged and converted to nil results so a single misbehaving instance
    # doesn't poison the whole sweep.
    #
    # @param instances [Enumerable<NodeInstance>] target set
    # @param options [Hash] reads :max_threads (Integer, default 8)
    # @yield [instance] block to run per instance — should return a hash
    # @return [Array] block return values in input order; nil where the block
    #   raised
    def parallel_each_instance(instances, options = {})
      items = instances.to_a
      return [] if items.empty?

      max_threads = options[:max_threads] || DEFAULT_MAX_THREADS
      pool_size = [ items.size, max_threads ].min
      pool = Concurrent::FixedThreadPool.new(pool_size)

      begin
        futures = items.map do |item|
          Concurrent::Future.execute(executor: pool) do
            ActiveRecord::Base.connection_pool.with_connection do
              yield item
            end
          end
        end

        futures.map do |f|
          f.wait
          if f.fulfilled?
            f.value
          else
            Rails.logger.error("[NodeMaintenanceService] parallel task error: #{f.reason&.message}")
            nil
          end
        end
      ensure
        pool.shutdown
        pool.wait_for_termination(120)
      end
    end

    def update_maintenance_record(node, results)
      config = node.config || {}
      config["last_maintenance"] = {
        "ran_at" => Time.current.iso8601,
        "tasks" => results.keys,
        "success" => results.values.all? { |r| r[:success] }
      }
      node.update!(config: config)
    end
  end
end
