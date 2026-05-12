# frozen_string_literal: true

module System
  # Join row tying a PackageRepository to a NodePlatform. Cardinality is
  # genuine many-to-many — one Ubuntu noble repo serves every Ubuntu-noble
  # NodePlatform regardless of arch flavor, and a single platform may pull
  # from base + security + third-party repos.
  #
  # Cross-account integrity: enforced here rather than at the DB level
  # because shared repos (account_id IS NULL) may legally link to any
  # account's platform, while account-scoped repos must keep all links
  # within their own account. A single CHECK constraint can't express
  # that branch.
  class PackageRepositoryPlatform < ApplicationRecord
    self.table_name = "system_package_repository_platforms"

    belongs_to :package_repository, class_name: "System::PackageRepository"
    belongs_to :node_platform,      class_name: "System::NodePlatform"

    validates :package_repository_id,
              uniqueness: { scope: :node_platform_id,
                            message: "is already linked to this platform" }
    validate :account_consistency

    private

    def account_consistency
      return if package_repository.nil? || node_platform.nil?
      # Shared repos (account_id IS NULL) can link to any platform.
      return if package_repository.shared?
      # Account-scoped repos: platform must belong to the same account.
      return if package_repository.account_id == node_platform.account_id

      errors.add(
        :node_platform,
        "must belong to the same account as the repository " \
        "(repo=#{package_repository.account_id.inspect} platform=#{node_platform.account_id.inspect})"
      )
    end
  end
end
