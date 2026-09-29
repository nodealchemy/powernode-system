# frozen_string_literal: true

module System
  # IMP-88e82d59b7f2 — the ONE author of what system_restart_unit may restart,
  # and of the restart task itself.
  #
  # The agent's LifecycleHandler is the SECOND layer, not the first: its
  # validateUnit refuses a unit its own node did not materialise, but it cannot
  # see the control plane's self-hosting fence, the reason, or which of a node's
  # legitimate units the control plane itself runs on. The verb calls #refusal
  # at request time (its gate context, before anything is parked) and again on
  # the approved replay (its arm, through #restart!) — state changes while a
  # request is parked, and the approval is for a decision made on the old state.
  #
  # NOT System::RestartAfterUpdate, deliberately. That producer creates the same
  # task shape but never meets Ai::AutonomyGate; it restarts what a module's own
  # manifest declared, on the materialisation of a promoted version. This one is
  # a caller-chosen unit, so the gate is the point.
  #
  # A refusal is a MESSAGE (nil means "would proceed"), like
  # System::OutOfBandExecService#refusal, so a preflight can ask without writing.
  class UnitRestartService
    include ::System::Autonomy::SelfManagementFence

    class Refused < StandardError; end

    # One entry per service of a module attached to the instance's node.
    ComposedUnit = Struct.new(:unit, :service, :module_id, :module_name, keyword_init: true)

    AUDIT_ACTION = "system.instance.restart_unit"
    AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze

    REASON_MAX_LENGTH = 500

    # The agent's own unit and its variants (powernode-agent.service,
    # powernode-agent@x.service). Restarting the agent from a task the agent
    # itself is executing kills the executor before it can report, and a bad
    # agent has no working task path left to fix it with.
    AGENT_UNIT_PREFIX = "powernode-agent"
    MANAGED_PREFIX = "powernode-"
    # The shape lifecycle.UnitName produces, widened only by what a unit
    # instance name may hold. No path separator, whitespace or control character.
    MANAGED_UNIT_SHAPE = /\Apowernode-[A-Za-z0-9_.:@-]+\.service\z/

    # Services the control plane RUNS ON, judged only when the fence cannot say
    # whether the target is its own hosting node (self_hosting_node_id unset):
    # then a restart of any of them is refused rather than guessed at. Matched
    # on the SERVICE name a shipped manifest declares (not the module name):
    # rails and postgres by prefix, so rails-setup is covered; the rest exactly,
    # so pg-replica (the postgres-replica module's service) is listed by its own
    # name, which the postgres prefix does not reach.
    CONTROL_PLANE_SERVICE = /\A(?:(?:rails|postgres)|(?:pg-replica|redis|vault|traefik|restore-dynamic|sidekiq|worker-web|caddy)\z)/i

    class << self
      # The units the agent generated for this instance: the services of every
      # module attached to its node (RestartAfterUpdate.attached_modules is the
      # same union the node API serves the agent), named by lifecycle.UnitName.
      def composed_units(instance)
        node = instance&.node
        return [] if node.nil?

        modules = ::System::RestartAfterUpdate.attached_modules(node).index_by(&:id)
        return [] if modules.empty?

        ::System::ModuleService.where(node_module_id: modules.keys).order(:name).map do |svc|
          ComposedUnit.new(
            unit: ::System::RestartAfterUpdate.unit_name(svc.node_module_id, svc.name),
            service: svc.name, module_id: svc.node_module_id,
            module_name: modules.fetch(svc.node_module_id).name
          )
        end
      end
    end

    # nil when the restart would proceed; else the refusal text, authored for
    # the caller. Read-only.
    def refusal(instance:, unit:, reason:)
      reason_refusal(reason) || target_refusal(instance: instance, unit: unit)
    end

    # The unit and instance half of #refusal, without the reason: the seam
    # System::UnitDropinService (IMP-9951cbf20bb0) calls, so a runtime drop-in
    # and a restart refuse exactly the same targets — composed managed units
    # only, never the agent's, the node-scoped INV-1 fence, and a running,
    # reporting agent. `act` names the operation in the message. Read-only.
    def target_refusal(instance:, unit:, act: "restart")
      unit_refusal(instance, unit.to_s.strip, act) || instance_refusal(instance, act)
    end

    # Re-checks, then creates the task and its audit row in ONE transaction: a
    # restart whose audit cannot be written does not happen. Returns the task.
    def restart!(instance:, unit:, reason:, initiated_by: nil, agent_id: nil, deferred_operation_id: nil, call_origin: nil)
      unit = unit.to_s.strip
      reason = reason.to_s.strip
      message = refusal(instance: instance, unit: unit, reason: reason)
      raise Refused, message if message

      ::ActiveRecord::Base.transaction do
        task = ::System::Task.create!(
          account: instance.account, operable: instance, command: "restart", status: "pending",
          initiated_by: initiated_by,
          description: "restart #{unit}: #{reason}",
          options: {
            ::System::Task::RESTART_SCOPE_KEY => "unit",
            "unit" => unit,
            "reason" => reason
          }
        )
        write_audit!(instance: instance, unit: unit, reason: reason, task: task, initiated_by: initiated_by,
                     agent_id: agent_id, deferred_operation_id: deferred_operation_id, call_origin: call_origin)
        task
      end
    end

    private

    def reason_refusal(reason)
      text = reason.to_s.strip
      return "reason is required: say why this unit is being restarted" if text.blank?

      "reason must be at most #{REASON_MAX_LENGTH} characters" if text.length > REASON_MAX_LENGTH
    end

    def unit_refusal(instance, unit, act)
      return "unit is required" if unit.blank?
      return agent_unit_refusal(act) if unit.downcase.start_with?(AGENT_UNIT_PREFIX)

      unless unit.downcase.start_with?(MANAGED_PREFIX)
        return "unit #{unit.inspect} is outside the managed #{MANAGED_PREFIX}* namespace; " \
               "only a unit a module composed on this instance may be the target of a #{act}"
      end
      return "unit #{unit.inspect} is not a well-formed managed unit name (powernode-<module-id>-<service>.service)" unless unit.match?(MANAGED_UNIT_SHAPE)

      composed = self.class.composed_units(instance).find { |c| c.unit == unit }
      return "unit #{unit.inspect} is not composed on this instance (list its modules' services to find the unit name)" if composed.nil?

      fence_refusal(instance, composed, act)
    end

    def agent_unit_refusal(act)
      "the node agent's own unit is never the target of a #{act} through this verb: it acts on the " \
        "process that would report it, and stays out-of-band"
    end

    # INV-1 is NODE-scoped: on the node hosting this control plane EVERY unit
    # is refused, because restarting any service there is management of
    # oneself. When the fence cannot tell (self_hosting_node_id unset) it fails
    # CLOSED for the services the control plane runs on (CONTROL_PLANE_SERVICE),
    # unlike the fence's inert default for other consumers; the rest of a
    # deployment's units are unaffected by the setting being unset.
    def fence_refusal(instance, composed, act)
      if self_managed_target?(instance)
        return "refusing a #{act} of #{composed.unit} on instance #{instance.id} — it is this control plane's " \
               "own hosting node (INV-1: no self-management). Management authority must come from the " \
               "consensus group, never the node itself."
      end
      return nil unless composed.service.match?(CONTROL_PLANE_SERVICE)
      return nil if self_hosting_node_id.present?

      "refusing a #{act} of #{composed.unit} — this deployment has not configured " \
        "#{::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY}, so it cannot verify the " \
        "instance is not the control plane's own hosting node (fail closed for the services the control plane runs on)"
    end

    # A task addressed to a node whose agent is not reporting would wait
    # indefinitely (or run at the next boot, long after the question was
    # asked). on_node_dispatch_refusal is the status arm plus the silence
    # verdict (never reported / went silent), the check the reconcile producers
    # use.
    def instance_refusal(instance, act)
      unless ::System::NodeInstance::HEARTBEAT_EXPECTED_STATUSES.include?(instance.status)
        return "instance is #{instance.status}: a unit #{act} needs a running agent"
      end

      instance.on_node_dispatch_refusal
    end

    def write_audit!(instance:, unit:, reason:, task:, initiated_by:, agent_id:, deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: instance.account,
        user: initiated_by,
        action: AUDIT_ACTION,
        resource_type: "System::NodeInstance",
        resource_id: instance.id.to_s,
        source: "system",
        metadata: {
          unit: unit, reason: reason, task_id: task.id, agent_id: agent_id,
          deferred_operation_id: deferred_operation_id, call_origin: call_origin
        }.compact
      )
    end
  end
end
