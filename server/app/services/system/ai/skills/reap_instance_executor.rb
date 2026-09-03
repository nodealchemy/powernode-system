# frozen_string_literal: true

module System
  module Ai
    module Skills
      # APO-4 (DR-1) — the DESTRUCTIVE half of a replace: terminate the
      # instance whose workload ReplaceInstanceExecutor has already moved onto
      # a warm pool member.
      #
      # WHY THIS IS A CLASS AND NOT A FLAG. The first cut of APO-4 carried the
      # reap as a `reap_only:` input on ReplaceInstanceExecutor, replayed there
      # when the approval released. That put the terminate behind the WRONG
      # gate: BaseSkillExecutor#gate_action! resolves the CLASS's single
      # `action_category`, which on the replace executor is
      # system.instance_replace — the ADDITIVE category. Two consequences, both
      # real:
      #
      #   * any caller that could reach the replace could pass the flag, so a
      #     plan-authored invocation parked a card describing a REPLACE and
      #     released a TERMINATE;
      #   * an operator retuning system.instance_replace to a proceeding verb
      #     (which PolicyDeclarations explicitly contemplates as a tunable
      #     decision) would have auto-executed the terminate with no reap
      #     approval anywhere in the loop.
      #
      # A separate class is what makes the second approval real: this
      # executor's own action_category IS system.instance_reap, so an ungated
      # call gates on the reap policy and a released approval replays THIS
      # class. The replace executor can no longer terminate anything at all —
      # it has no terminate call site left.
      #
      # IDEMPOTENT ON operation_id, on the same ledger the additive half
      # writes (InstanceReplacementLedger): a double release cannot ask the
      # provider to terminate twice, and the reap event shares the replace's
      # correlation_id so the whole operation reads as one thing.
      class ReapInstanceExecutor < BaseSkillExecutor
        include InstanceReplacementLedger

        skill_descriptor(
          name: "reap_instance",
          description: "Terminate an unrecoverable NodeInstance whose workload has already been moved to a pooled replacement. The destructive half of a DR replace, gated separately from it.",
          category: "fleet",
          inputs: {
            instance_id: { type: "string", required: true,
                           description: "System::NodeInstance to terminate — the FAILED one, whose volumes/VIPs have already moved" },
            operation_id: { type: "string", required: true,
                            description: "The replace's idempotency key — the terminate is skipped if a FleetEvent already records it for this id" },
            reason: { type: "string", required: false,
                      description: "Classified reason from the unrecoverable sensor, carried onto the step event" }
          },
          outputs: {
            reaped: :boolean,
            failed_instance_id: :string,
            removed_sdwan_service_backend_ids: [ :string ],
            stranded_sdwan_service_ids: [ :string ],
            replayed: :boolean
          },
          requires_approval: true,
          # Declared rather than derived: the derived name would be
          # system.reap_instance, and the operator-facing row, the
          # PolicyDeclarations entry and Ai::AutonomyGate must all resolve the
          # SAME spelling — system.instance_reap.
          action_category: "system.instance_reap",
          blast_radius: :high
        )

        binds_to "capacity_manager"

        protected

        def perform(instance_id:, operation_id:, reason: nil)
          failed = find_instance(instance_id)
          return failure("Instance not found in account scope: #{instance_id}") unless failed

          prior = replayed_step("reap", operation_id)
          return success(prior.payload.symbolize_keys.merge(replayed: true)) if prior

          # APO-3d — BEFORE the terminate. The dead instance's
          # Sdwan::ServiceBackend rows (drained by the replace) are resolved
          # from its addresses, and the terminate detaches its overlay peer —
          # after it, the rows could no longer be found by the instance and
          # would keep the dead host in every set forever. The same query also
          # reports the services that route to it through their LEGACY column
          # and so have no row to drop (see #remove_service_backends!).
          backends = remove_service_backends!(failed)

          result = ::System::ProvisioningService.terminate_instance(instance: failed)
          return failure("Reap of #{failed.name} failed: #{result.error}") unless result.success?

          payload = { "reaped" => true, "failed_instance_id" => failed.id,
                      "removed_sdwan_service_backend_ids" => backends[:removed],
                      "stranded_sdwan_service_ids" => backends[:stranded] }
          record_step!(step: "reap", operation_id: operation_id, payload: payload,
                       failed: failed, reason: reason, severity: "medium")

          success(payload.symbolize_keys.merge(replayed: false))
        end

        private

        # Drops the failed instance out of every published service's backend
        # set and regenerates the proxy once. Returns { removed:, stranded: }.
        # A regen failure is logged, not raised: the rows are gone and the
        # terminate must still happen; the stale on-disk file is what a
        # system_reverse_proxy_compose repairs.
        #
        # STRANDED is the case row removal cannot reach. A published service
        # nobody ever scaled has NO member row — it dials the instance through
        # its legacy backend_host column, which the writer renders verbatim
        # whenever the set is empty. .remove_instance! honestly returns [] for
        # it, so an empty removal list would read as "no published service
        # routed to this instance" while Traefik keeps dialling the host this
        # executor is about to terminate. Rewriting a published service's
        # backend is not the reap's decision to make; REPORTING it is, and the
        # id is what an operator needs to repoint or unpublish the route.
        def remove_service_backends!(failed)
          services = ::Sdwan::ServiceBackend.host_routed_services(account: @account, instance: failed)
          removed = services.flat_map { |svc| ::Sdwan::ServiceBackend.remove_instance!(service: svc, instance: failed) }
                            .map(&:id)
          stranded = services.select do |svc|
            ::Sdwan::ServiceBackend.legacy_route_only?(service: svc, instance: failed)
          end.map(&:id)
          if stranded.any?
            Rails.logger.warn("[ReapInstanceExecutor] #{failed.id} is still the LEGACY backend of " \
                              "service(s) #{stranded.join(', ')} — the route outlives the instance")
          end
          return { removed: removed, stranded: stranded } if removed.empty?

          begin
            ::Sdwan::ServiceExposureWriter.write!(account: @account)
          rescue ::Sdwan::ServiceExposureWriter::WriteError => e
            Rails.logger.warn("[ReapInstanceExecutor] backend rows removed for #{failed.id} but " \
                              "reverse-proxy regen failed: #{e.message}")
          end
          { removed: removed, stranded: stranded }
        end
      end
    end
  end
end
