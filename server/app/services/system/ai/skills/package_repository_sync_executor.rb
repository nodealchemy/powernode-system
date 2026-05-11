# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for triggering a single package-repository sync.
      # Bound to Fleet Autonomy; auto-approved per intervention policy
      # (system.package_repository.sync, 1h cooldown).
      class PackageRepositorySyncExecutor
        def self.descriptor
          {
            name:        "package_repository_sync",
            description: "Sync upstream apt/rpm metadata for one package repository (account-scoped or shared)",
            category:    "devops",
            inputs: {
              repository_id: { type: "string", required: true,
                               description: "PackageRepository.id" }
            },
            outputs: {
              ok:            :boolean,
              upserted:      :integer,
              obsoleted:     :integer,
              package_count: :integer,
              error:         :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent   = agent
          @user    = user
        end

        def execute(repository_id:)
          repo = ::System::PackageRepository.accessible_to(@account).find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          result = ::System::PackageRepositorySyncService.call(repository: repo)
          success(
            ok:            result.success?,
            upserted:      result.upserted,
            obsoleted:     result.obsoleted,
            package_count: result.package_count,
            error:         result.error,
            requires_approval: false
          )
        end

        private

        def success(**data); { success: true, data: data }; end
        def failure(msg); { success: false, error: msg }; end
      end
    end
  end
end
