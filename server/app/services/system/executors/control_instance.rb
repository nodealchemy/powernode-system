# frozen_string_literal: true

module System
  module Executors
    # Approval-replayable start/stop/reboot for a System::NodeInstance
    # (campaign 01a0790b increment 1).
    #
    # Sibling of System::Executors::TerminateInstance, and it exists for the
    # same reason: Ai::AutonomyGate defers by storing `executor_class` and
    # re-invoking it once an approval lands, so a gated action's executor —
    # not the calling surface — is the actor on BOTH branches.
    #
    # WHY THIS REPLACES ExecuteTask ON THE REST LIFECYCLE ARMS
    #
    # ExecuteTask inserts a System::Task("start"/"stop"/"reboot"), which is
    # dispatched two ways and actuated correctly by NEITHER on this fleet:
    #
    #   1. The SERVER arm (SystemExecuteTaskJob -> worker_api/tasks/:id/execute
    #      -> ExecutionDispatcher) was unreachable, and campaign 01a0790b
    #      increment 3 has since DELETED it entirely. It scoped every action
    #      through `System::Node.where(worker: current_worker)` and
    #      `node.worker_id` is NULL on every node, so /execute 404'd for every
    #      task id (the measurement is recorded in
    #      Api::V1::System::WorkerApi::JanitorController's header).
    #   2. The AGENT arm does pull the row — node_api/status_controller serves
    #      every pending task on the instance with no command filter — and then
    #      does the WRONG thing, because the agent's handlers are systemd-unit
    #      verbs, not provider verbs:
    #        start/stop  -> LifecycleHandler, which requires options["unit"]
    #                       and fails validateUnit without one.
    #        reboot      -> RebootHandler, `systemctl reboot` INSIDE the guest:
    #                       a soft reboot, not a provider reboot.
    #
    # The in-thread provider call the REST arm used to make
    # (NodeInstanceGating#execute_local_provider_action_sync!) was gated on
    # `provider_type == "local_qemu"` and this fleet is Proxmox, so it never
    # fired here. The net effect was that REST start/stop left the row stranded
    # in its transitional state with the machine untouched.
    #
    # Routing to InstanceControlService instead is what the MCP verbs
    # system_start/stop/reboot_instance already do, so this makes the two
    # surfaces agree on one actuator rather than inventing a third.
    #
    # NO System::Task ROW IS CREATED. That is the point: a Task is a message to
    # the agent, and these are provider-plane operations the agent cannot
    # perform. The audit record is the Ai::DeferredOperation / approval trail
    # the gate already writes.
    class ControlInstance < ::System::Executors::Base
      # The three provider-plane lifecycle verbs. `terminate` is deliberately
      # ABSENT: it carries four controls that live only in ProvisioningService
      # (INV-1, SDWAN peer detach, deploy-key revocation, the terminate meter
      # event) and is routed to System::Executors::TerminateInstance instead.
      # See that class for the full rationale.
      ACTIONS = %w[start stop reboot].freeze

      class ControlFailed < StandardError; end

      protected

      # Account-anchored for the same reason TerminateInstance is: a deferred
      # operation is replayed LATER, the row can have been re-parented in
      # between, and "belongs to another account" and "exists nowhere" must
      # raise the same error so a replay cannot be used as a cross-tenant
      # existence oracle.
      #
      # The may_<action>? guard and the AASM transition both live in
      # InstanceControlService (#can_execute_action? / #update_transitional_status).
      # Deliberately NOT duplicated here — two guards over one transition is
      # how the two surfaces drifted apart in the first place.
      def perform
        instance = resolve_scoped(::System::NodeInstance, params[:instance_id])
        action = params[:action].to_s
        unless ACTIONS.include?(action)
          raise ArgumentError, "unsupported control action #{action.inspect} (expected one of #{ACTIONS.join(', ')})"
        end

        result = ::System::InstanceControlService.execute(instance: instance, action: action.to_sym)
        raise ControlFailed, (result.error.presence || "#{action} failed") unless result.success?

        { instance_id: instance.id, action: action, status: instance.reload.status }
      end

      def summarize
        instance = scoped_label_record(::System::NodeInstance, params[:instance_id])
        verb = params[:action].to_s.capitalize
        instance ? "#{verb} instance '#{instance.name}'" : "#{verb} instance #{params[:instance_id]}"
      end

      # Identifies the instance by the id the CALLER supplied, never by a
      # looked-up name — and the distinction is load-bearing twice over.
      #
      # This string is also the frozen `description` (gate_or_execute seeds it
      # from #preview[:impact] so an approver never sees two labels for one
      # operation, IMP-1dd3ed2b5353), and the two are computed at different
      # moments: at gate time `preview(params)` has no Ai::DeferredOperation
      # anchor, at card time it does. Anything resolved through
      # #scoped_label_record therefore differs between them — it fails closed
      # without an anchor — and the drift guard reddens. Echoing params back
      # touches no database and so cannot disagree with itself.
      #
      # It also discloses nothing: the id came from the requester. Naming the
      # RECORD at pre-gate time is what ExecuteTask has to gate behind
      # #name_disclosable? (execute_task.rb:166-182), because an unanchored
      # preview would otherwise hand back a caller-named foreign UUID's name.
      #
      # An earlier draft of this comment claimed naming a record here was
      # structurally impossible. That was wrong — ExecuteTask#impact does it,
      # via resolve_operable's unanchored passthrough plus that disclosure
      # gate. It is possible; it is just more machinery than an id needs, and
      # the id is what distinguishes one queued approval from another.
      # #summarize carries the human name, rendered once, with an anchor.
      def impact
        subject = "instance #{params[:instance_id]}"
        case params[:action].to_s
        when "start"  then "Powers #{subject} on through its provider"
        when "stop"   then "Powers #{subject} off through its provider"
        when "reboot" then "Power-cycles #{subject} through its provider"
        else "Changes the power state of #{subject} through its provider"
        end
      end
    end
  end
end
