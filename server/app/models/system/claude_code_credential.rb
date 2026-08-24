# frozen_string_literal: true

module System
  # One Claude Code CLI credential per NodeInstance, consumed by the
  # claude-tmux NodeModule's boot-time fetch script over the
  # mTLS-authenticated node_api. Prefers Vault; falls back to an
  # encrypted_credentials column (Security::CredentialEncryptionService,
  # via the VaultCredential concern's default DB-fallback path) on
  # Vault-less deployments (e.g. ops-hub, POWERNODE_CA_MODE=local) — same
  # shape as System::AcmeDnsCredential.
  #
  # Two credential kinds (credential_kind column, producer-declared):
  #   "api_key" — an Anthropic API key; the node exports it as
  #               ANTHROPIC_API_KEY for the session. The original kind
  #               and the column default.
  #   "oauth"   — a Claude subscription login: the claudeAiOauth object
  #               from ~/.claude/.credentials.json. The node installs it
  #               as that file, SEED-ONCE: after first install the NODE
  #               owns the file (Claude Code rotates both tokens in place
  #               when refreshing), so the Vault copy goes stale by design
  #               and is re-consulted only when no usable local credential
  #               exists. See docs/CLAUDE_TMUX_MODULE.md.
  class ClaudeCodeCredential < ApplicationRecord
    self.table_name = "system_claude_code_credentials"

    include VaultCredential

    self.vault_credential_type = "claude_code_api_key"

    KINDS = %w[api_key oauth].freeze

    # Raised by .normalize_oauth_payload! — message names the offending
    # FIELD only; it must never echo a token value (CryptoMaterialSafety).
    class InvalidOauthPayload < ArgumentError; end

    # 10^12 ms = 2001-09-09. The credentials-file timestamps are epoch
    # MILLISECONDS; any plausible value clears this floor, while an
    # epoch-seconds value (mistakenly divided by 1000) never can.
    EPOCH_MS_FLOOR = 10**12

    validates :credential_kind, inclusion: { in: KINDS }

    # The VaultCredential concern assumes a generic `vault_path` column;
    # this table names it `vault_path_credentials` (same alias pattern as
    # System::AcmeDnsCredential) so multi-path callers can coexist.
    alias_attribute :vault_path, :vault_path_credentials

    belongs_to :node_instance, class_name: "System::NodeInstance"
    delegate :account, :account_id, to: :node_instance

    validates :node_instance_id, uniqueness: true

    def oauth?
      credential_kind == "oauth"
    end

    # The Vault credential type for THIS row's kind — distinct types so
    # the two kinds never share a Vault path and rotate independently.
    # :claude_code_oauth is deliberately NOT registered in core's
    # VaultCredentialProvider::CREDENTIAL_TYPES — the provider's documented
    # fallback (`CREDENTIAL_TYPES[type] || credential_type.to_s`) yields the
    # stable path segment "claude_code_oauth", keeping this kind fully
    # extension-contained (core never needs to learn the new type).
    def vault_kind_type
      oauth? ? :claude_code_oauth : :claude_code_api_key
    end

    # Validates + normalizes an operator-supplied OAuth blob into the inner
    # claudeAiOauth object (string keys, exactly what Claude Code reads from
    # ~/.claude/.credentials.json). Accepts either the bare object or the
    # full file shape ({"claudeAiOauth" => {...}}). Unknown keys are
    # preserved verbatim — Claude Code may add fields, and this platform
    # must not strip what the CLI wrote.
    #
    # Sanity rules:
    #   * accessToken / refreshToken: required non-empty strings.
    #   * expiresAt: required integer, epoch MILLISECONDS. MAY be in the
    #     past — an expired access token is fine, the refresh token is the
    #     seed's lifeline and Claude Code refreshes on first use.
    #   * refreshTokenExpiresAt: optional integer epoch ms; if present it
    #     must be in the FUTURE — a dead refresh token can never
    #     authenticate, so accepting one would seed a credential that is
    #     guaranteed to fail weeks later with no breadcrumb.
    def self.normalize_oauth_payload!(payload)
      payload = payload["claudeAiOauth"] if payload.is_a?(Hash) && payload.key?("claudeAiOauth")
      unless payload.is_a?(Hash)
        raise InvalidOauthPayload,
              "oauth payload must be a JSON object (the claudeAiOauth object from ~/.claude/.credentials.json)"
      end

      %w[accessToken refreshToken].each do |key|
        value = payload[key]
        unless value.is_a?(String) && !value.strip.empty?
          raise InvalidOauthPayload, "#{key} is required and must be a non-empty string"
        end
      end

      expires_at = payload["expiresAt"]
      raise InvalidOauthPayload, "expiresAt is required and must be an integer" unless expires_at.is_a?(Integer)
      if expires_at < EPOCH_MS_FLOOR
        raise InvalidOauthPayload, "expiresAt must be epoch milliseconds (this value looks like epoch seconds)"
      end

      refresh_expires = payload["refreshTokenExpiresAt"]
      unless refresh_expires.nil?
        unless refresh_expires.is_a?(Integer) && refresh_expires >= EPOCH_MS_FLOOR
          raise InvalidOauthPayload, "refreshTokenExpiresAt must be an integer, epoch milliseconds"
        end
        if refresh_expires <= (Time.current.to_f * 1000).to_i
          raise InvalidOauthPayload,
                "refreshTokenExpiresAt is already expired — a dead refresh token can never authenticate; " \
                "log in again on the source machine and re-export the credential"
        end
      end

      scopes = payload["scopes"]
      unless scopes.nil? || (scopes.is_a?(Array) && scopes.all? { |s| s.is_a?(String) })
        raise InvalidOauthPayload, "scopes must be an array of strings"
      end

      subscription = payload["subscriptionType"]
      unless subscription.nil? || subscription.is_a?(String)
        raise InvalidOauthPayload, "subscriptionType must be a string"
      end

      payload
    end
  end
end
