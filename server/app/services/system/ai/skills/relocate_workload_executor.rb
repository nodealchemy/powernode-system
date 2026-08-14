# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — relocate a project's workload from one
      # region to another. Two strategies:
      #
      #   blue_green — provision the full target stack first, then terminate
      #                source instances (zero overlap downtime; double-spend
      #                during cutover window)
      #   drain      — terminate source instances *first* (workload-aware
      #                drain), then provision target. Cheaper but with a
      #                gap window between teardown and bring-up. v0 issues
      #                terminate sequentially in source order.
      #
      # Composes:
      #   - ProvisionFullStackExecutor (target region) for the new stack
      #   - System::ProvisioningService.terminate_instance for source teardown
      #
      # Returns the standard {dry_run, count, planned_actions, outputs,
      # failures, partial} envelope. Outputs additionally surface
      # `terminated_instance_ids` so observability + rollback know which
      # source instances were torn down.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
      class RelocateWorkloadExecutor < BaseSkillExecutor
        STRATEGIES = %w[blue_green drain].freeze
        MAX_COUNT  = 50

        skill_descriptor(
          name: "relocate_workload",
          description: "Relocate a project's compute workload from one region to another via blue/green or drain cutover. Composes ProvisionFullStackExecutor (target) + ProvisioningService.terminate_instance (source).",
          category: "devops",
          inputs: {
            project_id: { type: "string", required: true,
                          description: "Ai::Mission id (the provisioning project being relocated)" },
            from_region_id: { type: "string", required: true,
                              description: "System::ProviderRegion the workload is leaving (audit hint, no lookup)" },
            to_region_id: { type: "string", required: true,
                            description: "System::ProviderRegion the workload is moving to (target for new stack)" },
            cutover_strategy: { type: "string", required: true,
                                description: "One of: #{STRATEGIES.join(', ')}" },
            template_id: { type: "string", required: true,
                           description: "System::NodeTemplate to instantiate at the target region" },
            provider_instance_type_id: { type: "string", required: true,
                                         description: "Instance type for the target stack" },
            count: { type: "integer", required: true,
                     description: "Number of new instances to bring up at the target (1-#{MAX_COUNT})" },
            source_instance_ids: { type: "array", required: true,
                                   description: "System::NodeInstance ids in the source region to terminate during cutover" },
            network_id: { type: "string", required: false,
                          description: "Sdwan::Network — when present, target instances are wired into the SDWAN topology and peer ids returned" },
            with_storage_gb: { type: "integer", required: false,
                               description: "When present, provision a per-instance ProviderVolume of this size at the target" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without provisioning or terminating" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            cutover_strategy: :string,
            planned_actions: [ :object ],
            outputs: {
              node_ids: [ :string ],
              node_instance_ids: [ :string ],
              sdwan_peer_ids: [ :string ],
              storage_volume_ids: [ :string ],
              terminated_instance_ids: [ :string ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          requires_approval: true,
          rollback: :rollback_relocate_workload,
          blast_radius: :high
        )

        binds_to "Fleet Autonomy"

        # Rollback contract: detach-and-delete the volumes provisioned for the
        # *new* (target-region) instances, then terminate those instances (see
        # the ordering note below). The source instances may
        # already be gone — we cannot un-terminate them — so they are not
        # in this kwargs-set. This is best-effort: a failed relocation
        # should be re-driven manually after rollback.
        def rollback_relocate_workload(node_instance_ids: [], storage_volume_ids: [],
                                       sdwan_peer_ids: [], **_extras)
          errors = []

          # VOLUMES BEFORE INSTANCES, detach-then-delete (IMP-093378034fb4).
          # These ids come straight from ProvisionFullStackExecutor's envelope
          # and relocate composes that executor WITH with_storage_gb, so the
          # volumes arrive ATTACHED. `VolumeManagementService#delete` refuses an
          # attached volume outright, and detaching one whose instance has
          # already been terminated asks the provider to detach from a machine
          # it no longer has. Terminate-first therefore failed every volume
          # with "Volume is attached, detach first" and left the row alive.
          # Same shape as ProvisionFullStackExecutor#rollback_provision_full_stack
          # and ScaleProjectExecutor#teardown_resources.
          Array(storage_volume_ids).reverse_each do |volume_id|
            volume = ::System::ProviderVolume.find_by(id: volume_id)
            next unless volume

            if volume.attached?
              detach = ::System::VolumeManagementService.detach(volume: volume)
              unless detach.success?
                errors << { resource: "provider_volume", id: volume_id, error: detach.error }
                next
              end
            end

            result = ::System::VolumeManagementService.delete(volume: volume)
            errors << { resource: "provider_volume", id: volume_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "provider_volume", id: volume_id, error: e.message }
          end

          Array(node_instance_ids).reverse_each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            errors << { resource: "node_instance", id: instance_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          # IMP-94f778f92dba — these are now peers the target provisioning
          # actually enrolled (they used to be a read-back of the network's
          # pre-existing fleet, which is why this was a no-op). "Released when
          # the host instance is terminated" holds only when the terminate
          # SUCCEEDS: the auto-detach lives in
          # ProvisioningService#finalize_termination!, and five of
          # terminate_instance's exits never reach it — four return Result.err
          # and the fifth re-raises. Detach explicitly rather than assume.
          Array(sdwan_peer_ids).reverse_each do |peer_id|
            peer = ::Sdwan::Peer.where(account_id: @account.id).find_by(id: peer_id)
            next unless peer

            ::Sdwan::PeerDetacher.call(node_instance: peer.node_instance, network: peer.network)
          rescue StandardError => e
            errors << { resource: "sdwan_peer", id: peer_id, error: e.message }
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(project_id:, from_region_id:, to_region_id:, cutover_strategy:,
                    template_id:, provider_instance_type_id:, count:, source_instance_ids:,
                    network_id: nil, with_storage_gb: nil, dry_run: false, **_extras)
          strategy = cutover_strategy.to_s
          return failure("cutover_strategy must be one of: #{STRATEGIES.join(', ')}") unless STRATEGIES.include?(strategy)

          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          source_ids = Array(source_instance_ids).map(&:to_s).reject(&:empty?)
          return failure("source_instance_ids must contain at least one id") if source_ids.empty?

          mission = ::Ai::Mission.where(account_id: @account.id).find_by(id: project_id)
          return failure("project not found: #{project_id}") unless mission

          if dry_run
            return success(
              dry_run: true,
              count: count,
              cutover_strategy: strategy,
              planned_actions: build_plan(strategy: strategy, count: count,
                                          source_ids: source_ids,
                                          template_id: template_id,
                                          to_region_id: to_region_id,
                                          provider_instance_type_id: provider_instance_type_id,
                                          network_id: network_id,
                                          with_storage_gb: with_storage_gb),
              outputs: empty_outputs,
              failures: [],
              partial: false
            )
          end

          run_execute(strategy: strategy, count: count, source_ids: source_ids,
                      template_id: template_id, to_region_id: to_region_id,
                      provider_instance_type_id: provider_instance_type_id,
                      network_id: network_id, with_storage_gb: with_storage_gb)
        end

        private

        def run_execute(strategy:, count:, source_ids:, template_id:, to_region_id:,
                        provider_instance_type_id:, network_id:, with_storage_gb:)
          planned_actions = [ { step: "relocate_workload", cutover_strategy: strategy,
                                source_count: source_ids.size, target_count: count } ]
          terminated = []
          failures = []
          provision_data = nil

          if strategy == "drain"
            terminate_step!(source_ids: source_ids, terminated: terminated,
                            failures: failures, planned_actions: planned_actions)

            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions)
          else # blue_green
            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions)

            # Only tear down the source if we actually have a healthy target.
            #
            # IMP-94f778f92dba — "healthy" has to include the fabric.
            #
            # This gap is PRE-EXISTING, not something the enrollment change
            # introduced: the old network leg called compile_for_network,
            # which maps the network's existing peers and enrols nothing, so
            # every blue/green relocate with a network_id already terminated
            # the source while the targets sat off-fabric — and it reported
            # success, because a leg that does nothing cannot fail. The bare
            # instance-count check has never covered the network leg.
            #
            # What changed is that the failure is now KNOWABLE: attach_sdwan_peer
            # entries are real data this executor can gate on. Reading them
            # here is the whole point of producing them.
            #
            # IMP-bb73f7154f27 — "healthy" has to include the SIZE, too: the
            # old empty-check let a 1-of-2 shortfall through, terminating
            # every source against half the requested capacity. Undersized
            # (which subsumes empty) and off-fabric are one guard with one
            # refusal shape.
            target_outputs      = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
            target_instance_ids = Array(target_outputs[:node_instance_ids])
            attached_peer_ids   = Array(target_outputs[:sdwan_peer_ids])
            undersized = target_instance_ids.size < count
            off_fabric = network_id.present? && attached_peer_ids.size < target_instance_ids.size

            if undersized || off_fabric
              # IMP-6b497651d670 — every refusal is a FAILURE with an
              # in-branch reclaim, not a success(partial: true): see
              # #refuse_blue_green_cutover! for why neither standard envelope
              # shape can delegate the reclaim to the runner.
              return refuse_blue_green_cutover!(
                network_id: network_id, count: count,
                provision_data: provision_data, step_failures: failures
              )
            else
              terminate_step!(source_ids: source_ids, terminated: terminated,
                              failures: failures, planned_actions: planned_actions)
            end
          end

          provision_outputs = provision_data ? (provision_data[:outputs] || {}) : empty_outputs
          # The inner executor reports per-leg failures in its own envelope and
          # keeps going; dropping them here left an enrollment or volume error
          # with nowhere to surface — the runner records only what we return.
          failures.concat(provision_data ? Array(provision_data[:failures]) : [])

          success(
            dry_run: false,
            count: count,
            cutover_strategy: strategy,
            planned_actions: planned_actions,
            outputs: {
              node_ids: Array(provision_outputs[:node_ids]),
              node_instance_ids: Array(provision_outputs[:node_instance_ids]),
              sdwan_peer_ids: Array(provision_outputs[:sdwan_peer_ids]),
              storage_volume_ids: Array(provision_outputs[:storage_volume_ids]),
              terminated_instance_ids: terminated
            },
            failures: failures,
            partial: failures.any?
          )
        end

        # IMP-6b497651d670 — a blue_green refusal (undersized OR off-fabric
        # target stack) reclaims the refused targets itself, then reports
        # failure. Neither standard envelope could hand the reclaim to the
        # runner:
        #
        #   - success(partial: true) abandoned the entire stack (VMs + volumes
        #     + enrolled peers, unowned): SkillCompositionRunner reaches
        #     rollback_step! only from handle_failure, so a completed-partial
        #     step never dispatches the rollback that holds these ids.
        #   - a bare failure(...) reclaims nothing either: the runner's
        #     rollback kwargs come from metadata["last_outputs"], which only
        #     mark_completed writes — on a first-run failure the hook fires
        #     with empty kwargs, no-ops, and stamps rolled_back over live
        #     resources.
        #
        # So the reclaim runs HERE, reusing the rollback contract this
        # executor already owns. That contract is target-only by construction:
        # its kwargs are the ids from the target provisioning envelope, and
        # the sources are not in its kwargs-set (terminated_instance_ids is
        # swallowed by **_extras) — so a refused cutover can never reach the
        # workload it declined to tear down. If the runner rolls back again
        # after this failure (composers stamp on_failure: "rollback" by
        # default), the hook is idempotent: every id it re-resolves is
        # already gone. The System::Node shells are deliberately NOT
        # reclaimed — they stay for inspection, the same rationale as
        # ProvisionFullStackExecutor's rollback.
        def refuse_blue_green_cutover!(network_id:, count:, provision_data:, step_failures:)
          outputs     = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
          target_ids  = Array(outputs[:node_instance_ids])
          volume_ids  = Array(outputs[:storage_volume_ids])
          peer_ids    = Array(outputs[:sdwan_peer_ids])

          reasons = []
          if target_ids.empty?
            reasons << "target stack is empty"
          elsif target_ids.size < count
            reasons << "target stack is undersized (#{target_ids.size}/#{count} instances provisioned)"
          end
          if network_id.present? && peer_ids.size < target_ids.size
            reasons << "target stack is off-fabric (#{peer_ids.size}/#{target_ids.size} " \
                       "instances enrolled on network #{network_id})"
          end

          reclaim = rollback_relocate_workload(
            node_instance_ids: target_ids,
            storage_volume_ids: volume_ids,
            sdwan_peer_ids: peer_ids
          )

          message = "blue_green cutover refused: #{reasons.join('; ')}; source instances not terminated"

          # The failure envelope carries no failures array, so the inner
          # executor's own leg failures — the REASON the stack is refused —
          # ride in the message; the runner records only what we return.
          # step_failures covers the provision_data-nil shape (a whole-step
          # inner failure lands in run_execute's local failures, not in an
          # inner envelope).
          leg_failures = Array(step_failures) + (provision_data.is_a?(Hash) ? Array(provision_data[:failures]) : [])
          message += "; provisioning-leg failures: #{summarize_entries(leg_failures)}" if leg_failures.any?

          message += if reclaim[:success]
                       "; refused target stack reclaimed"
                     else
                       "; refused target stack reclaim INCOMPLETE: #{summarize_entries(Array(reclaim[:errors]))}"
                     end

          failure(message)
        end

        # F6 (IMP-6b497651d670 review) — bounded but never truncated
        # mid-identifier: whole entries are rendered (step/resource + id +
        # error) and overflow is COUNTED, not sliced, so an operator reading
        # a failed step never loses an id to a byte cap.
        MESSAGE_DETAIL_LIMIT = 3

        def summarize_entries(entries)
          shown = entries.first(MESSAGE_DETAIL_LIMIT).map do |e|
            label = e[:step] || e["step"] || e[:resource] || e["resource"]
            id    = e[:instance_id] || e["instance_id"] || e[:node_id] || e["node_id"] || e[:id] || e["id"]
            error = e[:error] || e["error"]
            [ label, id ? "(#{id})" : nil, error ? ": #{error}" : nil ].compact.join
          end
          overflow = entries.size - shown.size
          shown.join("; ") + (overflow.positive? ? " (+#{overflow} more)" : "")
        end

        def provision_target!(template_id:, count:, to_region_id:,
                              provider_instance_type_id:, network_id:, with_storage_gb:,
                              failures:, planned_actions:)
          inner = executor(::System::Ai::Skills::ProvisionFullStackExecutor)
          result = inner.execute(
            template_id: template_id, count: count,
            provider_region_id: to_region_id,
            provider_instance_type_id: provider_instance_type_id,
            network_id: network_id, with_storage_gb: with_storage_gb,
            dry_run: false
          )

          if result[:success]
            data = result[:data] || {}
            # IMP-666a6e904650 — lift the inner executor's own planned_actions
            # into this envelope (detail steps in execution order, then the
            # provision_target_stack rollup for the leg). The envelope used to
            # carry only the inner outputs and failures, so the run never
            # recorded the create_node/provision_instance/attach_* steps the
            # approval card promised — plan-vs-run grading was structurally
            # impossible.
            planned_actions.concat(Array(data[:planned_actions]))
            planned_actions << { step: "provision_target_stack",
                                 to_region_id: to_region_id,
                                 instance_count: Array(data.dig(:outputs, :node_instance_ids)).size }
            data
          else
            failures << { step: "provision_target_stack", error: result[:error] }
            nil
          end
        end

        def terminate_step!(source_ids:, terminated:, failures:, planned_actions:)
          source_ids.each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            unless instance
              failures << { step: "terminate_source", id: instance_id, error: "instance not found" }
              next
            end

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            if result.success?
              terminated << instance_id
              planned_actions << { step: "terminate_source", instance_id: instance_id }
            else
              failures << { step: "terminate_source", id: instance_id, error: result.error }
            end
          rescue StandardError => e
            failures << { step: "terminate_source", id: instance_id, error: e.message }
          end
        end

        def build_plan(strategy:, count:, source_ids:, template_id:, to_region_id:,
                       provider_instance_type_id:, network_id:, with_storage_gb:)
          steps = [
            { step: "relocate_workload", cutover_strategy: strategy,
              source_count: source_ids.size, target_count: count }
          ]
          # One peer attach and one storage pair per target, inside the
          # provisioning run rather than trailing the whole plan: the real path
          # enrols each instance and provisions-then-attaches its volume as that
          # instance comes up (ProvisionFullStackExecutor#run_execute), so under
          # blue_green all of it completes BEFORE the source is terminated. This
          # is the operator's approval card for a :high blast-radius skill — a
          # single trailing step understated the peer count, and trailing
          # storage placed the volumes after a terminate_source that blue_green
          # does not reach until provisioning is done (IMP-9fff24306a2c). Under
          # drain the trailing placement was order-correct by accident, but
          # still listed the volumes apart from the targets they belong to.
          #
          # Every per-target step uses the inner executor's own emitted step
          # name: creating the Node and provisioning its instance are two state
          # changes, so they are two steps (a collapsed provision_target_instance
          # understated the run by one step per target, IMP-666a6e904650), and
          # the attach is its own step because it is its own state change
          # (IMP-093378034fb4). Since #run_execute concatenates the inner
          # envelope's planned_actions into this executor's own
          # (#provision_target!), a relocate plan and a relocate run CAN be
          # graded step-for-step. The run additionally records one
          # provision_target_stack rollup after the provisioning leg, and
          # records terminate_source only for sources actually terminated —
          # every blue_green refusal (undersized or off-fabric) fails the
          # whole step after reclaiming the refused targets
          # (IMP-6b497651d670, IMP-bb73f7154f27). The terminate steps below
          # carry that guard.
          provision_steps = []
          count.times do |i|
            provision_steps << { step: "create_node", index: i, template_id: template_id }
            provision_steps << { step: "provision_instance", index: i,
                                 to_region_id: to_region_id,
                                 provider_instance_type_id: provider_instance_type_id }
            provision_steps << { step: "attach_sdwan_peer", index: i, network_id: network_id } if network_id.present?
            # Non-positive is "no volume", matching the executor that actually
            # provisions it (ProvisionFullStackExecutor#storage_requested?,
            # IMP-33fa6c51f05d). `blank?` did not screen a 0 — and once the
            # inner executor screens one, listing the pair here would promise a
            # volume the run will not create, on the approval card of a :high
            # blast-radius skill.
            next unless with_storage_gb.respond_to?(:to_i) && with_storage_gb.to_i.positive?

            provision_steps << { step: "provision_storage", index: i, size_gb: with_storage_gb.to_i }
            provision_steps << { step: "attach_volume", index: i }
          end
          terminate_steps = source_ids.map { |id| { step: "terminate_source", instance_id: id } }
          if strategy == "blue_green"
            # IMP-666a6e904650 — blue_green refuses the teardown when the
            # target stack comes up undersized or off-fabric (the
            # blue_green_cutover guard in #run_execute), so an unconditional
            # entry promised a destruction the run may (correctly) decline.
            # The step stays — the operator consents to the intent — marked
            # with the guard that may refuse it, so the card shows both the
            # intent and the safety. IMP-6b497651d670 — the card also
            # discloses the refusal's OTHER side: the fresh target stack is
            # reclaimed and sources stay untouched, because a :high
            # blast-radius approval must cover every destruction the run can
            # perform, including the compensating one.
            condition = if network_id.present?
                          "skipped when the target stack comes up undersized or off-fabric " \
                          "(not fully enrolled on network #{network_id}); on refusal the fresh " \
                          "target stack is reclaimed and sources are left untouched"
                        else
                          "skipped when the target stack comes up undersized (fewer instances " \
                          "than requested); on refusal the fresh target stack is reclaimed and " \
                          "sources are left untouched"
                        end
            terminate_steps.each do |step|
              step[:conditional] = true
              step[:guard] = "blue_green_cutover"
              step[:condition] = condition
            end
          end

          steps.concat(strategy == "drain" ? terminate_steps + provision_steps : provision_steps + terminate_steps)
          steps
        end

        def empty_outputs
          { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [],
            storage_volume_ids: [], terminated_instance_ids: [] }
        end
      end
    end
  end
end
