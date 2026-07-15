# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Post-build smoke check (campaign 019f6084 inc2 §4.3.3) — composes a
      # newly-built module + base-os on a pooled instance and asserts it's
      # actually healthy. The post-build smoke inc3's fulfill flow (and the
      # git dogfood) calls once a ModuleBuildBatch reaches a terminal state,
      # before the module is trusted for on-demand template assembly.
      #
      # Read-shape: requires_approval defaults false (skill_descriptor
      # default) — this executor claims + releases an ephemeral pooled
      # instance and re-applies template modules, but makes no lasting
      # platform-config change an operator would need to approve.
      #
      # Orchestration is REAL: acquiring a pooled instance
      # (InstancePoolService.acquire!), composing the template pairing
      # (System::TemplateModule joins + a queued sync_modules Task), and
      # releasing the instance back to its pool are all ordinary DB/service
      # calls. Only the actual health probe is PARKED — see
      # System::ModuleSmokeProbe's class doc for why — and is mocked
      # entirely in this executor's spec.
      class ModuleSmokeVerifyExecutor < BaseSkillExecutor
        DEFAULT_BASE_OS_MODULE_NAME = "base-os-ubuntu-noble"

        skill_descriptor(
          name: "module_smoke_verify",
          description: "Compose a newly-built module onto a pooled instance atop base-os and assert it's healthy " \
                       "(systemd unit active, manifest health endpoint answers, ldd closure complete)",
          category: "devops",
          inputs: {
            module_name: { type: "string", required: false,
                           description: "NodeModule name to smoke-verify (module_name or module_id required)" },
            module_id: { type: "string", required: false,
                        description: "NodeModule id to smoke-verify (module_name or module_id required)" },
            base_os_module_name: { type: "string", required: false, default: DEFAULT_BASE_OS_MODULE_NAME,
                                   description: "Base-os module composed alongside the target module" },
            template_id: { type: "string", required: false,
                          description: "Existing NodeTemplate to reuse instead of the acquired instance's own template" }
          },
          outputs: {
            ok: :boolean,
            module_name: :string,
            base_os_module_name: :string,
            instance_id: :string,
            template_id: :string,
            checks: [ :object ]
          }
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(module_name: nil, module_id: nil, base_os_module_name: DEFAULT_BASE_OS_MODULE_NAME,
                    template_id: nil, **_extras)
          return failure("module_name or module_id is required") if module_name.blank? && module_id.blank?

          node_module = resolve_module(module_name: module_name, module_id: module_id)
          return failure("module not found: #{module_name || module_id}") unless node_module

          base_os_module = @account.system_node_modules.find_by(name: base_os_module_name)
          return failure("base-os module not found: #{base_os_module_name}") unless base_os_module

          begin
            instance = ::System::InstancePoolService.acquire!(account: @account)
          rescue ::System::InstancePoolService::NoReadyMembersError => e
            return failure("no ready pool members: #{e.message}")
          rescue ::System::InstancePoolService::PoolError => e
            return failure(e.message)
          end

          begin
            run_smoke(instance: instance, node_module: node_module, base_os_module: base_os_module,
                      template_id: template_id)
          ensure
            release_pooled_instance(instance)
          end
        end

        private

        def resolve_module(module_name:, module_id:)
          return @account.system_node_modules.find_by(id: module_id) if module_id.present?

          @account.system_node_modules.find_by(name: module_name)
        end

        def run_smoke(instance:, node_module:, base_os_module:, template_id:)
          template = resolve_template(instance: instance, template_id: template_id)
          return failure("template not found: #{template_id || "instance #{instance.id} has no node_template"}") unless template

          compose_pairing!(template: template, node_module: node_module, base_os_module: base_os_module, instance: instance)

          report = ::System::ModuleSmokeProbe.run(
            instance: instance, node_module: node_module, base_os_module_name: base_os_module.name
          )

          success(
            ok: report.ok?,
            module_name: node_module.name,
            base_os_module_name: base_os_module.name,
            instance_id: instance.id,
            template_id: template.id,
            checks: report.checks.map { |c| { name: c.name, pass: c.pass, detail: c.detail } }
          )
        rescue ActiveRecord::RecordInvalid => e
          failure("compose failed: #{e.message}")
        end

        # template_id, when given, is trusted as already-composed (caller's
        # responsibility) — this only READS it. Otherwise falls back to the
        # acquired instance's own node's template, onto which the pairing is
        # composed below.
        def resolve_template(instance:, template_id:)
          return @account.system_node_templates.find_by(id: template_id) if template_id.present?

          instance.node&.node_template
        end

        # Ensures `template` carries both modules, then queues a sync_modules
        # Task so the on-node agent re-applies the (possibly just-widened)
        # template to the live instance — the same mechanism
        # system_refresh_instance_modules uses.
        def compose_pairing!(template:, node_module:, base_os_module:, instance:)
          [ base_os_module, node_module ].each do |node_mod|
            ::System::TemplateModule.find_or_create_by!(node_template: template, node_module: node_mod)
          end

          ::System::Task.create!(
            account: @account, operable: instance, command: "sync_modules", status: "pending",
            options: { "source" => "module_smoke_verify", "module" => node_module.name }
          )
        end

        def release_pooled_instance(instance)
          return unless instance.is_a?(::System::NodeInstance)
          return unless instance.respond_to?(:pool_claimed?) && instance.pool_claimed?

          ::System::InstancePoolService.release!(instance: instance, pool: instance.instance_pool)
        rescue StandardError => e
          Rails.logger.warn(
            "[ModuleSmokeVerifyExecutor] pool release failed (instance=#{instance.id}): #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
