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
    #   1. gitea_repo_full_name match (canonical OCI namespace)
    #   2. bare name match within the account
    #   3. create a NodeModule on `account` with stub defaults; the
    #      apply_manifest_yaml step immediately following populates the rest.
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

      existing = account.system_node_modules.find_by(gitea_repo_full_name: gitea_repo) ||
                 account.system_node_modules.find_by(name: module_name)
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

    # Category for auto-created NodeModules. "Powernode Platform"
    # is the seed-managed category for platform modules; absent
    # that, drop into whatever category the account has set up.
    def resolve_publisher_category(account)
      ::System::NodeModuleCategory.find_by(account: account, name: "Powernode Platform", variety: "subscription") ||
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
