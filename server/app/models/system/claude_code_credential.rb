# frozen_string_literal: true

module System
  # One on-node AI CLI credential per NodeInstance PER PROVIDER, consumed by
  # an AI-CLI NodeModule's boot-time fetch script over the
  # mTLS-authenticated node_api: claude-tmux reads the "anthropic" row,
  # grok-cli the "grok" row (see PROVIDER_TYPES).
  #
  # The class and table are still named for their first and only consumer.
  # Renaming both — and the operator REST surface at
  # /nodes/:id/node_instances/:id/claude_code_credential — is deliberately
  # deferred: it is a pure rename across a live deployment and belongs in
  # its own change, not bundled with adding a provider.
  #
  # Prefers Vault; falls back to an
  # encrypted_credentials column (Security::CredentialEncryptionService,
  # via the VaultCredential concern's default DB-fallback path) on
  # Vault-less deployments (e.g. ops-hub, POWERNODE_CA_MODE=local) — same
  # shape as System::AcmeDnsCredential.
  #
  # Two credential kinds (credential_kind column, producer-declared):
  #   "api_key" — a provider API key; the node exports it under that
  #               provider's own env var (ANTHROPIC_API_KEY for the
  #               claude-tmux session, XAI_API_KEY for grok-cli). The
  #               original kind, the column default, and the ONLY kind
  #               any provider other than anthropic supports.
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

    # The AI providers an on-node CLI credential may belong to. A row is
    # scoped to one provider so a single instance can carry an Anthropic key
    # for claude-tmux AND an xAI key for grok-cli without either table or
    # Vault path colliding. Values are Ai::Constants::ProviderTypes members — the
    # same vocabulary Ai::Provider#provider_type validates against — but the
    # list is deliberately NOT the full catalog: a provider belongs here only
    # once a NodeModule actually fetches its key over the node_api, because
    # every entry widens what an enrolled instance can ask the platform to
    # decrypt and hand back.
    PROVIDER_TYPES = %w[anthropic grok].freeze

    # OAuth is a Claude-subscription shape (the ~/.claude/.credentials.json
    # blob). No other provider here has one, and accepting `oauth` for them
    # would let an operator store a payload that normalize_oauth_payload!
    # validates as a Claude credential and no node could ever use.
    OAUTH_CAPABLE_PROVIDER_TYPES = %w[anthropic].freeze

    # Raised by .normalize_oauth_payload! — message names the offending
    # FIELD only; it must never echo a token value (CryptoMaterialSafety).
    class InvalidOauthPayload < ArgumentError; end

    # 10^12 ms = 2001-09-09. The credentials-file timestamps are epoch
    # MILLISECONDS; any plausible value clears this floor, while an
    # epoch-seconds value (mistakenly divided by 1000) never can.
    EPOCH_MS_FLOOR = 10**12

    validates :credential_kind, inclusion: { in: KINDS }
    validates :provider_type, inclusion: { in: PROVIDER_TYPES }
    validate :oauth_kind_only_for_oauth_capable_provider

    # The VaultCredential concern assumes a generic `vault_path` column;
    # this table names it `vault_path_credentials` (same alias pattern as
    # System::AcmeDnsCredential) so multi-path callers can coexist.
    alias_attribute :vault_path, :vault_path_credentials

    belongs_to :node_instance, class_name: "System::NodeInstance"
    delegate :account, :account_id, to: :node_instance

    # Scoped to the provider (see the migration): one credential per
    # instance PER PROVIDER, so an instance can carry both an Anthropic key
    # for claude-tmux and an xAI key for grok-cli. Backed by the composite
    # unique index — the validation is the friendly error, the index is the
    # guarantee.
    validates :node_instance_id, uniqueness: { scope: :provider_type }

    def oauth?
      credential_kind == "oauth"
    end

    # The Vault credential type for THIS row's provider AND kind — distinct
    # types so no two of them share a Vault path or rotate together.
    # :claude_code_oauth and every non-anthropic type are deliberately NOT
    # registered in core's VaultCredentialProvider::CREDENTIAL_TYPES — the
    # provider's documented fallback
    # (`CREDENTIAL_TYPES[type] || credential_type.to_s`) yields the stable
    # path segment verbatim, keeping these fully extension-contained (core
    # never needs to learn a new type).
    #
    # anthropic keeps its ORIGINAL segments (claude_code_api_key /
    # claude_code_oauth) rather than being folded into the generic scheme
    # below: those paths hold live credentials on deployed fleets, and a
    # renamed segment reads as "Vault has no credential for this instance"
    # (a 503 on the node_api read path) with no migration to point at.
    def vault_kind_type
      if provider_type == "anthropic"
        oauth? ? :claude_code_oauth : :claude_code_api_key
      else
        :"#{provider_type}_api_key"
      end
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

    private

    # An `oauth` row for a provider with no OAuth shape is unusable by
    # construction: normalize_oauth_payload! validates the Claude
    # subscription blob specifically, and no non-Anthropic module reads
    # that file. Rejected at the model rather than at the node_api read
    # path, where it would surface as a 503 on a live instance.
    def oauth_kind_only_for_oauth_capable_provider
      return unless oauth?
      return if OAUTH_CAPABLE_PROVIDER_TYPES.include?(provider_type)

      errors.add(:credential_kind,
                 "oauth is not supported for provider_type #{provider_type} " \
                 "(supported: #{OAUTH_CAPABLE_PROVIDER_TYPES.join(', ')})")
    end
  end
end
