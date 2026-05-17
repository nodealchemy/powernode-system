# frozen_string_literal: true

module Api
  module V1
    module System
      module AcmeDnsCredentials
        # Operator-facing CRUD for DNS records on the provider associated
        # with a specific AcmeDnsCredential. Today only Cloudflare is
        # supported (other providers can ship adapters of the same
        # Acme::<Provider>::DnsClient shape).
        #
        # All endpoints are nested under the credential so the auth chain
        # is implicit (credential ownership = record management
        # permission for that zone). The api_token already has
        # Zone:Read + Zone:DNS:Edit scope from ACME setup.
        #
        # Endpoints:
        #   GET    /acme_dns_credentials/:credential_id/zones
        #   GET    /acme_dns_credentials/:credential_id/records?zone_id=...
        #   POST   /acme_dns_credentials/:credential_id/records
        #   PATCH  /acme_dns_credentials/:credential_id/records/:id?zone_id=...
        #   DELETE /acme_dns_credentials/:credential_id/records/:id?zone_id=...
        #
        # Permissions:
        #   system.dns.read   — list zones + records
        #   system.dns.manage — create + update + delete
        #
        # Plan reference: CF-DNS (Cloudflare DNS record management).
        class DnsRecordsController < ApplicationController
          before_action :authenticate_request
          before_action :set_credential
          before_action :load_api_token

          def zones
            return forbidden unless current_user&.has_permission?("system.dns.read")

            result = client.list_zones(
              name: params[:name].presence,
              per_page: clamp(params[:per_page], 1, 50, 50),
              page: clamp(params[:page], 1, 1_000, 1)
            )
            render_cf_result(result, key: :zones)
          end

          def index
            return forbidden unless current_user&.has_permission?("system.dns.read")
            zone_id = require_zone!
            return if performed?

            result = client.list_records(
              zone_id,
              type: params[:type].presence,
              name: params[:name].presence,
              per_page: clamp(params[:per_page], 1, 5_000, 100),
              page: clamp(params[:page], 1, 1_000, 1)
            )
            render_cf_result(result, key: :records)
          end

          def create
            return forbidden unless current_user&.has_permission?("system.dns.manage")
            zone_id = require_zone!
            return if performed?

            attrs = record_params
            unless attrs[:type].present? && attrs[:name].present? && attrs[:content].present?
              return render_error("type, name, and content are required", status: :bad_request)
            end

            result = client.create_record(
              zone_id,
              type: attrs[:type],
              name: attrs[:name],
              content: attrs[:content],
              ttl: (attrs[:ttl] || 1).to_i,
              proxied: cast_bool(attrs[:proxied]),
              priority: attrs[:priority]&.to_i,
              comment: attrs[:comment].presence,
              tags: Array(attrs[:tags]).reject(&:blank?)
            )
            render_cf_result(result, key: :record, status: :created)
          rescue ::Acme::Cloudflare::DnsClient::ApiError => e
            render_error(e.message, status: :bad_request)
          end

          def update
            return forbidden unless current_user&.has_permission?("system.dns.manage")
            zone_id = require_zone!
            return if performed?

            attrs = record_params.compact
            return render_error("no mutable fields supplied", status: :bad_request) if attrs.empty?

            payload = {}
            payload[:type]     = attrs[:type] if attrs[:type].present?
            payload[:name]     = attrs[:name] if attrs[:name].present?
            payload[:content]  = attrs[:content] if attrs[:content].present?
            payload[:ttl]      = attrs[:ttl].to_i if attrs[:ttl].present?
            payload[:proxied]  = cast_bool(attrs[:proxied]) if attrs.key?(:proxied)
            payload[:priority] = attrs[:priority].to_i if attrs[:priority].present?
            payload[:comment]  = attrs[:comment] if attrs.key?(:comment)
            payload[:tags]     = Array(attrs[:tags]) if attrs.key?(:tags)

            result = client.update_record(zone_id, params[:id], payload)
            render_cf_result(result, key: :record)
          rescue ::Acme::Cloudflare::DnsClient::ApiError => e
            render_error(e.message, status: :bad_request)
          end

          def destroy
            return forbidden unless current_user&.has_permission?("system.dns.manage")
            zone_id = require_zone!
            return if performed?

            result = client.delete_record(zone_id, params[:id])
            if result.ok?
              render_success(deleted: true, id: params[:id])
            else
              render_error("Delete failed: #{result.error}", status: bad_status(result))
            end
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_credential
            # Member action (zones) passes the row id as :id; nested
            # `resources :records` uses :acme_dns_credential_id.
            cred_id = params[:acme_dns_credential_id].presence ||
                      params[:credential_id].presence ||
                      params[:id]
            @credential = ::System::AcmeDnsCredential.find_by(
              id: cred_id, account: current_account
            )
            render_error("Credential not found", status: :not_found) unless @credential
          end

          def load_api_token
            return if performed?
            unless ::Acme::DnsClient.supported?(@credential.provider)
              return render_error(
                "DNS record management for provider #{@credential.provider.inspect} is not yet supported. " \
                "Supported providers: #{::Acme::DnsClient.supported_providers.inspect}.",
                status: :unprocessable_entity
              )
            end

            plaintext = vault_provider.get_credential(
              credential_type: :acme_dns,
              credential_id: @credential.id,
              record: @credential
            )

            unless plaintext.is_a?(Hash) && plaintext.any?
              return render_error(
                "Vault has no credential stored for #{@credential.id}.",
                status: :unprocessable_entity
              )
            end

            # Key may be stringified OR symbolized depending on how it was stored.
            @api_token = plaintext["api_token"] || plaintext[:api_token]
            unless @api_token.present?
              return render_error(
                "Stored credential has no api_token key. Re-create the credential to fix.",
                status: :unprocessable_entity
              )
            end
          rescue StandardError => e
            Rails.logger.error("[DnsRecordsController] vault read failed: #{e.message}")
            render_error("Failed to retrieve api_token from Vault: #{e.message}",
                        status: :internal_server_error)
          end

          # E5 — Dispatch via the factory. Every adapter conforms to
          # the same Result-shaped contract so the rest of this
          # controller doesn't branch on provider.
          def client
            @client ||= ::Acme::DnsClient.for(
              provider: @credential.provider, api_token: @api_token
            )
          end

          def vault_provider
            @vault_provider ||= ::Security::VaultCredentialProvider.new(
              account_id: current_account.id
            )
          end

          def require_zone!
            zone_id = params[:zone_id].presence
            unless zone_id
              render_error("zone_id is required", status: :bad_request)
              return nil
            end
            zone_id
          end

          def record_params
            params.permit(:type, :name, :content, :ttl, :proxied, :priority, :comment, tags: []).to_h.symbolize_keys
          end

          def render_cf_result(result, key:, status: :ok)
            if result.ok?
              render_success({ key => result.data }, status: status)
            else
              render_error("Cloudflare: #{result.error}",
                          status: bad_status(result),
                          details: { cf_errors: result.cf_errors }.compact)
            end
          end

          def bad_status(result)
            case result.http_status
            when 401, 403 then :forbidden
            when 404 then :not_found
            when 408, 504 then :gateway_timeout
            when 429 then :too_many_requests
            when 502, 503 then :bad_gateway
            else :unprocessable_entity
            end
          end

          def clamp(raw, min, max, default)
            v = raw.to_i
            return default if v.zero?
            [ [ v, min ].max, max ].min
          end

          def cast_bool(v)
            return false if v.nil?
            return v if v.is_a?(TrueClass) || v.is_a?(FalseClass)
            %w[true 1 yes on].include?(v.to_s.downcase)
          end
        end
      end
    end
  end
end
