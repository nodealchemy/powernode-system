# frozen_string_literal: true

class SeedPackageRepositoryPermissions < ActiveRecord::Migration[8.0]
  PERMISSIONS = [
    # Repository CRUD + sync (account-scoped repositories)
    ["system.package_repositories.view",   "View accessible package repositories (own account + shared)"],
    ["system.package_repositories.create", "Register a new account-scoped apt/rpm repository"],
    ["system.package_repositories.update", "Update an account-scoped package repository"],
    ["system.package_repositories.delete", "Delete an account-scoped package repository"],
    ["system.package_repositories.sync",   "Trigger a manual sync of upstream apt/rpm index"],

    # Shared-repository management (system-wide, account_id IS NULL)
    ["system.package_repositories.manage_shared",
     "Create/edit/delete shared (system-wide) package repositories — typically platform-admin only"],

    # Package browsing
    ["system.packages.view",   "View individual package metadata"],
    ["system.packages.search", "Search the synced package catalog"],

    # Package-module materialization + provenance
    ["system.package_modules.view",
     "View PackageModuleLink records (audit trail for which modules came from which packages)"],
    ["system.package_modules.create",
     "Materialize an apt/rpm package + closure into NodeModule rows and dispatch CI build"],
    ["system.package_modules.refresh",
     "Re-materialize a package-sourced NodeModule when upstream version drifts"]
  ].freeze

  def up
    PERMISSIONS.each do |(name, desc)|
      ::Permission.find_or_create_by!(name: name) do |p|
        p.description = desc
      end
    end
  end

  def down
    ::Permission.where(name: PERMISSIONS.map(&:first)).destroy_all
  end
end
