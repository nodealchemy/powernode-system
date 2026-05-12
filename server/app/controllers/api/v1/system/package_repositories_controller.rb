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
        before_action :set_repository, only: %i[show update destroy sync stale_links clean_stale_links link_platform unlink_platform]

        def index
          require_permission("system.package_repositories.view")
          repos = ::System::PackageRepository.accessible_to(@account).enabled
          repos = repos.where(kind: params[:kind]) if params[:kind].present?
          # Multi-platform filter: any-match on linked platforms via the
          # join table. Accepts a single id (legacy ?node_platform_id=X) or
          # an array (?node_platform_ids[]=A&node_platform_ids[]=B).
          platform_ids = Array(params[:node_platform_ids]).presence ||
                         Array(params[:node_platform_id]).presence
          if platform_ids.any?
            repos = repos.joins(:package_repository_platforms)
                         .where(system_package_repository_platforms: { node_platform_id: platform_ids })
                         .distinct
          end
          repos = repos.includes(:node_platforms).order(:name)
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

          attrs, platform_ids = repository_attrs_and_platform_ids
          repo = ::System::PackageRepository.new(attrs)
          repo.created_by = current_user
          repo.account = @account if intended_visibility == "account"
          repo.account = nil      if intended_visibility == "shared"

          ::System::PackageRepository.transaction do
            repo.save!
            sync_platform_links!(repo, platform_ids) unless platform_ids.nil?
          end
          render_success(package_repository: serialize(repo, detail: true), status: :created)
        rescue ActiveRecord::RecordInvalid => e
          render_validation_error(e.record)
        end

        def update
          if @repository.shared?
            require_permission("system.package_repositories.manage_shared")
          else
            require_permission("system.package_repositories.update")
            return render_error("Forbidden", status: :forbidden) if @repository.account_id != @account.id
          end

          attrs, platform_ids = repository_attrs_and_platform_ids
          ::System::PackageRepository.transaction do
            @repository.update!(attrs)
            sync_platform_links!(@repository, platform_ids) unless platform_ids.nil?
          end
          render_success(package_repository: serialize(@repository, detail: true))
        rescue ActiveRecord::RecordInvalid => e
          render_validation_error(e.record)
        end

        # POST /api/v1/system/package_repositories/:id/link_platform
        # Body: { node_platform_id: "<uuid>" }
        def link_platform
          authorize_repo_mutation!
          platform = ::System::NodePlatform.find_by(id: params[:node_platform_id])
          return render_not_found("Node Platform") unless platform

          link = @repository.package_repository_platforms.find_or_initialize_by(node_platform: platform)
          if link.save
            render_success(
              package_repository_id: @repository.id,
              node_platform_id: platform.id,
              linked: true
            )
          else
            render_validation_error(link)
          end
        end

        # DELETE /api/v1/system/package_repositories/:id/unlink_platform
        # Body: { node_platform_id: "<uuid>" }
        def unlink_platform
          authorize_repo_mutation!
          link = @repository.package_repository_platforms
                            .find_by(node_platform_id: params[:node_platform_id])
          return render_not_found("Repository ↔ Platform link") unless link

          link.destroy!
          render_success(
            package_repository_id: @repository.id,
            node_platform_id: params[:node_platform_id],
            linked: false
          )
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

        # GET /api/v1/system/package_repositories/:id/stale_links
        # Lists "stale" PackageModuleLink rows — transitive links whose
        # NodeModule is no longer referenced by any template or assignment.
        # Operators use this to audit cruft before destroying a repo (the
        # destroy FK constraint is on_delete: :restrict and fails when
        # any link exists).
        def stale_links
          require_permission("system.package_repositories.view")

          stale = ::System::PackageRepositoryStaleLinkService
                    .find_stale(repository: @repository)
                    .includes(:node_module).to_a

          render_success(
            package_repository_id: @repository.id,
            stale_count: stale.size,
            stale_links: stale.map { |link|
              {
                id: link.id,
                package_name: link.package_name,
                package_version: link.package_version,
                architecture: link.architecture,
                node_module_id: link.node_module_id,
                node_module_name: link.node_module&.name,
                last_synced_at: link.last_synced_at
              }
            }
          )
        end

        # POST /api/v1/system/package_repositories/:id/clean_stale_links
        # Body: { force: bool, dry_run: bool }
        # Destroys the stale links + their auto-generated NodeModules
        # (cascade hits links, versions, module_artifacts). force defaults
        # to false — without force the call is treated as dry_run.
        def clean_stale_links
          require_permission("system.package_repositories.delete")

          force   = ActiveModel::Type::Boolean.new.cast(params[:force])
          dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run])

          result = ::System::PackageRepositoryStaleLinkService.clean!(
            repository: @repository, force: force, dry_run: dry_run
          )

          render_success(
            package_repository_id: @repository.id,
            destroyed: result.destroyed,
            kept: result.kept,
            dry_run: result.dry_run
          )
        end

        private

        def set_repository
          @repository = ::System::PackageRepository.accessible_to(@account).find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Package Repository")
        end

        # Splits out node_platform_ids[] from the rest of the payload so
        # we can assign it AFTER save (the M:N association lives in a
        # join table; ActiveRecord can't set it from `new(attrs)` until
        # the parent has a persisted id).
        def repository_attrs_and_platform_ids
          permitted = params.require(:package_repository).permit(
            :name, :description, :kind, :visibility, :base_url,
            :signing_key_armor, :vault_credential_path,
            :priority, :enabled,
            architectures: [],
            apt_config: {},
            rpm_config: {},
            node_platform_ids: []
          )
          platform_ids = permitted.key?(:node_platform_ids) ? Array(permitted.delete(:node_platform_ids)) : nil
          [permitted, platform_ids]
        end

        # Reconciles the repo's linked platforms to match the given id
        # list — adds new links, removes ones that disappeared. Bubbles
        # the cross-account validation error up through RecordInvalid.
        def sync_platform_links!(repo, platform_ids)
          ids = platform_ids.compact.map(&:to_s).uniq
          current = repo.package_repository_platforms.pluck(:node_platform_id).map(&:to_s)
          to_add    = ids - current
          to_remove = current - ids

          to_add.each do |pid|
            repo.package_repository_platforms.create!(node_platform_id: pid)
          end
          if to_remove.any?
            repo.package_repository_platforms.where(node_platform_id: to_remove).destroy_all
          end
        end

        def authorize_repo_mutation!
          if @repository.shared?
            require_permission("system.package_repositories.manage_shared")
          else
            require_permission("system.package_repositories.update")
            if @repository.account_id != @account.id
              render_error("Forbidden", status: :forbidden) and return
            end
          end
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
            node_platform_ids: repo.node_platforms.map(&:id),
            created_at:   repo.created_at,
            updated_at:   repo.updated_at
          }
          if detail
            base[:apt_config] = repo.apt_config
            base[:rpm_config] = repo.rpm_config
            base[:has_signing_key] = repo.signing_key_armor.present?
            base[:node_platforms] = repo.node_platforms.map { |p| { id: p.id, name: p.name } }
          end
          base
        end
      end
    end
  end
end
