# frozen_string_literal: true

module System
  # Live health-probe seam for System::Ai::Skills::ModuleSmokeVerifyExecutor
  # (campaign 019f6084 inc2 §4.3.3) — asserts a freshly-composed module +
  # base-os pairing on a pooled instance is actually healthy. Checks mirror
  # plan §2.6 step 5's shape:
  #
  #   unit_active     — the module's systemd unit is active
  #   health_endpoint — its manifest-declared health endpoint answers
  #   ldd_closure     — `chroot /sysroot ldd <ELF>` reports no "not found"
  #                     (the module's shared-library closure is complete)
  #
  # WIRED (campaign 019f6084 inc-E): dispatches a `probe.module_smoke`
  # System::Task to the target instance — the agent-delegated command the
  # agent's probe_module_smoke.go handler executes — then bounded-polls for
  # its completion, mirroring System::NativeModuleBuildOrchestrator's
  # ci.module_build dispatch/poll shape. Every concrete check input (unit
  # names, health endpoints, ldd candidates) is computed HERE, server-side,
  # from the module's own system_module_services rows + file_spec, and
  # travels through the task's options — the agent has no independent
  # knowledge of "the module" beyond what's in those options (see
  # ProbeModuleSmokeHandler's doc on the agent side).
  #
  # ldd_closure candidates are restricted to CONCRETE (non-glob) file_spec
  # entries — rsync-glob patterns like "/usr/lib/node_modules/**" would
  # need live expansion against the mounted layer, which nothing in this
  # path does yet. Glob-only file_spec modules simply get a vacuous pass on
  # this check (see #elf_candidates) — a known limitation, not a silent
  # false-positive: the check only ever asserts what it actually probed.
  #
  # On no-agent (stale/absent heartbeat) or a poll timeout, #run returns a
  # well-formed, honestly-failing "unavailable" report rather than faking
  # success — same posture the pre-wiring PARKED stub had.
  class ModuleSmokeProbe
    Result = Struct.new(:ok?, :checks, keyword_init: true)
    CheckResult = Struct.new(:name, :pass, :detail, keyword_init: true)

    CHECKS = %w[unit_active health_endpoint ldd_closure].freeze

    # Bounded poll, operator-overridable via SiteSetting — same pattern as
    # CiBuildOrchestrator's run_correlate_timeout (never a bare hardcoded
    # cap). A module_smoke probe is a handful of shell-outs on the agent
    # side (systemctl/curl/chroot+ldd), so the default is generous but far
    # short of a build's multi-minute budget.
    DEFAULT_POLL_TIMEOUT_SECONDS = 120
    DEFAULT_POLL_INTERVAL_SECONDS = 2

    # file_spec can carry hundreds of concrete paths for a large package
    # module — cap how many ldd calls a single probe dispatches.
    MAX_ELF_CANDIDATES = 25

    class << self
      def run(instance:, node_module:, base_os_module_name:)
        new(instance: instance, node_module: node_module, base_os_module_name: base_os_module_name).run
      end
    end

    def initialize(instance:, node_module:, base_os_module_name:)
      @instance = instance
      @node_module = node_module
      @base_os_module_name = base_os_module_name
    end

    def run
      return unavailable("instance has no reachable on-node agent (stale or no heartbeat)") unless agent_reachable?

      task = dispatch_task!
      return unavailable("failed to dispatch probe.module_smoke task") unless task

      poll_for_completion(task)

      case task.status
      when "complete"
        result_from_task(task)
      when "failed"
        unavailable("probe.module_smoke failed: #{task.error_message}")
      else
        unavailable("probe.module_smoke timed out after #{poll_timeout_seconds}s " \
                    "(task=#{task.id}, status=#{task.status})")
      end
    end

    private

    def agent_reachable?
      @instance.present? && @instance.respond_to?(:stale_heartbeat?) && !@instance.stale_heartbeat?
    end

    # === Dispatch ===

    def dispatch_task!
      ::System::Task.create!(
        account: @node_module.account,
        operable: @instance,
        command: "probe.module_smoke",
        status: "pending",
        options: task_options
      )
    rescue StandardError => e
      Rails.logger.warn("[ModuleSmokeProbe] dispatch failed (instance=#{@instance&.id}, " \
                        "module=#{@node_module&.name}): #{e.class}: #{e.message}")
      nil
    end

    def task_options
      {
        "module" => @node_module.name,
        "module_id" => @node_module.id,
        "base_os" => @base_os_module_name,
        "checks" => CHECKS,
        "services" => service_names,
        "health_checks" => health_checks,
        "elf_candidates" => elf_candidates
      }
    end

    def service_names
      @node_module.module_services.pluck(:name)
    end

    def health_checks
      @node_module.module_services.where.not(health_endpoint: [ nil, "" ]).map do |svc|
        { "service" => svc.name, "endpoint" => svc.health_endpoint, "method" => svc.health_method }
      end
    end

    def elf_candidates
      Array(@node_module.file_spec).select { |p| concrete_absolute_path?(p) }.first(MAX_ELF_CANDIDATES)
    end

    # Only concrete, non-glob absolute paths are usable ldd candidates —
    # rsync-glob entries (e.g. "/usr/lib/node_modules/**") would need live
    # expansion against the mounted layer, which nothing in this path does
    # yet (a future increment could expand globs against a live instance).
    # This also incidentally guards against file_spec entries that were
    # base64-encoded by NodeModule#encode_specs (operator-authored via the
    # UI's textarea form — see that private method's doc): an encoded blob
    # essentially never starts with "/", so it's naturally filtered out
    # here rather than sent to the agent as a bogus literal path.
    def concrete_absolute_path?(path)
      path.is_a?(String) && path.start_with?("/") && !path.end_with?("/") && !path.match?(/[*?\[\{]/)
    end

    # === Poll (mirrors CiBuildOrchestrator#correlate_run's bounded-retry
    # shape: a monotonic deadline, sleeping between checks, never raising) ===

    def poll_for_completion(task)
      deadline = monotonic_now + poll_timeout_seconds
      loop do
        task.reload
        return if task.finished?
        break if monotonic_now >= deadline

        sleep(poll_interval_seconds)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def poll_timeout_seconds
      (::SiteSetting.get("system.module_smoke.poll_timeout_seconds").presence || DEFAULT_POLL_TIMEOUT_SECONDS).to_i
    end

    def poll_interval_seconds
      (::SiteSetting.get("system.module_smoke.poll_interval_seconds").presence || DEFAULT_POLL_INTERVAL_SECONDS).to_i
    end

    # === Result parsing ===

    def result_from_task(task)
      raw = task_result(task)
      checks = Array(raw["checks"]).map { |c| check_result_from_hash(c) }
      ok = raw.key?("ok") ? !!raw["ok"] : checks.present? && checks.all?(&:pass)
      Result.new(ok?: ok, checks: checks)
    end

    def check_result_from_hash(c)
      c = c.stringify_keys if c.respond_to?(:stringify_keys)
      CheckResult.new(name: c["name"], pass: !!c["ok"], detail: c["detail"])
    end

    # Reads the "completed" event's "result" payload — mirrors
    # System::NativeModuleBuildOrchestrator#task_result exactly (both are
    # tiny, four-line private helpers reading the same Task#events shape;
    # kept as separate copies rather than a shared concern, per that
    # class's precedent).
    def task_result(task)
      completed_event = Array(task.events).reverse.find { |e| (e["type"] || e[:type]).to_s == "completed" }
      raw = completed_event && (completed_event["result"] || completed_event[:result])
      raw.is_a?(Hash) ? raw.stringify_keys : {}
    end

    # === Unavailable (no-agent / dispatch failure / timeout / task failure) ===

    def unavailable(message)
      Rails.logger.warn("[ModuleSmokeProbe] #{message} (module=#{@node_module&.name}, " \
                        "base_os=#{@base_os_module_name}, instance=#{@instance&.id})")
      Result.new(
        ok?: false,
        checks: CHECKS.map { |name| CheckResult.new(name: name, pass: false, detail: "unavailable: #{message}") }
      )
    end
  end
end
