# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for triggering a single package-repository sync.
      # Bound to Fleet Autonomy; auto-approved per intervention policy
      # (system.package_repository.sync, 1h cooldown).
      class PackageRepositorySyncExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "package_repository_sync",
          description: "Enqueue a background sync of upstream apt/rpm metadata for one package repository (account-scoped or shared); returns once queued, the sync runs out-of-process",
          category:    "devops",
          inputs: {
            repository_id: { type: "string", required: true,
                             description: "PackageRepository.id" }
          },
          outputs: {
            ok:            :boolean,
            queued:        :boolean,
            status:        :string,
            repository_id: :string
          }
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(repository_id:, force: false)
          repo = ::System::PackageRepository.accessible_to(@account).find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          # Async: enqueue the sync (→ detached out-of-puma process) rather than
          # block the autonomy loop for minutes. The reconcile tick re-observes
          # sync_status later; no need to wait on stats here.
          ::System::PackageRepositorySyncService.enqueue!(repository: repo, force: force)
          success(
            ok:            true,
            queued:        true,
            status:        repo.sync_status,
            repository_id: repo.id,
            requires_approval: false
          )
        end
      end
    end
  end
end
