# frozen_string_literal: true

module System
  # Lifecycle-control plumbing for NodeInstancesController, extracted to keep the
  # controller focused on action routing (start/stop/reboot/terminate +
  # public-IP association/disassociation). Drives every instance lifecycle
  # action through the Ai::AutonomyGate for uniform audit + chain-of-custody.
  #
  # The lifecycle arms actuate the PROVIDER PLANE and create no System::Task.
  # Campaign 01a0790b increment 1 replaced the in-thread local-hypervisor
  # provider call this header used to describe: it was gated on
  # provider_type == "local_qemu", so on a Proxmox fleet it never fired and the
  # arms left rows stranded in a transitional state with the machine untouched.
  # Actuation now runs through System::InstanceControlService for EVERY
  # provider — the same actuator the MCP verbs use.
  #
  # NOT behaviour-preserving, and deliberately so: the response's `task` key is
  # now always nil (there is no Task to report), and the AASM transition is
  # owned by InstanceControlService rather than fired here. The public-IP arms
  # below are untouched.
  module NodeInstanceGating
    extend ActiveSupport::Concern

    private

    # Returns a rejection message if the instance is on a provider that has no
    # public-IP concept (i.e. local hypervisors). nil = allowed.
    def local_hypervisor_rejection_message
      provider = @instance.provider_region&.provider
      return nil unless provider&.provider_type == "local_qemu"
      ip_hint = @instance.private_ip_address.presence || "pending"
      "Public IP allocation is not supported for local hypervisor instances. " \
        "Connect via the private IP (#{ip_hint}) from the host, or configure " \
        "the provider with a bridged network for routable LAN addressing."
    end

    # Executor per lifecycle verb. All four are PROVIDER-plane operations, so
    # none of them creates a System::Task: a Task is a message to the on-node
    # agent, and the agent cannot power-cycle the machine it runs on.
    #
    # Campaign 01a0790b increment 1. These four arms previously routed through
    # System::Executors::ExecuteTask, which minted a Task that nothing actuated
    # correctly on this fleet — the server dispatch arm 404s for every task id
    # (worker_operations is an empty scope), and the agent arm applies systemd
    # UNIT verbs, so `stop` failed validateUnit and `terminate` ran
    # `systemctl reboot` and brought the VM back. The in-thread provider call
    # that masked this was gated on provider_type == "local_qemu" and this
    # fleet is Proxmox, so it never fired. See System::Executors::ControlInstance.
    # Each entry declares its own param shape, so adding a verb does not mean
    # remembering a special case elsewhere. (An earlier draft encoded this as
    # `unless event == :terminate`, which would have silently handed a spurious
    # :action to any future no-action executor.)
    LIFECYCLE_EXECUTORS = {
      start: { executor: "System::Executors::ControlInstance", action_param: true },
      stop: { executor: "System::Executors::ControlInstance", action_param: true },
      reboot: { executor: "System::Executors::ControlInstance", action_param: true },
      terminate: { executor: "System::Executors::TerminateInstance", action_param: false }
    }.freeze

    def gate_or_execute(event)
      spec = LIFECYCLE_EXECUTORS.fetch(event.to_sym)
      executor_class = spec[:executor]
      executor_params = { instance_id: @instance.id }
      executor_params[:action] = event.to_s if spec[:action_param]

      # PRE-GATE PRECONDITION, and it is not a duplicate of the service's
      # #can_execute_action?. Without it an ordinary "you cannot stop a
      # terminated instance" travels a punishing route: the executor RAISES,
      # Ai::DeferredOperation#execute_now! marks the row `failed` and re-raises,
      # and Ai::AutonomyGate's rescue returns decision :blocked with the message
      # wrapped as "Gate evaluation failed: ...". The caller would get a
      # policy-sounding error for a state problem, and every routine 422 would
      # leave a failed DeferredOperation behind for the governance dashboard to
      # count. Checking the read-only predicate first keeps the 422 clean and
      # writes no row. The service still owns the authoritative check — this
      # cannot replace it, because the approval branch executes LATER, when the
      # state may have moved.
      unless @instance.public_send("may_#{event}?")
        return render_error(
          "Cannot #{event} instance in #{@instance.status} state",
          status: :unprocessable_content
        )
      end

      # The IMPACT line, not the summary. IMP-1dd3ed2b5353 pins that an
      # approver sees ONE label for one operation: the frozen `description`
      # must equal the card's recomputed impact, or the approvals API serves
      # two different descriptions of the same decision.
      #
      # Wrapped, mirroring ExecuteTask.gate_description's own rescue: a label
      # must never fail a control-plane request. The fallback names the verb
      # and the instance, which is what the impact line degrades to anyway.
      label = begin
        executor_class.constantize.preview(executor_params)[:impact].presence ||
          "#{event} instance #{@instance.id}"
      rescue StandardError => e
        Rails.logger.warn("[NodeInstanceGating] label preview failed: #{e.class}: #{e.message}")
        "#{event} instance #{@instance.id}"
      end

      gate_result = ::Ai::AutonomyGate.evaluate(
        # UNCHANGED category. One operator-tuned policy row governs the
        # operation however it is reached; only the executor differs, because
        # the mechanism differs. This is the same split
        # System::Executors::TerminateInstance already made on the MCP side.
        action_category: "system.task.#{event}",
        executor_class: executor_class,
        params: executor_params,
        account: current_account,
        requested_by: current_user,
        source_type: @instance.class.name,
        source_id: @instance.id,
        description: label
      )

      case gate_result.decision
      when :proceed
        # NO failure branch here, and that is not an omission. Executors::Base
        # either returns success:true or RAISES; DeferredOperation#execute_now!
        # re-raises after failing the row; AutonomyGate's rescue turns that into
        # decision :blocked. So on :proceed the executor has already succeeded,
        # and an `if result[:success] == false` guard would be unreachable code
        # asserting a contract the gate does not have.
        #
        # The AASM transition is NOT fired here: InstanceControlService owns it
        # (#update_transitional_status), and ProvisioningService owns
        # terminate's. Duplicating it is how the REST and MCP surfaces drifted.
        render_success(
          node_instance: serialize_instance(@instance.reload),
          task: nil
        )
      when :pending
        render_pending_approval(gate_result.deferred_operation,
                                message: "Approval required to #{event} instance")
      when :blocked
        render_error(gate_result.error || "Action blocked by policy",
                     status: :unprocessable_content)
      end
    end

    # Variant of gate_or_execute for IP association/disassociation —
    # which don't go through the AASM lifecycle (no may_event? predicate)
    # but still need an audit row + the same gate semantics.
    def gate_ip_action(event)
      # ONE label, shared by the task row, the gate description and the card's
      # impact line — see System::Executors::ExecuteTask.gate_description.
      # Each of these built its own raw "cmd Type#uuid" before
      # IMP-1dd3ed2b5353, so an approver read two disagreeing labels for one
      # decision. (The comparison this note used to draw — against
      # #create_instance_operation, "the UNGATED path in this same file" — is
      # gone with that method; the lifecycle arms no longer insert a Task.)
      task_attributes = {
        command: event.to_s,
        operable_type: @instance.class.name,
        operable_id: @instance.id,
        initiated_by_id: current_user.id
      }
      label = ::System::Executors::ExecuteTask.gate_description(task_attributes)

      gate_result = ::Ai::AutonomyGate.evaluate(
        action_category: "system.task.#{event}",
        executor_class: "System::Executors::ExecuteTask",
        params: { task_attributes: task_attributes.merge(description: label) },
        account: current_account,
        requested_by: current_user,
        source_type: @instance.class.name,
        source_id: @instance.id,
        description: label
      )

      case gate_result.decision
      when :proceed
        data = gate_result.result&.dig(:data) || {}
        task = data[:task_id] ? current_account.system_tasks.find_by(id: data[:task_id]) : nil
        render_success(
          node_instance: serialize_instance(@instance.reload),
          task: task ? ::System::TaskSerializer.new(task).as_json : nil
        )
      when :pending
        render_pending_approval(gate_result.deferred_operation,
                                message: "Approval required to #{event}")
      when :blocked
        render_error(gate_result.error || "Action blocked by policy",
                     status: :unprocessable_content)
      end
    end

    # IMP-9ce0ed39c557 — the governed out-of-band exec door (REST side of the
    # same gated primitive the MCP verb system_out_of_band_exec uses; see
    # Ai::Tools::SystemFleetTool#out_of_band_exec_gate_context, which this
    # mirrors check-for-check). Extracted from
    # NodeInstancesController#out_of_band_exec (review finding #10 — that
    # controller was the largest file in its directory) so the action stays
    # a thin permission-check + delegate like every other one here.
    #
    # Not folded into #gate_or_execute: that helper is hardcoded to
    # LIFECYCLE_EXECUTORS' instance_id-only param shape and the
    # "system.task.#{event}" category composition, neither of which fits a
    # caller-supplied command under a differently-named category.
    def gate_out_of_band_exec
      # Security review finding S3 — this door must be a PERSON's own
      # session, never a machine principal. `current_worker` is set by BOTH
      # worker-JWT auth and forwarded-mTLS-client-cert auth
      # (MtlsClientAuthentication#authenticate_worker_via_mtls! sets the
      # same attribute), so checking its presence alone refuses both shapes
      # team-lead named. #require_permission alone does not: a worker
      # carrying system.instances.control would otherwise pass it exactly
      # like a human admin (Authentication#has_permission? dispatches to
      # `current_worker.has_permission?` when a worker, not a user, is the
      # caller) — this feature runs root commands over SSH with no node
      # agent involved, so a compromised/misissued worker or node
      # certificate must not be able to even REQUEST it, human_only
      # approval notwithstanding.
      if current_worker.present?
        Rails.logger.warn(
          "[NodeInstanceGating] refusing out_of_band_exec for a worker/node-cert principal: " \
          "worker=#{current_worker.id}"
        )
        return render_error(
          "out-of-band exec must be requested from a person's own session, never a worker or " \
          "node-cert principal", status: :forbidden
        )
      end

      command = params[:command].to_s
      return render_error("command is required", status: :unprocessable_content) if command.blank?

      sudo = params.key?(:sudo) ? ::ActiveModel::Type::Boolean.new.cast(params[:sudo]) : true

      # Review finding #5 — mirrors
      # SystemFleetTool#out_of_band_exec_gate_context's identical check and
      # reasoning: a blank ssh_ip_address would gate with a nil pinned_ip,
      # which OutOfBandExecService's pin-match check at execution time can
      # never meaningfully compare against.
      if @instance.ssh_ip_address.blank?
        return render_error("instance has no SSH IP address to pin", status: :unprocessable_content)
      end

      # Refuses BEFORE gating exactly what execution time would refuse
      # anyway (self-node / INV-1) — mirrors
      # SystemFleetTool#out_of_band_exec_gate_context's own early check.
      early_refusal = ::System::OutOfBandExecService.new.refusal(instance: @instance, command: command)
      return render_error(early_refusal, status: :unprocessable_content) if early_refusal

      # IP-pin (IMP-9ce0ed39c557): resolve and freeze the CURRENT SSH IP
      # into the operation now, so a target repointed between this
      # request and a later approval is refused at execution time
      # (System::OutOfBandExecService#refusal), not silently followed.
      #
      # call_origin: nil — a REST call is a person acting in their own
      # session, and Ai::Tools::CallOrigin marks doors a MACHINE calls
      # through; there is deliberately no human value (see that module's
      # header). Distinguishing "this ran via REST" from "this ran via
      # the identical MCP verb" is what leaving it unmarked here does. The
      # guard above now makes that reading LITERAL, not just documentary: a
      # machine principal (worker/node-cert) never reaches this line at all.
      #
      # requires_human_session: true (security review finding S1) — same
      # flag BaseTool's human_only branch sets for the MCP verb, passed
      # directly since this door builds its own Ai::AutonomyGate.evaluate
      # call rather than going through BaseTool. Forces require_approval
      # regardless of the resolved policy (Ai::AutonomyGate#evaluate) and
      # marks the opened Ai::ApprovalRequest so it can only be decided from a
      # person's own session — never through a tool door, per every other
      # requires_human_session? consumer (Ai::Tools::AgentAutonomyTool
      # #approve_deferred_operation / #reject_deferred_operation).
      gate_result = ::Ai::AutonomyGate.evaluate(
        action_category: ::System::OutOfBandExecService::ACTION_CATEGORY,
        executor_class: "System::Executors::OutOfBandExec",
        params: {
          instance_id: @instance.id,
          command: command,
          sudo: sudo,
          pinned_ip: @instance.ssh_ip_address,
          call_origin: nil
        },
        account: current_account,
        requested_by: current_user,
        source_type: @instance.class.name,
        source_id: @instance.id,
        # Review finding R2-1 — the pinned address is named on the card the
        # approver actually reads, not just stored in executor_params: an
        # approver must see WHERE this will run, since that's exactly the
        # value a target repoint (system_update_instance is ungated; REST
        # update too) could otherwise silently change underneath a decision
        # made from the instance's NAME alone.
        description: "Run an out-of-band command on '#{@instance.name}' (#{@instance.ssh_ip_address})",
        requires_human_session: true
      )

      # Review finding C2-5 — :proceed is UNREACHABLE here in real operation:
      # requires_human_session: true (above) makes Ai::AutonomyGate#evaluate
      # force require_approval regardless of the resolved policy, so this
      # gate never actually returns :proceed for this category. Mirrors
      # BaseTool#run_through_autonomy_gate's own identical arm
      # (base_tool.rb ~1227-1229) rather than rendering a fabricated success
      # a person never confirmed — if the gate ever DID return :proceed here
      # (a bug elsewhere), reporting it as a refusal is the safe reading, not
      # a success nobody approved.
      case gate_result.decision
      when :proceed
        render_error("Action #{::System::OutOfBandExecService::ACTION_CATEGORY} needs a person's " \
                     "confirmation; refusing.", status: :unprocessable_content)
      when :pending
        render_pending_approval(gate_result.deferred_operation,
                                message: "Approval required to run an out-of-band command on #{@instance.name}")
      when :blocked
        render_error(gate_result.error || "Action blocked by policy", status: :unprocessable_content)
      else
        render_error("Action #{::System::OutOfBandExecService::ACTION_CATEGORY} returned an unknown " \
                     "gate decision #{gate_result.decision.inspect}; refusing.", status: :internal_server_error)
      end
    end

    # REMOVED in campaign 01a0790b increment 1:
    #
    #   #control_or_error              — already had NO callers (all four
    #                                    lifecycle actions route through
    #                                    #gate_or_execute); its only reason to
    #                                    exist was the Task row it minted.
    #   #create_instance_operation     — the ungated System::Task producer.
    #                                    Provider-plane operations do not
    #                                    message the agent, so there is nothing
    #                                    to enqueue.
    #   #local_hypervisor_instance?    — gated on provider_type == "local_qemu";
    #   #execute_local_provider_action_sync!
    #                                    this fleet is Proxmox, so the in-thread
    #                                    provider call NEVER fired here. Its
    #                                    work now happens in
    #                                    InstanceControlService for every
    #                                    provider, not just local ones.
    #
    # #local_hypervisor_rejection_message above is a DIFFERENT predicate (it
    # answers "does this provider have a public-IP concept") and is retained.
  end
end
