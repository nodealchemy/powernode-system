# frozen_string_literal: true

# IMP-01a05afd — drop system_package_repositories.vault_credential_path.
#
# Nothing reads it. Package repository sync has no authentication seam at all
# (every index fetch is a bare Faraday GET in System::PackageAdapters::Base),
# and IMP-64854437ca43 already removed the column from the permit list, keeps
# it out of the serializer, and 422s any request that supplies a non-blank
# value. What was left was a column only a pre-guard write could have filled,
# with a value (a Vault PATH, not credential material) that no code consumes.
#
# NOT the same-named column on system_gitops_repositories, which is live: the
# GitOps sync reads its clone credentials from Vault through it.
#
# Reversible in shape only: `down` restores an empty column; any path stored
# before the drop is not recovered, and nothing read it.
class DropVaultCredentialPathFromSystemPackageRepositories < ActiveRecord::Migration[8.0]
  def change
    remove_column :system_package_repositories, :vault_credential_path, :string
  end
end
