# frozen_string_literal: true

module System
  # Resolves (or auto-creates) the NodeModule a CI publish targets.
  #
  # Extracted verbatim from Api::V1::System::ModulePublicationsController to
  # keep the controller under the size budget. Method bodies are an exact
  # move — same lookup chain, same publisher-account/category/platform
  # heuristics, same RecordInvalid-swallowing auto-create.
  class ModulePublishTargetResolver
    # Find the NodeModule receiving this publish; create one if absent.
    #
    # ACCOUNT-SCOPED (multi-tenant safe). The module registry is owned
    # per-account: a CI publish authenticated as account A may only ever
    # resolve or create modules within account A. `account` is the CI
    # worker's owning account (controller passes @current_ci_worker.account).
    #
    # Lookup order — ALL scoped to the supplied account:
    #   1. bare name match within the account
    #   2. create a NodeModule on `account` with stub defaults; the
    #      apply_manifest_yaml step immediately following populates the rest.
    #
    # NAME IS AUTHORITATIVE, and that is forced on us by the very next step in
    # the pipeline: ManifestImportService REFUSES any target whose `name`
    # differs from the manifest's `name:` (unconditionally — there is no
    # rename-allowed path). Whatever this method returns is handed straight to
    # it, so returning a differently-named module is not a lesser match, it is a
    # guaranteed 422. Since `name` is unique per account, a name lookup is
    # deterministic and is the only lookup that can produce a usable target.
    #
    # This used to try gitea_repo_full_name FIRST, on the reasoning that the OCI
    # namespace is canonical and would let a module renamed in the source tree
    # keep resolving without an ops-side cutover. That benefit is unreachable:
    # a renamed module is precisely the mismatch the importer rejects, so the
    # repo-first branch could only ever select a doomed target. What it did
    # instead was let ANY module holding the binding intercept publishes meant
    # for another.
    #
    # Measured on ops-hub 2026-07-27: the canonical `powernode-system-base` (54
    # assignments) had no binding, while a one-off
    # `powernode-system-base-vm104-devpin` (1 assignment, named for a VMID that
    # no longer exists) held "powernode/powernode-system-base". Every publish
    # resolved to the variant and 422'd, so no module build landed on that
    # platform. `gitea_repo_full_name` carries a UNIQUE index, so exactly one
    # module can hoard a repo this way.
    #
    # The binding is still meaningful metadata elsewhere (build dispatch,
    # manifest fetch, parity) — it simply must not outrank the name here.
    #
    # Scoping every lookup to the worker's account closes the cross-tenant
    # IDOR where an unscoped find_by(name:)/find_by(gitea_repo_full_name:)
    # could resolve (and then republish/promote) another tenant's module,
    # and where auto-create attached the row to a heuristically-picked
    # "publisher" account rather than the worker's own.
    #
    # Auto-creation guards against record-invalid + returns nil so the
    # caller can render a clean 422 instead of bubbling an exception.
    def find_or_create_publish_target(gitea_repo, module_name, account:)
      return nil unless account

      existing = account.system_node_modules.find_by(name: module_name)
      warn_on_foreign_repo_binding(gitea_repo, module_name, account)
      return existing if existing

      category = resolve_publisher_category(account)
      platform = resolve_publisher_node_platform(account)
      return nil unless category && platform

      ::System::NodeModule.create!(
        account:       account,
        name:          module_name,
        variety:       "subscription",
        category:      category,
        node_platform: platform,
        enabled:       true,
        public:        false,
        priority:      50,
        lock_spec:     false
      )
    rescue ::ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[ModulePublicationsController] auto-create failed for name=#{module_name}: #{e.message}"
      nil
    end

    private

    # A repo binding held by a DIFFERENT module is drift: the binding points at
    # a module the build no longer publishes to. It no longer breaks the
    # publish (name wins), but it is invisible otherwise — and its invisibility
    # is exactly what let ops-hub sit broken. Surface it at publish time.
    def warn_on_foreign_repo_binding(gitea_repo, module_name, account)
      return if gitea_repo.blank?

      holder = account.system_node_modules.find_by(gitea_repo_full_name: gitea_repo)
      return if holder.nil? || holder.name == module_name

      Rails.logger.warn(
        "[ModulePublishTargetResolver] #{holder.name} (#{holder.id}) holds the OCI repo " \
        "binding #{gitea_repo}, but this publish is for #{module_name.inspect} — resolved " \
        "by name instead. The binding is stale or belongs on the published module; clear it " \
        "or rebind it, or build dispatch/manifest fetch for #{module_name.inspect} will keep " \
        "falling back to a derived repo name."
      )
    end

    # Category for auto-created NodeModules. campaign 019f6084 retired the
    # single "Powernode Platform" catch-all in favor of System::
    # NodeModuleCategory::PLATFORM_TAXONOMY; a CI-published module with no
    # prior NodeModule row (no manifest `category:` has been read yet —
    # that happens in the apply_manifest_yaml step immediately following
    # this resolve) is, functionally, an on-demand workload, so it lands in
    # the same "workloads" bucket System::PackageModuleMaterializer
    # defaults to. Self-healing (creates the triplet on first use); falls
    # back to whatever subscription-variety category the account happens
    # to have if taxonomy resolution somehow comes back empty.
    def resolve_publisher_category(account)
      ::System::NodeModuleCategory.for_platform_slug!(account: account, slug: "workloads") ||
        ::System::NodeModuleCategory.find_by(account: account, variety: "subscription") ||
        ::System::NodeModuleCategory.find_by(account: account)
    end

    # NodePlatform for auto-created NodeModules. ubuntu-24.04-lts is
    # the seed default; fall back to first available.
    def resolve_publisher_node_platform(account)
      ::System::NodePlatform.find_by(account: account, name: "ubuntu-24.04-lts") ||
        ::System::NodePlatform.find_by(account: account)
    end
  end
end
