# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for materializing a package + closure into NodeModules
      # and dispatching a CI build. REQUIRES HUMAN APPROVAL per the
      # system.package_module.create intervention policy (supply-chain
      # critical — operators audit which packages enter their fleet).
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
          requires_approval: true
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(repository_id:, package_name:, architectures: nil, recommends_selected: [], category_id: nil)
          repo = ::System::PackageRepository.accessible_to(@account).find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          # When called from autonomy without a user, attribute to the account's first admin
          effective_user = @user || @account.users.where(account_id: @account.id).first
          return failure("no user available to attribute creation to") unless effective_user

          archs = Array(architectures).presence || Array(repo.architectures).presence || ["amd64"]
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
