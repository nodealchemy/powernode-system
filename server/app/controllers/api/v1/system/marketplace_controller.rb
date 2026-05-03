# frozen_string_literal: true

module Api
  module V1
    module System
      # Browse-side Module Marketplace. Returns NodeModule rows with trust
      # tier badges + recent version metadata. Operators "install" by
      # selecting a module + adding it to a Template via the Composer.
      #
      # Permission: `system.modules.read` (no new permission).
      # Submission/review queue is out of scope (Track E M-MK-1/2).
      #
      # Reference: comprehensive stabilization sweep P7.2.
      class MarketplaceController < BaseController
        before_action :set_account

        # GET /api/v1/system/marketplace
        # Filters: trust_tier, category, search (name + description)
        # Note: trust_tier filter is applied in Ruby because manifest_yaml
        # is a text column (raw YAML), not JSONB. Acceptable performance
        # because the result set is bounded by per-account modules.
        def index
          require_permission("system.modules.read")

          scope = @account.system_node_modules
                          .includes(:category, :node_platform)

          if (category_id = params[:category_id]).present?
            scope = scope.where(category_id: category_id)
          end

          if (q = params[:search]).present?
            scope = scope.where("name ILIKE ? OR description ILIKE ?", "%#{q}%", "%#{q}%")
          end

          modules = scope.order(:name).to_a

          if (tier = params[:trust_tier]).present?
            modules = modules.select { |m| m.manifest_trust_tier == tier }
          end

          paginated = paginate_array(modules)
          render_success(
            modules: paginated[:items].map { |m| serialize_card(m) },
            meta: paginated[:meta]
          )
        end

        # GET /api/v1/system/marketplace/:id
        # Returns the full module manifest, recent versions, and dependency
        # tree. Powers the Marketplace detail modal.
        def show
          require_permission("system.modules.read")
          mod = @account.system_node_modules
                        .includes(:category, :node_platform, :module_dependencies)
                        .find(params[:id])

          render_success(
            module: serialize_full(mod),
            recent_versions: recent_versions(mod),
            dependencies: serialize_dependencies(mod)
          )
        rescue ActiveRecord::RecordNotFound
          render_not_found("Module")
        end

        private

        # Manual array pagination. Avoids the bare paginate() helper that
        # relies on AR scopes — we have to materialize + Ruby-filter for
        # trust_tier before paginating since manifest_yaml is text.
        def paginate_array(array)
          page = (params[:page] || 1).to_i.clamp(1, 10_000)
          per_page = (params[:per_page] || 50).to_i.clamp(1, 200)
          offset = (page - 1) * per_page
          slice = array[offset, per_page] || []
          total_count = array.size
          {
            items: slice,
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count.to_f / per_page).ceil
            }
          }
        end

        # Compact card representation for the catalog grid.
        def serialize_card(mod)
          {
            id: mod.id,
            name: mod.name,
            description: mod.description,
            variety: mod.variety,
            priority: mod.priority,
            trust_tier: mod.manifest_trust_tier,
            category: mod.category&.name,
            platform: mod.node_platform&.name,
            current_version_number: mod.current_version_number,
            assignment_count: mod.node_module_assignments.count,
            updated_at: mod.updated_at
          }
        end

        # Detail representation including manifest + skill declarations.
        def serialize_full(mod)
          serialize_card(mod).merge(
            manifest_yaml: mod.manifest_yaml,
            file_spec: mod.file_spec,
            mask: mod.mask,
            package_spec: mod.package_spec,
            dependency_spec: mod.dependency_spec,
            protected_spec: mod.protected_spec,
            consent_budget_per_day: mod.consent_budget_per_day,
            cosign_identity_regexp: mod.cosign_identity_regexp,
            cosign_issuer_regexp: mod.cosign_issuer_regexp,
            gitea_repo_full_name: mod.gitea_repo_full_name
          )
        end

        def recent_versions(mod)
          ::System::NodeModuleVersion
            .where(node_module: mod)
            .order(version_number: :desc)
            .limit(10)
            .map do |v|
              {
                id: v.id,
                version_number: v.version_number,
                changelog: v.changelog,
                created_at: v.created_at
              }
            end
        end

        def serialize_dependencies(mod)
          mod.module_dependencies.map do |dep|
            {
              id: dep.id,
              required_module_id: dep.required_module_id,
              required_module_name: dep.required_module&.name,
              required_version: dep.required_version
            }
          end
        end
      end
    end
  end
end
