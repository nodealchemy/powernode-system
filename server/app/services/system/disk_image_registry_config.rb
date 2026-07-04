# frozen_string_literal: true

module System
  # Registry config the disk-image CI workflow needs to authenticate to the
  # OCI registry before `oras login` + push. DK1 moved this OUT of Gitea
  # Actions secrets; DK4 adds a third, lowest-precedence tier so a fresh
  # account needs ZERO hand-entered registry secrets — it reuses the Gitea
  # provider credential the operator already has:
  #
  #   * registry_host   — override: AdminSetting (platform config, NOT a
  #                        secret) → ENV → the account's Gitea provider's
  #                        `effective_web_base_url` host.
  #   * registry_user/registry_token — override: Security::SecretStore
  #                        (Vault-or-DB-encrypted seam, scoped
  #                        platform-global — account: nil, same as
  #                        Security::JwtKeyStore's signing keypair) → ENV →
  #                        the account's active Gitea `GitProviderCredential`
  #                        (external_username / access_token).
  #
  # The Gitea *provider* row is looked up unscoped (matching the
  # find_gitea_credential convention already used by
  # Ai::Tools::DiskImageOperatorTool, RepoManagementTool, GiteaActionsTool,
  # etc. — one shared provider record, referenced by every account's
  # credentials) — only the *credential* is scoped to the calling account.
  #
  # ENV remains a dev-only fallback (POWERNODE_REGISTRY_HOST/_USER/_TOKEN —
  # the same names the build-disk-image.yaml workflow already used as Gitea
  # secrets) so a bare-metal box without AdminSetting/Vault/a Gitea
  # credential configured yet still works, and so a Vault blip doesn't take
  # down CI publishing — mirroring JwtKeyStore's "never outage" fallback
  # posture: any read/lookup failure (including
  # Security::SecretStore::BackendUnavailable when Vault is selected but
  # unreachable) is logged and treated as "not configured here," falling
  # through to the next tier, rather than raising out of the resolver.
  #
  # No in-process caching (unlike JwtKeyStore) — this is called once per CI
  # publish, not once per request, so the extra DB/Vault round-trip doesn't
  # need amortizing.
  module DiskImageRegistryConfig
    HOST_SETTING_KEY = "disk_image_oci_registry_host"
    SECRET_SCOPE      = "disk_image_ci"
    SECRET_KEY_USER   = "registry_user"
    SECRET_KEY_TOKEN  = "registry_token"

    # The seed/placeholder value account_bootstrap_service and friends write
    # into cosign_identity_regexp/cosign_issuer_regexp for a fresh account —
    # treated as "not yet configured" here too, so an unconfigured platform
    # fails loudly (503) at fetch time instead of handing CI a host it can't
    # reach.
    PLACEHOLDER_HOST = "registry.example.com"

    class << self
      def registry_host(account:)
        safe_setting(HOST_SETTING_KEY).presence ||
          ENV["POWERNODE_REGISTRY_HOST"].presence ||
          gitea_host
      end

      def registry_user(account:)
        safe_secret(SECRET_KEY_USER).presence ||
          ENV["POWERNODE_REGISTRY_USER"].presence ||
          gitea_username(account)
      end

      # NEVER log this value. Callers must not pass it to Rails.logger.
      def registry_token(account:)
        safe_secret(SECRET_KEY_TOKEN).presence ||
          ENV["POWERNODE_REGISTRY_TOKEN"].presence ||
          gitea_credential(account)&.access_token
      end

      # True once a real host + credentials are available — false while the
      # host is missing/still the seed placeholder, or either credential is
      # absent.
      def configured?(account:)
        host = registry_host(account: account)
        host.present? && host != PLACEHOLDER_HOST &&
          registry_user(account: account).present? && registry_token(account: account).present?
      end

      private

      def safe_setting(key)
        AdminSetting.get(key)
      rescue StandardError => e
        Rails.logger.warn("[DiskImageRegistryConfig] AdminSetting read failed for #{key}: #{e.class}: #{e.message}")
        nil
      end

      def safe_secret(key)
        Security::SecretStore.read(account: nil, scope: SECRET_SCOPE, key: key)
      rescue StandardError => e
        Rails.logger.warn("[DiskImageRegistryConfig] SecretStore read failed for #{key}: #{e.class}: #{e.message}")
        nil
      end

      def gitea_provider
        Devops::GitProvider.find_by(provider_type: "gitea")
      end

      def gitea_host
        provider = gitea_provider
        return nil unless provider

        url = provider.effective_web_base_url
        return nil if url.blank?

        URI.parse(url).host
      rescue StandardError => e
        Rails.logger.warn("[DiskImageRegistryConfig] Gitea provider host resolution failed: #{e.class}: #{e.message}")
        nil
      end

      # Per-account, active, default-first — same ordering as the
      # find_gitea_credential pattern used elsewhere in the codebase.
      def gitea_credential(account)
        return nil unless account

        provider = gitea_provider
        return nil unless provider

        account.git_provider_credentials
               .where(git_provider_id: provider.id, is_active: true)
               .order(is_default: :desc, created_at: :desc)
               .first
      rescue StandardError => e
        Rails.logger.warn("[DiskImageRegistryConfig] Gitea credential lookup failed: #{e.class}: #{e.message}")
        nil
      end

      # external_username is the dedicated column both the OAuth callback
      # (Devops::Git::OAuthService#create_credential_from_token) and the PAT
      # connection-test path (Devops::Git::ProviderManagementService
      # #test_and_update_credential) populate on success — the reliable
      # source. The remaining fallbacks only matter for a credential that
      # predates that population (or whose connection test never ran).
      def gitea_username(account)
        cred = gitea_credential(account)
        return nil unless cred

        cred.external_username.presence ||
          cred.credentials["username"].presence ||
          cred.credentials["login"].presence ||
          cred.credentials["user"].presence ||
          cred.user.try(:username).presence ||
          cred.user.try(:login).presence ||
          cred.user&.email&.split("@")&.first
      rescue StandardError => e
        Rails.logger.warn("[DiskImageRegistryConfig] Gitea username resolution failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
