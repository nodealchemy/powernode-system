# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for triggering a single package-repository sync.
      # Bound to the Supply Chain Manager (HIER-P2E; Fleet Autonomy until
      # then); auto-approved per intervention policy
      # (system.package_repository.sync, 1h cooldown). The sensor path
      # (package_drift_sensor → system.package_drift_pressure) gates the same
      # category under that agent — the binding carries `skill: nil`, so no
      # tick reaches this executor; it is the skill/MCP door.
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

        binds_to "supply_chain_manager"

        protected

        def perform(repository_id:, force: false)
          repo = ::System::PackageRepository.accessible_to(@account).find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          # IMP-c90ba4ec46da — `force` is not a declared descriptor input, but
          # BaseSkillExecutor#acceptable_inputs slices the caller's inputs to
          # the keywords THIS method declares, so a composed plan step carrying
          # a `force` key reaches it. Force switches OFF the sync service's
          # mass-obsoletion guard, and `accessible_to` admits every shared
          # (account_id IS NULL) repo, so a forced sync here could soft-delete
          # an arbitrary fraction of a catalog every tenant reads. Gate the
          # FORCED path on a SHARED repo only: an unforced sync stays open (the
          # autonomy loop's normal refresh), and an account-scoped repo's owner
          # may force — the blast radius is their own catalog.
          # Coerced so the value the gate checks is byte-for-byte the value
          # enqueue! acts on (it casts too) — same expression the controller
          # and the MCP tool use.
          force = ::ActiveModel::Type::Boolean.new.cast(force) || false
          if force && repo.shared? && !(@user&.has_permission?("system.package_repositories.manage_shared"))
            return failure("cannot force-sync a shared repository without system.package_repositories.manage_shared")
          end

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
