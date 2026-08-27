# frozen_string_literal: true

module System
  module Executors
    # Approval-replayable terminate for a System::NodeInstance
    # (IMP-d410a587d6bf).
    #
    # Ai::AutonomyGate defers by storing `executor_class` and re-invoking it
    # once an approval lands, so a gated action's executor — not the tool arm —
    # is the actor on BOTH branches. This class exists so that actor performs
    # EXACTLY the work `Ai::Tools::SystemFleetTool#terminate_instance` used to
    # perform inline, no more and no less.
    #
    # Why not System::Executors::ExecuteTask, which the REST twin uses:
    # ExecuteTask inserts a System::Task("terminate"), which reaches the
    # instance through ExecutionDispatcher -> System::Runtime::ControlInstance
    # -> System::InstanceControlService. That lane looks equivalent — both end
    # at provider_adapter.terminate_instance — but it drops four controls that
    # live in ProvisioningService and nowhere else:
    #
    #   1. INV-1. ProvisioningService includes
    #      System::Autonomy::SelfManagementFence and calls
    #      assert_not_self_managed!(instance, action: "terminate").
    #      InstanceControlService includes no fence, so an approved terminate
    #      of THIS deployment's own hosting node would proceed — the
    #      self-detach class System::Compliance::RcpInvariantScanner asserts is
    #      "blocked at the actuator by SelfManagementFence".
    #   2. Sdwan::PeerDetacher (finalize_termination! -> auto_detach_sdwan_peer!)
    #      — otherwise a terminated instance leaves a live SDWAN peer.
    #   3. Dev-cell deploy-key revocation, including its Vault private key.
    #   4. The "terminated" meter event that closes out accrued hours.
    #
    # Plus F4-02 idempotency: ProvisioningService maps a provider-side NotFound
    # to finalize_termination! (row reaches :terminated), where
    # InstanceControlService#revert_status sends the same case to :error, so a
    # stale row could never finish terminating (the IMP-708079f866d9 bug).
    #
    # Gating must not cost the operation its safety controls, so the gate is
    # what changed here — not the terminate.
    #
    # NOTE (not fixed here): the REST twin
    # (System::NodeInstanceGating#gate_or_execute) still routes terminate
    # through ExecuteTask and therefore still has gaps 1-4. That is a
    # pre-existing defect on the REST surface, reported rather than widened.
    class TerminateInstance < ::System::Executors::Base
      # The policy key BOTH surfaces resolve terminate at. Same category as the
      # REST twin so one operator-tuned row governs the operation however it is
      # reached; the executor differs because the mechanisms differ.
      ACTION_CATEGORY = "system.task.terminate"

      class TerminationFailed < StandardError; end

      # No replay baseline, deliberately. Executors::Base documents the hazard
      # (an operator authorised THIS change against THAT state), and it bites
      # for attribute UPDATES, where replaying a stale edit silently overwrites
      # a concurrent one. Terminate expresses no opinion about any attribute:
      # it names one instance and destroys it, ProvisioningService is idempotent
      # about a resource that is already gone, and finalize_termination! guards
      # its own transition with may_terminate?. Pinning :status would instead
      # make an approval expire whenever the instance moved between parking and
      # approval — refusing to terminate a stopped-since-you-asked VM is not the
      # safer outcome for a destroy the operator explicitly approved. So the
      # inherited empty default stands; this note is the decision, not an
      # omission (and NOT re-declared, because it is a CLASS method on Base and
      # an instance-level override would be silently inert).

      protected

      # Account-anchored: "belongs to another account" and "exists nowhere"
      # raise the same CrossAccountError, so a replayed operation cannot be
      # used as a cross-tenant existence oracle. The gating surface resolves
      # the instance too, but a deferred operation is replayed LATER — the row
      # can have been re-parented in between, and the executor is the half that
      # runs at approval time.
      def perform
        instance = resolve_scoped(::System::NodeInstance, params[:instance_id])

        result = ::System::ProvisioningService.terminate_instance(instance: instance)
        unless result.success?
          raise TerminationFailed, (result.error.presence || "termination failed")
        end

        { instance_id: instance.id, terminated: true }
      end

      def summarize
        instance = scoped_label_record(::System::NodeInstance, params[:instance_id])
        instance ? "Terminate instance '#{instance.name}'" : "Terminate instance #{params[:instance_id]}"
      end

      def impact = "Destroys the cloud resource, detaches its SDWAN peer, and closes out billing"
    end
  end
end
