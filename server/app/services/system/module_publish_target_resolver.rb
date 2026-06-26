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
    # Lookup order:
    #   1. gitea_repo_full_name match (canonical OCI namespace)
    #   2. bare name match across any account (legacy unscoped lookup;
    #      ambiguous with multi-tenant seed data but preserves prior
    #      behavior when the row exists somewhere)
    #   3. find_or_create_by(account: publisher, name:) — stub row
    #      with sane defaults; the apply_manifest_yaml step
    #      immediately following populates the rest.
    #
    # Auto-creation guards against record-invalid + returns nil so the
    # caller can render a clean 422 instead of bubbling an exception.
    def find_or_create_publish_target(gitea_repo, module_name)
      existing = ::System::NodeModule.find_by(gitea_repo_full_name: gitea_repo) ||
                 ::System::NodeModule.find_by(name: module_name)
      return existing if existing

      account = resolve_publisher_account
      return nil unless account

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

    # Account that owns auto-created NodeModules. Default lookup:
    #   1. ENV[PLATFORM_PUBLISHER_ACCOUNT_NAME] (operator override)
    #   2. "Powernode Admin" (seed-managed canonical name)
    #   3. Account with the most existing NodeModule rows (heuristic
    #      for finding the platform-admin account in multi-tenant
    #      installs where it might have a non-default name)
    #   4. First account by created_at (last-resort fallback)
    def resolve_publisher_account
      explicit = ENV.fetch("PLATFORM_PUBLISHER_ACCOUNT_NAME", "Powernode Admin")
      ::Account.find_by(name: explicit) ||
        (
          top_id = ::System::NodeModule.group(:account_id).count.max_by(&:last)&.first
          top_id ? ::Account.find_by(id: top_id) : nil
        ) ||
        ::Account.order(:created_at).first
    end

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
