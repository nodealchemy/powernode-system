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

        # Rollback contract: terminate the *new* (target-region) instances
        # we provisioned + delete their volumes. The source instances may
        # already be gone — we cannot un-terminate them — so they are not
        # in this kwargs-set. This is best-effort: a failed relocation
        # should be re-driven manually after rollback.
        def rollback_relocate_workload(node_instance_ids: [], storage_volume_ids: [],
                                       sdwan_peer_ids: [], **_extras)
          errors = []

          Array(node_instance_ids).reverse_each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            errors << { resource: "node_instance", id: instance_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          Array(storage_volume_ids).reverse_each do |volume_id|
            volume = ::System::ProviderVolume.find_by(id: volume_id)
            next unless volume

            result = ::System::VolumeManagementService.delete(volume: volume)
            errors << { resource: "provider_volume", id: volume_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "provider_volume", id: volume_id, error: e.message }
          end

          # IMP-94f778f92dba — these are now peers the target provisioning
          # actually enrolled (they used to be a read-back of the network's
          # pre-existing fleet, which is why this was a no-op). "Released when
          # the host instance is terminated" holds only when the terminate
          # SUCCEEDS: the auto-detach lives in
          # ProvisioningService#finalize_termination!, and four of
          # terminate_instance's exits return an error without ever reaching
          # it. Detach explicitly rather than assume.
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
            target_instance_ids = provision_data ? Array(provision_data[:outputs][:node_instance_ids]) : []
            attached_peer_ids   = provision_data ? Array(provision_data[:outputs][:sdwan_peer_ids]) : []
            off_fabric = network_id.present? && attached_peer_ids.size < target_instance_ids.size

            if target_instance_ids.empty?
              failures << { step: "blue_green_cutover", error: "target stack is empty; refusing to terminate source" }
            elsif off_fabric
              failures << { step: "blue_green_cutover",
                            error: "target stack is off-fabric (#{attached_peer_ids.size}/#{target_instance_ids.size} " \
                                   "instances enrolled on network #{network_id}); refusing to terminate source" }
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
          # One attach per target, inside the provisioning run rather than
          # trailing the whole plan: the real path enrols each instance as it
          # is provisioned, so for blue_green that happens BEFORE the source is
          # terminated. This is the operator's approval card for a :high
          # blast-radius skill — a single trailing step understated the peer
          # count and mis-ordered the cutover.
          provision_steps = []
          count.times do |i|
            provision_steps << { step: "provision_target_instance", index: i,
                                 to_region_id: to_region_id, template_id: template_id,
                                 provider_instance_type_id: provider_instance_type_id }
            provision_steps << { step: "attach_sdwan_peer", index: i, network_id: network_id } if network_id.present?
          end
          terminate_steps = source_ids.map { |id| { step: "terminate_source", instance_id: id } }

          steps.concat(strategy == "drain" ? terminate_steps + provision_steps : provision_steps + terminate_steps)
          if with_storage_gb.present?
            count.times { |i| steps << { step: "provision_target_storage", index: i,
                                         size_gb: with_storage_gb.to_i } }
          end
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
