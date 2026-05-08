# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — scale a provisioning project (Ai::Mission)
      # along one of three axes:
      #
      #   add_replicas      — add N new instances of the project's existing
      #                       template + region (composes ProvisionFullStackExecutor
      #                       in its compute-only mode)
      #   vertical_resize   — plan a rolling module upgrade or instance-type
      #                       swap (composes RollingModuleUpgradeExecutor —
      #                       returns a batched plan, not in-band mutation)
      #   add_region        — provision a parallel stack in a new region
      #                       (composes ProvisionFullStackExecutor with
      #                       optional network + storage for the new region)
      #
      # Executor returns the same {dry_run, count, planned_actions, outputs,
      # failures, partial} envelope as ProvisionFullStackExecutor so the
      # AdaptationProposer + the runner's rollback dispatch can treat all
      # provisioning skills uniformly.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
      class ScaleProjectExecutor
        STRATEGIES = %w[add_replicas vertical_resize add_region].freeze
        MAX_DELTA  = 50

        def self.descriptor
          {
            name: "scale_project",
            description: "Adapt a provisioning project's footprint — add replicas in-region, plan a vertical resize, or expand into a new region. Composes ProvisionFullStackExecutor + RollingModuleUpgradeExecutor.",
            category: "devops",
            inputs: {
              project_id: { type: "string", required: true,
                            description: "Ai::Mission id (the provisioning project being scaled)" },
              target_count: { type: "integer", required: true,
                              description: "Number of new instances (add_replicas / add_region) — bounded 1..#{MAX_DELTA}. Ignored for vertical_resize." },
              scaling_strategy: { type: "string", required: true,
                                  description: "One of: #{STRATEGIES.join(', ')}" },
              template_id: { type: "string", required: false,
                             description: "System::NodeTemplate to instantiate (add_replicas / add_region) or whose fleet is being resized (vertical_resize)" },
              provider_region_id: { type: "string", required: false,
                                    description: "Region for new instances (add_replicas: same as project; add_region: NEW region)" },
              provider_instance_type_id: { type: "string", required: false,
                                           description: "Instance type for new instances" },
              module_id: { type: "string", required: false,
                           description: "vertical_resize: System::NodeModule whose target_version replaces in-place" },
              target_version_id: { type: "string", required: false,
                                   description: "vertical_resize: target System::NodeModuleVersion id" },
              network_id: { type: "string", required: false,
                            description: "add_region: optional Sdwan::Network to attach new instances to" },
              with_storage_gb: { type: "integer", required: false,
                                 description: "add_region: optional per-instance volume size" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — return projected actions without creating any cloud resources" }
            },
            outputs: {
              dry_run: :boolean,
              count: :integer,
              scaling_strategy: :string,
              planned_actions: [ :object ],
              outputs: {
                node_ids: [ :string ],
                node_instance_ids: [ :string ],
                sdwan_peer_ids: [ :string ],
                storage_volume_ids: [ :string ],
                rolling_upgrade_plan: :object
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_scale_project,
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        # `**_extras` swallows context kwargs (notably `brief`) that
        # PlanComposerService injects into every step's inputs.
        def execute(project_id:, target_count:, scaling_strategy:,
                    template_id: nil, provider_region_id: nil,
                    provider_instance_type_id: nil, module_id: nil,
                    target_version_id: nil, network_id: nil,
                    with_storage_gb: nil, dry_run: false, **_extras)
          strategy = scaling_strategy.to_s
          return failure("scaling_strategy must be one of: #{STRATEGIES.join(', ')}") unless STRATEGIES.include?(strategy)

          mission = ::Ai::Mission.where(account_id: @account.id).find_by(id: project_id)
          return failure("project not found: #{project_id}") unless mission

          case strategy
          when "add_replicas", "add_region"
            count = target_count.to_i
            return failure("target_count must be between 1 and #{MAX_DELTA}") unless count.between?(1, MAX_DELTA)
            return failure("template_id is required for #{strategy}") if template_id.blank?
            return failure("provider_region_id is required for #{strategy}") if provider_region_id.blank?
            return failure("provider_instance_type_id is required for #{strategy}") if provider_instance_type_id.blank?

            run_provision(strategy: strategy, count: count, template_id: template_id,
                          provider_region_id: provider_region_id,
                          provider_instance_type_id: provider_instance_type_id,
                          network_id: network_id, with_storage_gb: with_storage_gb,
                          dry_run: dry_run)

          when "vertical_resize"
            return failure("template_id is required for vertical_resize") if template_id.blank?
            return failure("module_id is required for vertical_resize") if module_id.blank?
            return failure("target_version_id is required for vertical_resize") if target_version_id.blank?

            run_vertical_resize(template_id: template_id, module_id: module_id,
                                target_version_id: target_version_id, dry_run: dry_run)
          end
        rescue StandardError => e
          Rails.logger.error("[ScaleProjectExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Instance-method rollback. Reverses the side effects recorded in the
        # outputs envelope. vertical_resize returns a plan — it has no side
        # effects to reverse, so its outputs are empty and rollback no-ops.
        def rollback_scale_project(node_instance_ids: [], storage_volume_ids: [], **_extras)
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

        # add_replicas + add_region both compose the M0 ProvisionFullStackExecutor.
        # The strategies differ only in semantics (same vs. new region) —
        # both delegate to the same primitive and re-shape the result.
        def run_provision(strategy:, count:, template_id:, provider_region_id:,
                          provider_instance_type_id:, network_id:, with_storage_gb:, dry_run:)
          inner = ::System::Ai::Skills::ProvisionFullStackExecutor.new(
            account: @account, agent: @agent, user: @user
          )
          inner_result = inner.execute(
            template_id: template_id,
            count: count,
            provider_region_id: provider_region_id,
            provider_instance_type_id: provider_instance_type_id,
            network_id: network_id,
            with_storage_gb: with_storage_gb,
            dry_run: dry_run
          )
          return inner_result unless inner_result[:success]

          inner_data = inner_result[:data] || {}
          inner_outputs = inner_data[:outputs] || {}

          success(
            dry_run: dry_run ? true : false,
            count: count,
            scaling_strategy: strategy,
            planned_actions: prepend_strategy_marker(strategy, inner_data[:planned_actions]),
            outputs: {
              node_ids: Array(inner_outputs[:node_ids]),
              node_instance_ids: Array(inner_outputs[:node_instance_ids]),
              sdwan_peer_ids: Array(inner_outputs[:sdwan_peer_ids]),
              storage_volume_ids: Array(inner_outputs[:storage_volume_ids]),
              rolling_upgrade_plan: nil
            },
            failures: Array(inner_data[:failures]),
            partial: inner_data[:partial] == true
          )
        end

        # vertical_resize produces a plan only — RollingModuleUpgradeExecutor
        # is plan-returning by design (M7 reconciler advances batches one at
        # a time through ApprovalRequest). We surface the plan in
        # outputs.rolling_upgrade_plan and leave the side-effect outputs
        # empty.
        def run_vertical_resize(template_id:, module_id:, target_version_id:, dry_run:)
          if dry_run
            return success(
              dry_run: true,
              count: 0,
              scaling_strategy: "vertical_resize",
              planned_actions: [ {
                step: "rolling_module_upgrade_plan",
                template_id: template_id, module_id: module_id, target_version_id: target_version_id
              } ],
              outputs: empty_outputs,
              failures: [],
              partial: false
            )
          end

          inner = ::System::Ai::Skills::RollingModuleUpgradeExecutor.new(
            account: @account, agent: @agent, user: @user
          )
          inner_result = inner.execute(
            template_id: template_id, module_id: module_id,
            target_version_id: target_version_id
          )
          return inner_result unless inner_result[:success]

          plan = inner_result[:data] || {}
          success(
            dry_run: false,
            count: plan[:total_instances].to_i,
            scaling_strategy: "vertical_resize",
            planned_actions: [ { step: "rolling_module_upgrade_plan",
                                 batch_count: plan[:batch_count],
                                 batch_size: plan[:batch_size],
                                 estimated_total_seconds: plan[:estimated_total_seconds] } ],
            outputs: empty_outputs.merge(rolling_upgrade_plan: plan),
            failures: [],
            partial: false
          )
        end

        def empty_outputs
          { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [],
            storage_volume_ids: [], rolling_upgrade_plan: nil }
        end

        def prepend_strategy_marker(strategy, planned_actions)
          marker = { step: "scale_project", scaling_strategy: strategy }
          [ marker ] + Array(planned_actions)
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
