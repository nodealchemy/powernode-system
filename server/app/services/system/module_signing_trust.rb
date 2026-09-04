# frozen_string_literal: true

module System
  # The ONE resolver for "which module-signing PUBLIC keys does this platform
  # trust". Consumed by:
  #
  #   - ModuleOciIngestService::OrasOciAdapter — verifies the builder's OCI
  #     image signature at ingest against this list.
  #   - NodeApi::ModulesController#signing_keys and the #download envelope —
  #     serves the same list to fleet nodes as their trust anchor for the
  #     platform's `cosign sign-blob` bundles (agent runtime.ResolveModuleVerifier
  #     caches it under /persist when the operator pins no keys).
  #
  # One list, deliberately: a node must not trust a key the platform's own
  # ingest would not, and vice versa. Ordered SiteSetting keys first (the
  # Vault-transit / local signing key(s); rotation is append-new, cut over,
  # keep old — see ModuleSigningKey#register_public_key!), then the legacy
  # static key from POWERNODE_COSIGN_PUBLIC_KEY / _FILE. Public keys are not
  # secret; any read failure degrades that source to "no keys" rather than
  # raising, matching the adapter's historical behaviour.
  module ModuleSigningTrust
    TRUSTED_KEYS_SETTING = "system.module_signing.trusted_public_keys"

    module_function

    # @return [Array<String>] PEM public keys, de-duplicated, in trust order,
    #   byte-for-byte as configured (they are handed to cosign verbatim).
    #   Empty when nothing is configured.
    def public_keys
      (site_setting_keys + [ legacy_static_key ])
        .map { |k| k.to_s.presence }
        .compact
        .uniq
    end

    def site_setting_keys
      Array(::SiteSetting.get(TRUSTED_KEYS_SETTING))
    rescue StandardError => e
      ::Rails.logger.warn("[ModuleSigningTrust] #{TRUSTED_KEYS_SETTING} read failed: #{e.class}: #{e.message}")
      []
    end

    # The pre-inc8 single static key — the same config
    # BootImage::UpgradeDispatcher.platform_cosign_public_key reads.
    def legacy_static_key
      if (inline = ENV["POWERNODE_COSIGN_PUBLIC_KEY"]).present?
        inline
      elsif (path = ENV["POWERNODE_COSIGN_PUBLIC_KEY_FILE"]).present? && File.exist?(path)
        File.read(path)
      end
    rescue StandardError => e
      ::Rails.logger.warn("[ModuleSigningTrust] legacy static key read failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
