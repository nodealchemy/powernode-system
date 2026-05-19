# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Deploy a Git repository onto a provisioned `System::NodeInstance`
      # via SSH + systemd. Skill executor for the
      # `SkillCompositionRunner`: dispatched when a plan step says
      # `skill: "deploy_app_code"`.
      #
      # Composition shape:
      #
      #   Ai::ProvisioningCodeDeployment.create!(status: "pending")
      #     → ::System::CodeDeployService.call(...)  # Slice A
      #     → update deployment row (running | failed)
      #
      # Returns `{ success: true, data: {...} }` (descriptor declares requires_approval statically).
      #
      # Rollback (`rollback_deploy_app_code`): SSH to the node and stop +
      # disable the powernode-app systemd unit, then mark the deployment
      # row `rolled_back`. Errors are collected (never raised) so the
      # runner can surface them.
      #
      # Reference: how-can-we-provide-flickering-candy plan, M3 slice 2.
      class DeployAppCodeExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "deploy_app_code",
          description: "Deploy a Git repository onto a provisioned NodeInstance via SSH+systemd",
          category: "devops",
          inputs: {
            node_instance_id: { type: "string", required: true,
                                description: "Target System::NodeInstance.id (provisioned earlier in the plan)" },
            repo_url: { type: "string", required: true,
                        description: "Git remote URL (https or ssh)" },
            branch: { type: "string", required: false, default: "main",
                      description: "Git branch to deploy" },
            start_command: { type: "string", required: false,
                             description: "Command to run as the systemd ExecStart (e.g. 'npm start'). Inferred from repo if omitted." },
            deploy_key_id: { type: "string", required: false,
                             description: "Secret ID for a private repo deploy key (resolved by CodeDeployService)" },
            mission_id: { type: "string", required: false,
                          description: "Auto-injected by PlanComposer — the Ai::Mission this deploy belongs to" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without touching the node" }
          },
          outputs: {
            deployment_id: :string,
            commit_sha: :string,
            public_url: :string
          },
          rollback: :rollback_deploy_app_code,
          blast_radius: :low
        )

        binds_to "Fleet Autonomy"

        # Instance-method rollback contract — invoked by
        # `SkillCompositionRunner` via
        # `executor.public_send(:rollback_deploy_app_code, **outputs)`.
        # Receives the recorded outputs as kwargs so the runner can
        # dispatch without knowing the executor's internals.
        def rollback_deploy_app_code(deployment_id: nil, node_instance_ids: [], **_extras)
          errors = []

          deployment_ids = Array(deployment_id).compact
          deployment_ids.each do |id|
            deployment = ::Ai::ProvisioningCodeDeployment.find_by(id: id)
            unless deployment
              errors << { resource: "deployment", id: id, error: "not found" }
              next
            end

            instance = deployment.node_instance
            tear_down_result = tear_down_on_node(instance)
            if tear_down_result[:success]
              deployment.update(status: "rolled_back")
            else
              errors << { resource: "deployment", id: id, error: tear_down_result[:error] }
            end
          rescue StandardError => e
            errors << { resource: "deployment", id: id, error: e.message }
          end

          # Tolerate plain node_instance_ids forwarded from a sibling
          # rollback hook — best-effort tear-down without a deployment
          # row to update.
          Array(node_instance_ids).each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            result = tear_down_on_node(instance)
            errors << { resource: "node_instance", id: instance_id, error: result[:error] } unless result[:success]
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        # `**_extras` swallows context kwargs that PlanComposerService
        # injects into every step's inputs (notably `brief`) so the
        # runner's `executor.execute(**inputs)` call doesn't raise
        # ArgumentError.
        def perform(node_instance_id:, repo_url:,
                    branch: "main", start_command: nil,
                    deploy_key_id: nil, mission_id: nil,
                    dry_run: false, **_extras)
          return failure("repo_url is required") if repo_url.to_s.strip.empty?
          return failure("node_instance_id is required") if node_instance_id.to_s.strip.empty?

          node_instance = ::System::NodeInstance.find_by(id: node_instance_id)
          return failure("node_instance not found: #{node_instance_id}") unless node_instance

          mission = nil
          if mission_id.present?
            mission = ::Ai::Mission.find_by(id: mission_id)
            return failure("mission not found: #{mission_id}") unless mission
          end

          if dry_run
            return success(
              dry_run: true,
              deployment_id: nil,
              commit_sha: nil,
              public_url: nil,
              planned_actions: build_plan(node_instance, repo_url, branch, start_command, deploy_key_id)
            )
          end

          return failure("mission_id is required for non-dry-run deploys") unless mission

          run_execute(
            mission: mission,
            node_instance: node_instance,
            repo_url: repo_url,
            branch: branch,
            start_command: start_command,
            deploy_key_id: deploy_key_id
          )
        end

        private

        def run_execute(mission:, node_instance:, repo_url:, branch:, start_command:, deploy_key_id:)
          deployment = ::Ai::ProvisioningCodeDeployment.create!(
            mission: mission,
            node_instance: node_instance,
            repo_url: repo_url,
            branch: branch,
            start_command: start_command,
            status: "pending"
          )

          result = ::System::CodeDeployService.call(
            node_instance: node_instance,
            repo_url: repo_url,
            branch: branch,
            start_command: start_command,
            deploy_key: resolve_deploy_key(deploy_key_id)
          )

          result_hash = normalize_result(result)

          if result_hash[:success]
            deployment.update!(
              commit_sha: result_hash[:commit_sha],
              public_url: result_hash[:public_url],
              status: "running",
              deployed_at: Time.current,
              last_error: nil
            )
            success(
              dry_run: false,
              deployment_id: deployment.id,
              commit_sha: deployment.commit_sha,
              public_url: deployment.public_url
            )
          else
            err = result_hash[:error] || "unknown deploy error"
            deployment.update!(
              status: "failed",
              last_error: err
            )
            failure(err, deployment_id: deployment.id)
          end
        end

        # Slice A's `System::CodeDeployService` is contracted to return a
        # plain hash `{ success:, commit_sha:, public_url:, error? }`,
        # but we also accept the existing `System::Runtime::Result`
        # struct (used elsewhere in the system extension) so the
        # executor stays portable.
        def normalize_result(result)
          return result if result.is_a?(Hash)
          return nil unless result

          if result.respond_to?(:success?)
            data = result.respond_to?(:data) ? (result.data || {}) : {}
            {
              success: result.success?,
              commit_sha: data[:commit_sha] || data["commit_sha"],
              public_url: data[:public_url] || data["public_url"],
              error: result.respond_to?(:error) ? result.error : nil
            }
          else
            { success: false, error: "unexpected result shape from CodeDeployService" }
          end
        end

        def resolve_deploy_key(deploy_key_id)
          return nil if deploy_key_id.blank?

          # CodeDeployService is the source of truth for deploy-key
          # resolution; we forward the id and let it fetch from Vault.
          # Surfaced as a string here to keep the executor's surface
          # minimal — the service may also accept an opaque object in
          # the future.
          deploy_key_id.to_s
        end

        # Cross-slice contract: Slice A's `System::CodeDeployService`
        # exposes `.tear_down(node_instance:)` for the rollback path —
        # stops + disables the powernode-app systemd unit, clears
        # `/opt/app`, returns `{success:, error?}` (or a Result struct).
        def tear_down_on_node(node_instance)
          result = ::System::CodeDeployService.tear_down(node_instance: node_instance)
          normalize_tear_down(result)
        rescue StandardError => e
          { success: false, error: e.message }
        end

        def normalize_tear_down(result)
          return result if result.is_a?(Hash)
          return { success: true, error: nil } unless result

          if result.respond_to?(:success?)
            { success: result.success?, error: result.respond_to?(:error) ? result.error : nil }
          else
            { success: true, error: nil }
          end
        end

        def build_plan(node_instance, repo_url, branch, start_command, deploy_key_id)
          [
            { step: "create_deployment_record", node_instance_id: node_instance.id, repo_url: repo_url, branch: branch },
            { step: "code_deploy_service",
              node_instance_id: node_instance.id,
              repo_url: repo_url,
              branch: branch,
              start_command: start_command,
              uses_deploy_key: deploy_key_id.present? }
          ]
        end

        def failure(msg, **extra)
          { success: false, error: msg }.merge(extra)
        end
      end
    end
  end
end
