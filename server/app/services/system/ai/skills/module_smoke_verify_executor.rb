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

        # Raised when the pairing this executor is about to compose would
        # introduce an error-severity composition conflict. See
        # #compose_pairing!.
        class CompositionConflictError < StandardError; end

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
                          description: "Existing NodeTemplate to reuse instead of the acquired instance's own template" },
            instance_id: { type: "string", required: false,
                          description: "Verify THIS already-provisioned instance in place (caller-owned: not acquired from a pool, not released/terminated). " \
                                       "Omit to self-acquire an ephemeral pool member for a standalone smoke (which IS released afterward)." }
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

        binds_to "Fleet Autonomy", "concierge"

        protected

        def perform(module_name: nil, module_id: nil, base_os_module_name: DEFAULT_BASE_OS_MODULE_NAME,
                    template_id: nil, instance_id: nil, **_extras)
          return failure("module_name or module_id is required") if module_name.blank? && module_id.blank?

          node_module = resolve_module(module_name: module_name, module_id: module_id)
          return failure("module not found: #{module_name || module_id}") unless node_module

          base_os_module = @account.system_node_modules.find_by(name: base_os_module_name)
          return failure("base-os module not found: #{base_os_module_name}") unless base_os_module

          if instance_id.present?
            # Caller-owned path (e.g. fulfill's leased instance): verify THAT
            # instance in place. NEVER acquire a second pool member, NEVER
            # release/terminate the caller's instance — its lifecycle belongs
            # to the caller.
            instance = ::System::NodeInstance.where(account_id: @account.id).find_by(id: instance_id)
            return failure("instance not found: #{instance_id}") unless instance

            run_smoke(instance: instance, node_module: node_module, base_os_module: base_os_module,
                      template_id: template_id, caller_owned: true)
          else
            # Standalone path: self-acquire an ephemeral pool member and release
            # it afterward.
            begin
              instance = ::System::InstancePoolService.acquire!(account: @account)
            rescue ::System::InstancePoolService::NoReadyMembersError => e
              return failure("no ready pool members: #{e.message}")
            rescue ::System::InstancePoolService::PoolError => e
              return failure(e.message)
            end

            begin
              run_smoke(instance: instance, node_module: node_module, base_os_module: base_os_module,
                        template_id: template_id, caller_owned: false)
            ensure
              release_pooled_instance(instance)
            end
          end
        end

        private

        def resolve_module(module_name:, module_id:)
          return @account.system_node_modules.find_by(id: module_id) if module_id.present?

          @account.system_node_modules.find_by(name: module_name)
        end

        def run_smoke(instance:, node_module:, base_os_module:, template_id:, caller_owned:)
          # An EXPLICIT template_id is the caller's dedicated template (e.g.
          # fulfill's freshly-authored NEW template) — trusted as already
          # composed, so anything we add to it stays. Without a template_id we
          # fall back to the acquired instance's OWN (pool/shared) template,
          # which must NEVER be permanently widened by a transient smoke — so we
          # compose the pairing, probe, then remove exactly the pairings we
          # added (leaving the shared template untouched for the next member).
          explicit_template = template_id.present?
          template = resolve_template(instance: instance, template_id: template_id)
          return failure("template not found: #{template_id || "instance #{instance.id} has no node_template"}") unless template

          created_pairings = compose_pairing!(
            template: template, node_module: node_module, base_os_module: base_os_module, instance: instance
          )

          begin
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
          ensure
            # Only tear down transient widening of a shared/pool template. A
            # caller-supplied template is dedicated (its modules must persist).
            created_pairings.each(&:destroy) unless explicit_template
          end
        rescue ActiveRecord::RecordInvalid => e
          failure("compose failed: #{e.message}")
        rescue CompositionConflictError => e
          failure(e.message)
        end

        # template_id, when given, is trusted as already-composed (caller's
        # responsibility) — this only READS it. Otherwise falls back to the
        # acquired instance's own node's template, onto which the pairing is
        # composed below.
        def resolve_template(instance:, template_id:)
          return @account.system_node_templates.find_by(id: template_id) if template_id.present?

          instance.node&.node_template
        end

        # Ensures `template` carries both modules, then — only when it actually
        # widened the template — queues a sync_modules Task so the on-node agent
        # applies the just-widened template to the live instance (the same
        # mechanism system_refresh_instance_modules uses). Returns the
        # TemplateModule rows it CREATED (so a transient smoke can tear exactly
        # those down); pre-existing pairings are left in the return empty, so a
        # dedicated template that already carries both modules is a no-op.
        #
        # Refuses a pairing that would introduce an error-severity composition
        # conflict. This is authoring: on the fulfill path (explicit
        # template_id) the joins PERSIST and become the new template's
        # permanent baseline, which the delta guard on the assignment paths
        # then treats as acceptable forever after; on the pool path they are
        # transient but still queue a sync_modules Task against a live shared
        # template. Either way a conflicting pairing composes something the
        # build cannot produce, so the probe would be reporting on the wrong
        # artifact. Both modules are judged TOGETHER — checked one at a time,
        # a collision between the pair itself would slip through, since
        # neither is in the other's baseline.
        def compose_pairing!(template:, node_module:, base_os_module:, instance:)
          # .uniq: smoking a base-os build pairs it with itself by default
          # (module_name == base_os_module_name), so base_os_module and
          # node_module resolve to the same record — without this the pair
          # would be created twice and the second create! would raise on the
          # (node_template, node_module) uniqueness constraint.
          pending = [ base_os_module, node_module ].uniq.reject do |node_mod|
            ::System::TemplateModule.exists?(node_template: template, node_module: node_mod)
          end

          if pending.any?
            verdict = ::System::TemplateCompositionAnalysis
                      .new(@account)
                      .additions_verdict(template: template, node_modules: pending)
            raise CompositionConflictError, verdict.message if verdict.blocked?
          end

          # Transactional: a create! failing partway through (e.g. a
          # concurrent widening racing this one) must not leave an earlier
          # join committed with no way back to the caller's ensure-teardown —
          # compose_pairing! raises before returning, so `created_pairings`
          # in run_smoke never gets assigned on that path.
          created = ::System::TemplateModule.transaction do
            pending.map do |node_mod|
              ::System::TemplateModule.create!(node_template: template, node_module: node_mod)
            end
          end

          if created.any?
            ::System::Task.create!(
              account: @account, operable: instance, command: "sync_modules", status: "pending",
              options: { "source" => "module_smoke_verify", "module" => node_module.name }
            )
          end

          created
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
