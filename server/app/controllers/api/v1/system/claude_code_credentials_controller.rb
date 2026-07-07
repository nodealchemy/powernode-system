# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for a NodeInstance's Claude Code CLI credential
      # (Anthropic API key) — the secret the claude-tmux NodeModule fetches
      # at boot over the mTLS-authenticated node_api
      # (NodeApi::ConfigController#claude_code_credential).
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
      # IMPORTANT (CryptoMaterialSafety): the api_key plaintext is received
      # via the POST body, handed directly to VaultCredentialProvider, and
      # never assigned to a model attribute, never serialized in a response,
      # never written to logs. Mirrors AcmeDnsCredentialsController.
      class ClaudeCodeCredentialsController < BaseController
        before_action :set_account
        before_action :set_node
        before_action :set_instance
        # Permission checks run BEFORE the resource lookup so an
        # unauthorized caller always gets 403, never a 404 that would leak
        # whether a credential exists for this instance.
        before_action -> { require_permission("system.node_instance_credentials.read") }, only: %i[show]
        before_action -> { require_permission("system.node_instance_credentials.manage") },
                      only: %i[create rotate destroy]
        before_action :set_credential, only: %i[show destroy rotate]

        def show
          render_success(credential: serialize(@credential))
        end

        def create
          if ::System::ClaudeCodeCredential.exists?(node_instance_id: @instance.id)
            return render_error("Credential already exists for this instance — use rotate",
                                 status: :conflict)
          end

          api_key = params[:api_key].to_s
          return render_error("api_key is required", status: :unprocessable_content) if api_key.blank?

          cred = nil
          ::ActiveRecord::Base.transaction do
            cred = ::System::ClaudeCodeCredential.create!(node_instance: @instance)
            # Hand the plaintext directly to Vault — never assign to the model.
            vault_provider.store_credential(
              credential_type: :claude_code_api_key,
              credential_id: cred.id,
              data: { "api_key" => api_key },
              record: cred
            )
          end
          render_success({ credential: serialize(cred) }, status: :created)
        rescue ::ActiveRecord::RecordInvalid => e
          render_error(e.message, status: :unprocessable_content)
        end

        def rotate
          api_key = params[:api_key].to_s
          return render_error("api_key is required", status: :unprocessable_content) if api_key.blank?

          vault_provider.rotate_credential(
            credential_type: :claude_code_api_key,
            credential_id: @credential.id,
            new_data: { "api_key" => api_key },
            record: @credential
          )
          render_success(credential: serialize(@credential.reload))
        end

        def destroy
          vault_provider.delete_credential(
            credential_type: :claude_code_api_key,
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

        def vault_provider
          @vault_provider ||= ::Security::VaultCredentialProvider.new(account_id: @account.id)
        end

        # Index card only — id + presence + timestamps. Never plaintext,
        # never the Vault path (an internal implementation detail).
        def serialize(cred)
          {
            id: cred.id,
            node_instance_id: cred.node_instance_id,
            configured: cred.vault_path.present?,
            created_at: cred.created_at.iso8601,
            updated_at: cred.updated_at.iso8601
          }
        end
      end
    end
  end
end
