# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Provision a full compute + (optional) network + (optional) storage stack
      # from a NodeTemplate. Composition shape:
      #
      #   loop(create_node + ProvisioningService.provision_instance)
      #     [+ VolumeManagementService.provision per instance, when with_storage_gb]
      #     [+ Sdwan::TopologyCompiler.compile_for_network, when network_id]
      #
      # The executor returns a structured *result set* (created nodes,
      # provisioned instances, volumes, sdwan peer ids) plus a planned-actions
      # log for the audit trail. Polling/wait_for_running is the autonomy
      # reconciler's job — this executor only provisions and returns.
      #
      # Rollback (`self.rollback_provision_full_stack`): reverses the side
      # effects in last-in / first-out order — terminate node instances,
      # delete provisioned volumes — using the execution_record's outputs as
      # the source of truth for what was created.
      #
      # Reference: AI-Driven Provisioning plan slice 4 (M0).
      class ProvisionFullStackExecutor
        # Hard upper bound on a single skill invocation. Larger fleet rolls go
        # through rolling_module_upgrade with explicit operator confirmation.
        MAX_COUNT = 50

        def self.descriptor
          {
            name: "provision_full_stack",
            description: "Provision a full compute+network+storage stack from a template — composes provision_instance + optional storage volume + optional SDWAN topology compile",
            category: "devops",
            inputs: {
              template_id: { type: "string", required: true,
                             description: "System::NodeTemplate to instantiate" },
              count: { type: "integer", required: true,
                       description: "Number of node instances to provision (1-#{MAX_COUNT})" },
              provider_region_id: { type: "string", required: true,
                                    description: "System::ProviderRegion target" },
              provider_instance_type_id: { type: "string", required: true,
                                           description: "System::ProviderInstanceType for each instance" },
              network_id: { type: "string", required: false,
                            description: "Sdwan::Network — when present, the SDWAN topology is compiled and the resulting peer ids are returned for downstream attach" },
              with_storage_gb: { type: "integer", required: false,
                                 description: "When present, provision a per-instance ProviderVolume of this size" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — return projected actions without creating any cloud resources" }
            },
            outputs: {
              dry_run: :boolean,
              count: :integer,
              planned_actions: [ :object ],
              outputs: {
                node_ids: [ :string ],
                node_instance_ids: [ :string ],
                sdwan_peer_ids: [ :string ],
                storage_volume_ids: [ :string ]
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_provision_full_stack,
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        # `**_extras` swallows context kwargs that PlanComposerService injects
        # into every step's inputs (notably `brief`) so the runner's
        # `executor.execute(**inputs)` invocation doesn't raise ArgumentError.
        def execute(template_id:, count:, provider_region_id:, provider_instance_type_id:,
                    network_id: nil, with_storage_gb: nil, dry_run: false, **_extras)
          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          template = ::System::NodeTemplate.where(account_id: @account.id).find_by(id: template_id)
          return failure("template not found: #{template_id}") unless template

          region = ::System::ProviderRegion.where(account_id: @account.id).find_by(id: provider_region_id)
          return failure("provider region not found: #{provider_region_id}") unless region

          instance_type = ::System::ProviderInstanceType.where(account_id: @account.id).find_by(id: provider_instance_type_id)
          return failure("provider instance type not found: #{provider_instance_type_id}") unless instance_type

          network = nil
          if network_id.present?
            network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: network_id)
            return failure("sdwan network not found: #{network_id}") unless network
          end

          if dry_run
            return success(
              dry_run: true,
              count: count,
              planned_actions: build_plan(template, count, region, instance_type, network, with_storage_gb),
              outputs: { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [], storage_volume_ids: [] },
              failures: [],
              partial: false
            )
          end

          run_execute(template: template, count: count, region: region,
                      instance_type: instance_type, network: network,
                      with_storage_gb: with_storage_gb)
        rescue StandardError => e
          Rails.logger.error("[ProvisionFullStackExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Instance-method rollback contract — invoked by `SkillCompositionRunner`
        # via `executor.public_send(:rollback_provision_full_stack, **outputs)`.
        # Receives the recorded outputs as kwargs so the runner can dispatch
        # without knowing the executor's internals.
        # Nodes themselves are cheap shells — left in place so the operator can
        # inspect the failed run. Only NodeInstances and ProviderVolumes are
        # reversed.
        def rollback_provision_full_stack(node_instance_ids: [], storage_volume_ids: [], **_extras)
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

          { success: errors.empty?, errors: errors }
        end

        private

        def run_execute(template:, count:, region:, instance_type:, network:, with_storage_gb:)
          node_ids = []
          node_instance_ids = []
          storage_volume_ids = []
          failures = []
          planned_actions = []

          count.times do |i|
            node = create_node!(template: template, index: i)
            node_ids << node.id
            planned_actions << { step: "create_node", node_id: node.id, name: node.name }

            prov_result = ::System::ProvisioningService.provision_instance(
              node: node,
              provider_region_id: region.id,
              provider_instance_type_id: instance_type.id
            )

            unless prov_result.success?
              failures << { step: "provision_instance", node_id: node.id, error: prov_result.error }
              next
            end

            instance = prov_result.data[:instance]
            node_instance_ids << instance.id
            planned_actions << { step: "provision_instance", node_id: node.id, instance_id: instance.id }

            next if with_storage_gb.blank?

            vol_result = ::System::VolumeManagementService.provision(
              account: @account,
              region: region,
              volume_type: nil,
              size_gb: with_storage_gb.to_i,
              options: { name: "#{node.name}-data" }
            )
            if vol_result.success?
              volume = vol_result.data[:volume]
              storage_volume_ids << volume.id
              planned_actions << { step: "provision_storage", instance_id: instance.id,
                                   volume_id: volume.id, size_gb: with_storage_gb.to_i }
            else
              failures << { step: "provision_storage", node_id: node.id, error: vol_result.error }
            end
          end

          sdwan_peer_ids = []
          if network
            topology = ::Sdwan::TopologyCompiler.compile_for_network(network)
            sdwan_peer_ids = topology.map { |peer_view| peer_view[:peer_id] }.compact
            planned_actions << { step: "compile_sdwan_topology", network_id: network.id,
                                 peer_count: sdwan_peer_ids.size }
          end

          success(
            dry_run: false,
            count: count,
            planned_actions: planned_actions,
            outputs: {
              node_ids: node_ids,
              node_instance_ids: node_instance_ids,
              sdwan_peer_ids: sdwan_peer_ids,
              storage_volume_ids: storage_volume_ids
            },
            failures: failures,
            partial: failures.any? && (node_instance_ids.any? || storage_volume_ids.any?)
          )
        end

        def create_node!(template:, index:)
          node_name = "#{template.name.parameterize}-#{index + 1}-#{SecureRandom.hex(3)}"
          ::System::Node.create!(
            account: @account,
            name: node_name,
            node_template: template,
            enabled: true
          )
        end

        def build_plan(template, count, region, instance_type, network, with_storage_gb)
          steps = []
          count.times do |i|
            steps << { step: "create_node", index: i, template_id: template.id, template_name: template.name }
            steps << { step: "provision_instance", index: i,
                       provider_region_id: region.id, provider_instance_type_id: instance_type.id }
            if with_storage_gb.present?
              steps << { step: "provision_storage", index: i, size_gb: with_storage_gb.to_i }
            end
          end
          steps << { step: "compile_sdwan_topology", network_id: network.id } if network
          steps
        end

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
