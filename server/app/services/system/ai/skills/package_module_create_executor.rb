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
      # WHAT THAT CHANGES FOR AN OPERATOR: the retired underscored spelling had
      # no policy row anywhere (it was declared by no set that ever shipped), so
      # this executor used to fall through to
      # Ai::InterventionPolicyService#default_policy = require_approval, whatever
      # the modal showed. It now resolves the row an operator can actually see
      # and edit — and that row is ALREADY the live gate for the same action on
      # the other door (System::Fleet::FleetAutonomyService ADVANCEMENT_ACTIONS
      # gates system.package_module.create for the fleet-autonomy path). So an
      # operator who had loosened "package module create" was already loosening
      # this behaviour there; the skill door now honours the same verdict
      # instead of gating independently. That convergence is the point of the
      # fix, and it is the direction that can LOOSEN a gate, so it is stated
      # here rather than left to be discovered.
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
          # this action already exists as the SEEDED FLEET_AUTONOMY_POLICIES
          # row "system.package_module.create"; the "<domain>.<skill name>"
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
