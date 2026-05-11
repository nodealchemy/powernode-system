# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Chains the full CVE response loop:
      #   1. CveResponseExecutor: triage the CVE, enumerate exposed modules,
      #      compute risk score, build remediation plan.
      #   2. For each affected module with a PackageModuleLink: dispatch
      #      PackageModuleRefreshExecutor so the upstream-patched version
      #      gets materialized into a new NodeModuleVersion.
      #   3. For each affected module that ALREADY has a blessed version
      #      newer than current_version: dispatch RollingModuleUpgradeExecutor
      #      (one plan per template) so the patch reaches running instances.
      #   4. Mark every named CveExposure as `remediating` so the dashboard
      #      reflects in-flight response and the sensor doesn't re-fire.
      #
      # Idempotency:
      #   - Keyed on (cve_id, node_module_id). Re-invocation for the same
      #     pair within the DecisionEngine's dedup TTL is a no-op (skipped
      #     by the engine before this executor is called).
      #   - Beyond the dedup window, the dispatched refresh job is itself
      #     idempotent (last_synced_at gate) and the rolling upgrade is
      #     guarded by the autonomy approval flow.
      #
      # Why this exists (separate from CveResponseExecutor):
      #   CveResponseExecutor is a *planner* — it returns a plan but doesn't
      #   dispatch. This orchestrator turns the plan into concrete operations
      #   for the CVE Responder agent's `notify_and_proceed` autonomy path.
      #   The planner remains usable by Concierge for runbook generation and
      #   by humans for triage without side-effects.
      class CveRemediationOrchestrationExecutor
        def self.descriptor
          {
            name: "cve_remediation_orchestration",
            description: "Orchestrate the full CVE → exposure → rebuild → rolling-upgrade chain for one CVE",
            category: "security",
            inputs: {
              cve_id: { type: "string", required: true,
                        description: "Canonical CVE id, e.g. CVE-2026-12345" },
              severity: { type: "string", required: false,
                          description: "critical|high|medium|low. Defaults to the persisted Cve.severity" },
              affected_module_ids: { type: "array", required: false,
                                     description: "Optional pre-resolved list of module ids — when omitted, derived from CveExposure rows" },
              exposure_ids: { type: "array", required: false,
                              description: "Optional list of CveExposure ids to transition to remediating" }
            },
            outputs: {
              cve_id: :string,
              triage: :object,
              refresh_dispatches: [ :object ],
              rolling_upgrade_plans: [ :object ],
              exposures_remediating: :integer,
              skipped_reason: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(cve_id:, severity: nil, affected_module_ids: nil, exposure_ids: nil)
          cve = ::System::Cve.find_by(cve_id: cve_id) if defined?(::System::Cve)
          return failure("cve not found: #{cve_id}") unless cve

          severity_norm = (severity || cve.severity).to_s.downcase
          packages = cve.normalized_affected_packages

          triage_executor = ::System::Ai::Skills::CveResponseExecutor.new(
            account: @account, agent: @agent, user: @user
          )
          triage = triage_executor.execute(
            cve_id: cve_id,
            severity: severity_norm,
            affected_packages: packages.empty? ? [ { name: cve_id } ] : packages,
            summary: cve.summary
          )

          unless triage[:success]
            return failure("triage failed: #{triage[:error]}")
          end

          triage_data = triage[:data] || {}
          resolved_module_ids = resolve_module_ids(affected_module_ids, triage_data)

          refresh_dispatches = dispatch_refreshes(resolved_module_ids)
          rolling_upgrade_plans = plan_rolling_upgrades(resolved_module_ids)
          remediating_count = transition_exposures(cve, exposure_ids, resolved_module_ids)

          success(
            cve_id: cve_id,
            severity: severity_norm,
            triage: {
              risk_score: triage_data[:risk_score],
              exposed_modules: triage_data[:exposed_modules],
              exposed_instance_count: triage_data[:exposed_instance_count],
              requires_approval: triage_data[:requires_approval]
            },
            refresh_dispatches: refresh_dispatches,
            rolling_upgrade_plans: rolling_upgrade_plans,
            exposures_remediating: remediating_count
          )
        rescue StandardError => e
          Rails.logger.error("[CveRemediationOrchestrationExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        attr_reader :account

        def resolve_module_ids(explicit_ids, triage_data)
          return Array(explicit_ids).map(&:to_s).uniq if explicit_ids.present?

          Array(triage_data[:exposed_modules]).filter_map { |m| m[:module_id]&.to_s }.uniq
        end

        def dispatch_refreshes(module_ids)
          return [] if module_ids.empty?

          refresh_executor = ::System::Ai::Skills::PackageModuleRefreshExecutor.new(
            account: account, agent: @agent, user: @user
          )

          links = ::System::PackageModuleLink
            .joins(:node_module)
            .where(system_node_modules: { account_id: account.id, id: module_ids })

          links.map do |link|
            result = refresh_executor.execute(package_module_link_id: link.id)
            {
              node_module_id: link.node_module_id,
              package_module_link_id: link.id,
              ok: result[:success] == true,
              error: result[:error]
            }
          end
        end

        def plan_rolling_upgrades(module_ids)
          return [] if module_ids.empty?

          rolling_executor = ::System::Ai::Skills::RollingModuleUpgradeExecutor.new(
            account: account, agent: @agent, user: @user
          )

          plans = []
          ::System::NodeModule
            .where(account: account, id: module_ids)
            .includes(versions: :module_artifacts)
            .find_each do |mod|
              blessed = newer_blessed_version_for(mod)
              next unless blessed

              templates_for(mod).each do |template_id|
                plan = rolling_executor.execute(
                  template_id: template_id,
                  module_id: mod.id,
                  target_version_id: blessed.id
                )
                plans << {
                  node_module_id: mod.id,
                  template_id: template_id,
                  target_version_id: blessed.id,
                  ok: plan[:success] == true,
                  batch_count: plan.dig(:data, :batch_count),
                  total_instances: plan.dig(:data, :total_instances),
                  error: plan[:error]
                }
              end
            end

          plans
        end

        def newer_blessed_version_for(mod)
          return nil unless mod.current_version_id

          mod.versions
             .where(promotion_state: %w[blessed live])
             .where.not(id: mod.current_version_id)
             .order(created_at: :desc)
             .first
        end

        def templates_for(mod)
          ::System::NodeModuleAssignment
            .joins(node: :node_template)
            .where(node_module_id: mod.id)
            .where(enabled: true)
            .distinct
            .pluck("system_node_templates.id")
        end

        def transition_exposures(cve, explicit_ids, module_ids)
          scope = ::System::CveExposure.unresolved.where(cve: cve)
          scope = if explicit_ids.present?
                    scope.where(id: explicit_ids)
                  elsif module_ids.present?
                    scope.joins(node_module_version: :node_module)
                         .where(system_node_modules: { id: module_ids })
                  else
                    scope
                  end

          scope.find_each.count do |exposure|
            exposure.update!(state: "remediating") if exposure.state == "open"
          end
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
