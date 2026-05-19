# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Spin up N instances of a Template in a region. Composition shape:
      #   system_get_template → loop(system_create_node) → parallel(system_provision_instance)
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (provision_cluster row).
      # The executor returns a structured *result set* (created nodes + provisioning
      # task ids); polling/wait_for_running is the autonomy reconciler's job.
      class ProvisionClusterExecutor
        DEFAULT_NAME_PREFIX = "node"

        def self.descriptor
          {
            name: "provision_cluster",
            description: "Provision N instances of a Template in a region — composes create_node + provision_instance for each",
            category: "devops",
            inputs: {
              template_id: { type: "string", required: true },
              count: { type: "integer", required: true,
                       description: "Number of nodes/instances to spin up (1-50)" },
              provider_region_id: { type: "string", required: true },
              provider_instance_type_id: { type: "string", required: true },
              name_prefix: { type: "string", required: false,
                             description: "Prefix for node names (default: \"node\")" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — return projected actions without creating resources" }
            },
            outputs: {
              dry_run: :boolean,
              count: :integer,
              created_nodes: [ :object ],
              provisioned: [ :object ],
              failures: [ :object ],
              partial: :boolean
            }
          }
        end

        # Hard upper bound on a single skill invocation. Larger fleet rolls
        # come through rolling_module_upgrade with explicit operator confirmation.
        MAX_COUNT = 50

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(template_id:, count:, provider_region_id:, provider_instance_type_id:,
                    name_prefix: DEFAULT_NAME_PREFIX, dry_run: false)
          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          tool = ::Ai::Tools::SystemFleetTool.new(account: @account, agent: @agent, user: @user)

          template_check = tool.execute(params: { action: "system_get_template", template_id: template_id })
          return failure("template lookup failed: #{template_check[:error]}") unless template_check[:success]

          if dry_run
            return success(
              dry_run: true,
              count: count,
              created_nodes: [],
              provisioned: [],
              failures: [],
              plan: build_plan(template_check[:data], name_prefix, count, provider_region_id, provider_instance_type_id)
            )
          end

          created = []
          provisioned = []
          failures = []

          count.times do |i|
            node_name = "#{name_prefix}-#{i + 1}-#{SecureRandom.hex(3)}"
            create_result = tool.execute(params: {
              action: "system_create_node", name: node_name, template_id: template_id
            })
            unless create_result[:success]
              failures << { step: "create_node", index: i, error: create_result[:error] }
              next
            end

            node = create_result[:data][:node]
            created << node

            prov_result = tool.execute(params: {
              action: "system_provision_instance",
              node_id: node[:id],
              provider_region_id: provider_region_id,
              provider_instance_type_id: provider_instance_type_id
            })
            if prov_result[:success]
              provisioned << prov_result[:data]
            else
              failures << { step: "provision_instance", node_id: node[:id], error: prov_result[:error] }
            end
          end

          success(
            dry_run: false,
            count: count,
            created_nodes: created,
            provisioned: provisioned,
            failures: failures,
            partial: failures.any? && created.any?
          )
        rescue StandardError => e
          Rails.logger.error("[ProvisionClusterExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def build_plan(template_data, name_prefix, count, region_id, instance_type_id)
          {
            template_id: template_data[:template][:id],
            template_name: template_data[:template][:name],
            count: count,
            naming: "#{name_prefix}-1..#{count}",
            provider_region_id: region_id,
            provider_instance_type_id: instance_type_id,
            estimated_steps: count * 2 # create_node + provision_instance per
          }
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
