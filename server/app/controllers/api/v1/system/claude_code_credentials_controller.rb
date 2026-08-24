# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for a NodeInstance's Claude Code CLI credential
      # — the secret the claude-tmux NodeModule fetches at boot over the
      # mTLS-authenticated node_api
      # (NodeApi::ConfigController#claude_code_credential).
      #
      # Two kinds, selected by which POST param is supplied (exactly one):
      #   api_key — an Anthropic API key (the original kind).
      #   oauth   — a Claude subscription login: the claudeAiOauth object
      #             from ~/.claude/.credentials.json (bare or still wrapped
      #             in {"claudeAiOauth": ...}). Validated by
      #             System::ClaudeCodeCredential.normalize_oauth_payload!.
      # Kind switches go through DELETE + POST (rotate refuses a mismatch)
      # so the Vault entry under the old kind's type is always cleaned up.
      #
      # Routes (nested under nodes/node_instances):
      #   GET    /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/claude_code_credential
      #   POST   /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/claude_code_credential
      #   POST   /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/claude_code_credential/rotate
      #   DELETE /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/claude_code_credential
      #
      # Permissions:
      #   system.node_instance_credentials.read   — show
      #   system.node_instance_credentials.manage — create + rotate + destroy
      #
      # IMPORTANT (CryptoMaterialSafety): the api_key / oauth-token
      # plaintext is received via the POST body, handed directly to
      # VaultCredentialProvider, and never assigned to a model attribute,
      # never serialized in a response, never written to logs — validation
      # errors name FIELDS, never values. Mirrors AcmeDnsCredentialsController.
      class ClaudeCodeCredentialsController < BaseController
        before_action :set_account
        before_action :set_node
        before_action :set_instance
        # Permission checks run BEFORE the CREDENTIAL lookup so an
        # unauthorized caller can never learn whether a credential exists
        # for an instance (403, not 404). Node/instance resolution runs
        # first — those ids are account-scoped resources the caller can
        # already enumerate elsewhere, not secrets.
        before_action -> { require_permission("system.node_instance_credentials.read") }, only: %i[show]
        before_action -> { require_permission("system.node_instance_credentials.manage") },
                      only: %i[create rotate destroy]
        before_action :set_credential, only: %i[show destroy rotate]

        # Raised by #extract_credential_payload! for malformed kind
        # selection (neither/both params). Field names only, never values.
        PayloadError = Class.new(StandardError)

        def show
          render_success(credential: serialize(@credential))
        end

        def create
          if ::System::ClaudeCodeCredential.exists?(node_instance_id: @instance.id)
            return render_error("Credential already exists for this instance — use rotate",
                                 status: :conflict)
          end

          kind, data = extract_credential_payload!

          cred = nil
          ::ActiveRecord::Base.transaction do
            cred = ::System::ClaudeCodeCredential.create!(node_instance: @instance,
                                                          credential_kind: kind)
            # Hand the plaintext directly to Vault — never assign to the model.
            vault_provider.store_credential(
              credential_type: cred.vault_kind_type,
              credential_id: cred.id,
              data: data,
              record: cred
            )
          end
          render_success({ credential: serialize(cred) }, status: :created)
        rescue PayloadError, ::System::ClaudeCodeCredential::InvalidOauthPayload,
               ::ActiveRecord::RecordInvalid => e
          render_error(e.message, status: :unprocessable_content)
        rescue ::ActiveRecord::RecordNotUnique
          # Lost the exists?/create! race to a concurrent create — same
          # answer as the up-front check, not a 500.
          render_error("Credential already exists for this instance — use rotate",
                       status: :conflict)
        end

        def rotate
          kind, data = extract_credential_payload!

          if kind != @credential.credential_kind
            # Rotating across kinds would leave the old kind's Vault entry
            # orphaned under its distinct credential_type path — force the
            # explicit DELETE + POST so cleanup always happens.
            return render_error(
              "Credential is #{@credential.credential_kind}-kind — delete and re-create to switch kinds",
              status: :conflict
            )
          end

          vault_provider.rotate_credential(
            credential_type: @credential.vault_kind_type,
            credential_id: @credential.id,
            new_data: data,
            record: @credential
          )
          render_success(credential: serialize(@credential.reload))
        rescue PayloadError, ::System::ClaudeCodeCredential::InvalidOauthPayload => e
          render_error(e.message, status: :unprocessable_content)
        end

        def destroy
          vault_provider.delete_credential(
            credential_type: @credential.vault_kind_type,
            credential_id: @credential.id,
            record: @credential
          )
          @credential.destroy!
          render_success(deleted: true, id: @credential.id)
        end

        private

        def set_node
          @node = @account.system_nodes.find(params[:node_id])
        rescue ::ActiveRecord::RecordNotFound
          render_not_found("Node")
        end

        def set_instance
          @instance = @node.node_instances.find(params[:node_instance_id])
        rescue ::ActiveRecord::RecordNotFound
          render_not_found("Node Instance")
        end

        def set_credential
          @credential = ::System::ClaudeCodeCredential.find_by(node_instance: @instance)
          render_not_found("Claude Code credential") unless @credential
        end

        # Exactly one of params[:api_key] / params[:oauth] selects the
        # credential kind. Returns [kind, vault_data]; the oauth blob is
        # validated + normalized by the model before anything is persisted.
        def extract_credential_payload!
          api_key = params[:api_key].to_s
          oauth   = params[:oauth]

          if api_key.present? && oauth.present?
            raise PayloadError, "supply exactly one of api_key or oauth, not both"
          end

          if api_key.present?
            ["api_key", { "api_key" => api_key }]
          elsif oauth.present?
            # Not model mass-assignment — the hash goes through the shape
            # validator and then straight to Vault, so unwrap the params.
            blob = oauth.respond_to?(:to_unsafe_h) ? oauth.to_unsafe_h : oauth
            ["oauth", { "oauth" => ::System::ClaudeCodeCredential.normalize_oauth_payload!(blob) }]
          else
            raise PayloadError,
                  "supply exactly one of api_key (Anthropic API key) or oauth " \
                  "(the claudeAiOauth object from ~/.claude/.credentials.json)"
          end
        end

        def vault_provider
          @vault_provider ||= ::Security::VaultCredentialProvider.new(account_id: @account.id)
        end

        # Index card only — id + kind + presence + timestamps. Never
        # plaintext, never the Vault path (an internal implementation
        # detail).
        def serialize(cred)
          {
            id: cred.id,
            node_instance_id: cred.node_instance_id,
            credential_kind: cred.credential_kind,
            configured: cred.vault_path.present?,
            created_at: cred.created_at.iso8601,
            updated_at: cred.updated_at.iso8601
          }
        end
      end
    end
  end
end
