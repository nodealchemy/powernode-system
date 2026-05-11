# frozen_string_literal: true

module System
  # Identifies and (optionally) cleans up "stale" PackageModuleLink rows
  # for a PackageRepository. The use case: operators trying to delete a
  # repo run into the `on_delete: :restrict` FK constraint when ANY
  # PackageModuleLink references it, even links pointing at long-dead
  # transitive modules.
  #
  # Stale link definition (conservative):
  #   - link.auto_generated = true (transitive, created by the package
  #     materializer rather than chosen by the operator)
  #   - link's NodeModule has zero TemplateModule references
  #   - link's NodeModule has zero NodeModuleAssignment references
  #
  # Operator-chosen links (auto_generated=false) are NEVER returned as
  # stale — those represent an explicit subscription the operator may
  # have temporarily disabled. Likewise, transitive links whose NodeModule
  # is still referenced anywhere are kept (something still uses them).
  #
  # Cleaning destroys the linked NodeModule which cascades to the link,
  # its versions, and its module_artifacts.
  class PackageRepositoryStaleLinkService
    Result = Struct.new(:ok, :destroyed, :kept, :dry_run, keyword_init: true) do
      alias_method :ok?, :ok
    end

    def self.find_stale(repository:)
      ::System::PackageModuleLink
        .joins(:node_module)
        .where(package_repository: repository, auto_generated: true)
        .where(<<~SQL.squish)
          NOT EXISTS (
            SELECT 1 FROM system_template_modules
             WHERE node_module_id = system_node_modules.id
          )
        SQL
        .where(<<~SQL.squish)
          NOT EXISTS (
            SELECT 1 FROM system_node_module_assignments
             WHERE node_module_id = system_node_modules.id
          )
        SQL
    end

    def self.clean!(repository:, force: false, dry_run: false)
      stale = find_stale(repository: repository).includes(:node_module).to_a

      if dry_run
        return Result.new(ok: true, destroyed: 0, kept: stale.size, dry_run: true)
      end

      unless force
        # Default to dry_run if force isn't passed — prevents accidental
        # cascade destroys.
        return Result.new(ok: true, destroyed: 0, kept: stale.size, dry_run: true)
      end

      destroyed = 0
      ActiveRecord::Base.transaction do
        stale.each do |link|
          link.node_module.destroy! if link.node_module  # cascades the link
          destroyed += 1
        end
      end

      Result.new(ok: true, destroyed: destroyed, kept: 0, dry_run: false)
    end
  end
end
