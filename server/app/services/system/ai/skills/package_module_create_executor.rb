# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for materializing a package + closure into NodeModules
      # and dispatching a CI build. REQUIRES HUMAN APPROVAL per the
      # system.package_module.create intervention policy (supply-chain
      # critical — operators audit which packages enter their fleet).
      #
      # That policy name is DECLARED below, not derived. This header has always
      # named system.package_module.create as the gate, but until
      # IMP-2effedffc990 the gate resolved the "<domain>.<skill name>" default
      # — system.package_module_create — so the comment described a row the
      # executor never read (IMP-51e5c6184ae4 found the same split on the
      # architecture executors first).
      #
      # WHAT THAT CHANGES FOR AN OPERATOR — say it plainly, because it is the
      # direction that can LOOSEN a gate. Before this release NOTHING resolved
      # system.package_module.create. This executor resolved the underscored
      # derivation, and no other door read the dotted spelling either: it has
      # no System::Fleet::DecisionEngine::SIGNAL_BINDINGS entry (the only
      # source of the action_category both FleetAutonomyService#gate_action!
      # call sites receive), and its membership in
      # System::Fleet::FleetAutonomyService::ADVANCEMENT_ACTIONS selects a 4h
      # rather than 1h approval TTL — a classifier, not a gate. So the dotted
      # row was operator-VISIBLE (the Autonomy modal lists it) but INERT, and
      # an install that loosened it believing it controlled package module
      # creation was in fact still gated: both spellings shipped at
      # require_approval, and the unmatched underscored name fell through to
      # Ai::InterventionPolicyService#default_policy, also require_approval.
      # From this release the dotted row IS the gate. The retirement migration
      # db/migrate/20260903120000_retire_underscored_package_module_autonomy_policy.rb
      # is where an operator meets that at deploy time: it reads every
      # surviving dotted row and warns when the verb is not require_approval.
      class PackageModuleCreateExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "package_module_create",
          description: "Materialize an apt/rpm package + transitive dep closure as NodeModule rows + ModuleDependency edges, then dispatch a CI build",
          category:    "devops",
          inputs: {
            repository_id:       { type: "string", required: true },
            package_name:        { type: "string", required: true },
            architectures:       { type: "array",  required: false,
                                   description: "Defaults to repository.architectures if omitted" },
            recommends_selected: { type: "array",  required: false,
                                   description: "Per-edge recommends opt-in list (defaults to none)" },
            category_id:         { type: "string", required: false }
          },
          outputs: {
            top_level_module_id:  :string,
            dependency_count:     :integer,
            recommends_count:     :integer,
            build_dispatches:     :array,
            warnings:             :array
          },
          requires_approval: true,
          # DECLARED, not derived (IMP-2effedffc990). The operator control for
          # this action already exists as the SEEDED
          # SUPPLY_CHAIN_MANAGER_POLICIES row "system.package_module.create"
          # (FLEET_AUTONOMY_POLICIES until HIER-P2DECL moved the supply-chain
          # group); the "<domain>.<skill name>"
          # default would resolve "system.package_module_create" instead, a
          # second row over the same behaviour that an operator tuning the
          # first would never touch.
          action_category: "system.package_module.create"
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(repository_id:, package_name:, architectures: nil, recommends_selected: [], category_id: nil)
          repo = ::System::PackageRepository.accessible_to(@account).find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          # When called from autonomy without a user, attribute to the account's first admin
          effective_user = @user || @account.users.where(account_id: @account.id).first
          return failure("no user available to attribute creation to") unless effective_user

          archs = Array(architectures).presence || Array(repo.architectures).presence || [ "amd64" ]
          category = category_id.present? ?
                       @account.system_node_module_categories.find_by(id: category_id) : nil

          result = ::System::PackageModuleMaterializer.call(
            repository:          repo,
            package_name:        package_name,
            architectures:       archs,
            account:             @account,
            requested_by_user:   effective_user,
            recommends_selected: Array(recommends_selected),
            category:            category,
            dispatch_build:      true
          )

          if result.success?
            success(
              top_level_module_id: result.top_level_module&.id,
              dependency_count:    result.dependency_modules.size,
              recommends_count:    result.recommends_modules.size,
              build_dispatches:    result.build_dispatches,
              warnings:            result.warnings,
              requires_approval:   true
            )
          else
            failure("Materialization failed: #{result.errors.join('; ')}")
          end
        rescue ::System::PackageModuleMaterializer::NamingConflictError => e
          failure(e.message)
        end
      end
    end
  end
end
