# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator CRUD + manual-sync for apt/rpm package repositories.
      # Permission gates:
      #   - system.package_repositories.view
      #   - system.package_repositories.create
      #   - system.package_repositories.update
      #   - system.package_repositories.delete
      #   - system.package_repositories.sync
      #   - system.package_repositories.manage_shared (required for shared repos)
      class PackageRepositoriesController < BaseController
        before_action :set_account
        before_action :set_repository, only: %i[show update destroy sync]

        def index
          require_permission("system.package_repositories.view")
          repos = ::System::PackageRepository.accessible_to(@account).enabled
          repos = repos.where(kind: params[:kind]) if params[:kind].present?
          repos = repos.where(node_platform_id: params[:node_platform_id]) if params[:node_platform_id].present?
          repos = repos.order(:name)
          render_success(
            package_repositories: repos.map { |r| serialize(r) },
            meta: { total: repos.size }
          )
        end

        def show
          require_permission("system.package_repositories.view")
          render_success(
            package_repository: serialize(@repository, detail: true),
            recent_packages_count: ::System::Package.live.where(package_repository: @repository).count
          )
        end

        def create
          # Permission depends on whether this is a shared or account-scoped repo
          intended_visibility = params.dig(:package_repository, :visibility) || "account"
          if intended_visibility == "shared"
            require_permission("system.package_repositories.manage_shared")
          else
            require_permission("system.package_repositories.create")
          end

          repo = ::System::PackageRepository.new(repository_params)
          repo.created_by = current_user
          repo.account = @account if intended_visibility == "account"
          repo.account = nil      if intended_visibility == "shared"

          if repo.save
            render_success(package_repository: serialize(repo), status: :created)
          else
            render_validation_error(repo)
          end
        end

        def update
          if @repository.shared?
            require_permission("system.package_repositories.manage_shared")
          else
            require_permission("system.package_repositories.update")
            return render_error("Forbidden", status: :forbidden) if @repository.account_id != @account.id
          end

          if @repository.update(repository_params)
            render_success(package_repository: serialize(@repository))
          else
            render_validation_error(@repository)
          end
        end

        def destroy
          if @repository.shared?
            require_permission("system.package_repositories.manage_shared")
          else
            require_permission("system.package_repositories.delete")
            return render_error("Forbidden", status: :forbidden) if @repository.account_id != @account.id
          end

          if @repository.destroy
            render_success(message: "Package repository deleted")
          else
            render_error("Failed to delete: #{@repository.errors.full_messages.join('; ')}",
                         status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/package_repositories/:id/sync
        def sync
          require_permission("system.package_repositories.sync")
          unless @repository.account_id.nil? || @repository.account_id == @account.id
            return render_error("Forbidden", status: :forbidden)
          end

          result = ::System::PackageRepositorySyncService.call(repository: @repository)
          render_success(
            ok:            result.success?,
            upserted:      result.upserted,
            obsoleted:     result.obsoleted,
            package_count: result.package_count,
            error:         result.error
          )
        end

        private

        def set_repository
          @repository = ::System::PackageRepository.accessible_to(@account).find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Package Repository")
        end

        def repository_params
          permitted = params.require(:package_repository).permit(
            :name, :description, :kind, :visibility, :base_url,
            :signing_key_armor, :vault_credential_path,
            :node_platform_id, :priority, :enabled,
            architectures: [],
            apt_config: {},
            rpm_config: {}
          )
          permitted
        end

        def serialize(repo, detail: false)
          base = {
            id:           repo.id,
            name:         repo.name,
            description:  repo.description,
            kind:         repo.kind,
            visibility:   repo.visibility,
            base_url:     repo.base_url,
            architectures: Array(repo.architectures),
            priority:     repo.priority,
            enabled:      repo.enabled,
            sync_status:  repo.sync_status,
            last_synced_at: repo.last_synced_at,
            last_sync_error: repo.last_sync_error,
            package_count: repo.package_count,
            shared:       repo.shared?,
            node_platform_id: repo.node_platform_id,
            created_at:   repo.created_at,
            updated_at:   repo.updated_at
          }
          if detail
            base[:apt_config] = repo.apt_config
            base[:rpm_config] = repo.rpm_config
            base[:has_signing_key] = repo.signing_key_armor.present?
          end
          base
        end
      end
    end
  end
end
