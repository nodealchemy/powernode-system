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

      # IMP-156eb1a7bdbc — the SAME error the required belongs_to adds for a
      # nonexistent platform ("must exist"). The message is rendered to the
      # caller (render_validation_error, the MCP tool's full_messages) on the
      # create/update doors, which pass a raw node_platform_id; a distinct
      # "same account" message would tell a tenant that another tenant's
      # platform id exists. To this repository, a foreign platform does not.
      # Rails records a required belongs_to as a presence error (`:blank`)
      # carrying the `:required` message; mirror both, so even
      # errors.details matches.
      errors.add(:node_platform, :blank, message: :required)
    end
  end
end
