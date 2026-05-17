# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for `System::AcmeDnsCredential` — the DNS
      # provider tokens (Cloudflare, DigitalOcean, etc.) used by the
      # ACME DNS-01 challenge during TLS cert issuance.
      #
      # Routes:
      #   GET    /api/v1/system/acme_dns_credentials
      #   GET    /api/v1/system/acme_dns_credentials/:id
      #   POST   /api/v1/system/acme_dns_credentials
      #   PATCH  /api/v1/system/acme_dns_credentials/:id        (name + metadata only)
      #   DELETE /api/v1/system/acme_dns_credentials/:id
      #   POST   /api/v1/system/acme_dns_credentials/:id/test_connectivity
      #   POST   /api/v1/system/acme_dns_credentials/:id/rotate
      #
      # Permissions:
      #   system.acme_dns.read   — list + show + test_connectivity
      #   system.acme_dns.manage — create + update + destroy + rotate
      #
      # Plan reference: Decentralized Federation §J + P2.5.
      #
      # IMPORTANT (CryptoMaterialSafety): the token plaintext is
      # received via the POST body, handed directly to
      # VaultCredentialProvider#store_credential, and never assigned
      # to a model attribute, never serialized in a response, never
      # written to logs. The model row carries only the public index
      # (name, provider, status, last_validated_at, vault_path).
      class AcmeDnsCredentialsController < ApplicationController
        before_action :set_credential, only: %i[show update destroy test_connectivity rotate]

        def index
          return forbidden unless current_user&.has_permission?("system.acme_dns.read")
          creds = ::System::AcmeDnsCredential
                    .where(account: current_account)
                    .order(:name)
          creds = creds.where(provider: params[:provider]) if params[:provider].present?
          render_success(
            credentials: creds.map { |c| serialize(c) },
            count: creds.count,
            supported_providers: ::Acme::DnsProviderRegistry::PROVIDERS.map { |slug, meta|
              { slug: slug, required_fields: meta[:required_fields], description: meta[:description] }
            }
          )
        end

        def show
          return forbidden unless current_user&.has_permission?("system.acme_dns.read")
          render_success(credential: serialize(@credential, full: true))
        end

        def create
          return forbidden unless current_user&.has_permission?("system.acme_dns.manage")

          provider_slug = params[:provider].to_s
          unless ::Acme::DnsProviderRegistry.supported?(provider_slug)
            return render_error(
              "Unsupported provider: #{provider_slug.inspect}. " \
              "Supported: #{::Acme::DnsProviderRegistry::PROVIDERS.keys.inspect}",
              status: :unprocessable_entity
            )
          end

          credentials = sanitize_credential_payload(params[:credentials], provider_slug)
          missing = required_fields(provider_slug) - credentials.keys
          unless missing.empty?
            return render_error(
              "Missing required credential field(s) for #{provider_slug}: #{missing.join(', ')}",
              status: :unprocessable_entity
            )
          end

          cred = nil
          ::ActiveRecord::Base.transaction do
            cred = ::System::AcmeDnsCredential.new(
              account: current_account,
              name: params[:name].to_s,
              provider: provider_slug,
              status: "untested",
              metadata: params[:metadata].is_a?(Hash) ? params[:metadata].to_unsafe_h : {}
            )

            unless cred.save
              raise ActiveRecord::Rollback,
                    "validation: #{cred.errors.full_messages.join('; ')}"
            end

            # Hand the plaintext directly to Vault — never assign to model.
            vault_provider.store_credential(
              credential_type: :acme_dns,
              credential_id: cred.id,
              data: credentials.transform_keys(&:to_s),
              record: cred
            )
          end

          if cred&.persisted?
            render_success({ credential: serialize(cred, full: true) }, status: :created)
          else
            render_error(
              cred ? cred.errors.full_messages.join("; ") : "Create failed",
              status: :unprocessable_entity
            )
          end
        end

        def update
          return forbidden unless current_user&.has_permission?("system.acme_dns.manage")
          if @credential.update(update_params)
            render_success(credential: serialize(@credential.reload, full: true))
          else
            render_error(@credential.errors.full_messages.join("; "),
                         status: :unprocessable_entity)
          end
        end

        def destroy
          return forbidden unless current_user&.has_permission?("system.acme_dns.manage")

          if @credential.acme_certificates.where.not(status: "revoked").exists?
            return render_error(
              "Cannot delete: credential is in use by active certificates. " \
              "Revoke or reassign them first.",
              status: :conflict
            )
          end

          ::ActiveRecord::Base.transaction do
            vault_provider.delete_credential(
              credential_type: :acme_dns,
              credential_id: @credential.id,
              record: @credential
            )
            @credential.destroy!
          end
          render_success(deleted: true, id: @credential.id)
        rescue StandardError => e
          ::Rails.logger.error("[AcmeDnsCredentialsController#destroy] #{e.class}: #{e.message}")
          render_error("Delete failed: #{e.message}", status: :unprocessable_entity)
        end

        def test_connectivity
          return forbidden unless current_user&.has_permission?("system.acme_dns.read")

          plaintext = vault_provider.get_credential(
            credential_type: :acme_dns,
            credential_id: @credential.id,
            record: @credential
          )

          unless plaintext.is_a?(Hash) && plaintext.any?
            return render_error("Vault has no credential for this row.",
                                status: :unprocessable_entity)
          end

          result = ::Acme::DnsCredentialValidator.new.verify(
            provider: @credential.provider,
            credentials: plaintext
          )

          if result.ok?
            @credential.mark_validated!
          else
            @credential.mark_invalid!(reason: result.message)
          end

          render_success(
            ok: result.ok?,
            # Reserved kwarg `message:` would render top-level — use `reason`
            # so the verifier's text lands inside `data` where the UI reads it.
            reason: result.message,
            details: result.details,
            credential: serialize(@credential.reload, full: true)
          )
        end

        def rotate
          return forbidden unless current_user&.has_permission?("system.acme_dns.manage")

          credentials = sanitize_credential_payload(params[:credentials], @credential.provider)
          missing = required_fields(@credential.provider) - credentials.keys
          unless missing.empty?
            return render_error(
              "Missing required credential field(s): #{missing.join(', ')}",
              status: :unprocessable_entity
            )
          end

          vault_provider.rotate_credential(
            credential_type: :acme_dns,
            credential_id: @credential.id,
            new_data: credentials.transform_keys(&:to_s),
            record: @credential
          )
          @credential.update!(status: "untested", last_validated_at: nil)
          render_success(credential: serialize(@credential.reload, full: true))
        end

        private

        def set_credential
          @credential = ::System::AcmeDnsCredential
                          .where(account: current_account)
                          .find_by(id: params[:id])
          render_error("Credential not found", status: :not_found) unless @credential
        end

        def forbidden
          render_error("Forbidden", status: :forbidden)
        end

        def update_params
          # Updates can change the operator-visible name + metadata, NOT
          # the provider (would orphan the Vault-stored credential type)
          # and NOT credentials (use #rotate for that).
          params.permit(:name, metadata: {})
        end

        def required_fields(provider_slug)
          ::Acme::DnsProviderRegistry::PROVIDERS[provider_slug.to_s][:required_fields]
        end

        # Strict allowlist — accept only the fields the registry declares
        # for this provider. Extras get silently dropped so we don't store
        # operator typos into Vault (which would later confuse Lego).
        def sanitize_credential_payload(payload, provider_slug)
          allowed = required_fields(provider_slug)
          hash = case payload
                 when ActionController::Parameters then payload.to_unsafe_h
                 when Hash then payload
                 else {}
                 end
          hash.each_with_object({}) do |(k, v), out|
            key = k.to_s
            out[key] = v.to_s if allowed.include?(key) && v.to_s.strip != ""
          end
        end

        def vault_provider
          @vault_provider ||= ::Security::VaultCredentialProvider.new(
            account_id: current_account.id
          )
        end

        # Serialization — index card only. Never includes credential
        # plaintext.
        def serialize(cred, full: false)
          base = {
            id: cred.id,
            name: cred.name,
            provider: cred.provider,
            status: cred.status,
            last_validated_at: cred.last_validated_at&.iso8601,
            created_at: cred.created_at.iso8601,
            updated_at: cred.updated_at.iso8601,
            needs_revalidation: cred.needs_revalidation?
          }
          return base unless full
          base.merge(
            metadata: cred.metadata || {},
            certificates_count: cred.acme_certificates.count,
            required_fields: required_fields(cred.provider)
          )
        end
      end
    end
  end
end
