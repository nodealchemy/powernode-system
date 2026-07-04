# frozen_string_literal: true

module System
  # Registry config the disk-image CI workflow needs to authenticate to the
  # OCI registry before `oras login` + push. Two backing sources, matching
  # the DK1 restoration (moving this OUT of Gitea Actions secrets):
  #
  #   * registry_host             — platform config, NOT a secret. AdminSetting.
  #   * registry_user/registry_token — real credentials. Security::SecretStore
  #                                    (Vault-or-DB-encrypted seam), scoped
  #                                    platform-global (account: nil), same as
  #                                    Security::JwtKeyStore's signing keypair.
  #
  # ENV is a dev-only fallback (POWERNODE_REGISTRY_HOST/_USER/_TOKEN — the
  # same names the build-disk-image.yaml workflow already used as Gitea
  # secrets) so a bare-metal box without AdminSetting/Vault configured yet
  # still works, and so a Vault blip doesn't take down CI publishing —
  # mirroring JwtKeyStore's "never outage" fallback posture: any read
  # failure (including Security::SecretStore::BackendUnavailable when Vault
  # is selected but unreachable) is logged and treated as "not configured
  # here," falling through to ENV, rather than raising out of the resolver.
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
      def registry_host
        safe_setting(HOST_SETTING_KEY).presence || ENV["POWERNODE_REGISTRY_HOST"]
      end

      def registry_user
        safe_secret(SECRET_KEY_USER).presence || ENV["POWERNODE_REGISTRY_USER"]
      end

      # NEVER log this value. Callers must not pass it to Rails.logger.
      def registry_token
        safe_secret(SECRET_KEY_TOKEN).presence || ENV["POWERNODE_REGISTRY_TOKEN"]
      end

      # True once a real host + credentials are available — false while the
      # host is missing/still the seed placeholder, or either credential is
      # absent.
      def configured?
        host = registry_host
        host.present? && host != PLACEHOLDER_HOST &&
          registry_user.present? && registry_token.present?
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
    end
  end
end
