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
  # PARKED — no live remote-exec primitive exists anywhere in this codebase
  # yet (System::Task is the closest thing, but it's an async
  # dispatch-and-poll channel for AGENT-side commands, not a synchronous
  # exec/probe call this class could shell out through). #run therefore
  # returns a well-formed, honestly-failing report rather than faking
  # success. A future increment wires each check to either:
  #   (a) a new System::Task command the agent executes + reports back via
  #       events (mirroring ci.module_build's dispatch/poll shape), or
  #   (b) a direct SSH/agent-exec channel, once one exists.
  # ModuleSmokeVerifyExecutor mocks this class entirely in spec — no test
  # depends on live execution here.
  class ModuleSmokeProbe
    Result = Struct.new(:ok?, :checks, keyword_init: true)
    CheckResult = Struct.new(:name, :pass, :detail, keyword_init: true)

    CHECKS = %w[unit_active health_endpoint ldd_closure].freeze

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
      checks = CHECKS.map { |name| parked_check(name) }
      Result.new(ok?: checks.all?(&:pass), checks: checks)
    end

    private

    def parked_check(name)
      CheckResult.new(
        name: name,
        pass: false,
        detail: "PARKED: no live remote-exec primitive wired yet " \
                "(module=#{@node_module&.name}, base_os=#{@base_os_module_name}, " \
                "instance=#{@instance&.id}) — see ModuleSmokeProbe class doc"
      )
    end
  end
end
