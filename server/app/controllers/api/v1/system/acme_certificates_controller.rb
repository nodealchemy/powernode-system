# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD + lifecycle actions for `System::AcmeCertificate`.
      #
      # Routes:
      #   GET    /api/v1/system/acme_certificates
      #   GET    /api/v1/system/acme_certificates/:id
      #   POST   /api/v1/system/acme_certificates            (create row, status=pending)
      #   POST   /api/v1/system/acme_certificates/:id/request_issue
      #   POST   /api/v1/system/acme_certificates/:id/revoke
      #   DELETE /api/v1/system/acme_certificates/:id
      #
      # Permissions:
      #   system.acme.read   — list + show
      #   system.acme.issue  — create + request_issue
      #   system.acme.revoke — revoke + destroy (destroy is hard delete; revoke is soft)
      #
      # Issuance flow:
      #   1. POST /acme_certificates with { common_name, dns_credential_id, issuer, sans }
      #      creates a row in `pending`. No ACME call yet — operator can review.
      #   2. POST /:id/request_issue fires Acme::CertificateManager.issue! inline.
      #      Returns after issuance completes (60-180s typical) OR fails with the
      #      verifier's error. The status transitions on the row reflect the outcome.
      #
      # The inline approach matches the smoke test path; a future enhancement
      # would dispatch to the worker (AcmeCertificateRenewalJob already does
      # this for renewals). Inline keeps the v1 operator UX simple — they see
      # the result as the response.
      #
      # Plan reference: Decentralized Federation §J + P2.5.9.
      class AcmeCertificatesController < ApplicationController
        before_action :set_certificate, only: %i[show update destroy request_issue renew revoke]

        def index
          return forbidden unless current_user&.has_permission?("system.acme.read")
          certs = ::System::AcmeCertificate
                    .where(account: current_account)
                    .includes(:dns_credential)
                    .order(created_at: :desc)
          certs = certs.where(status: params[:status].to_s.split(",")) if params[:status].present?
          render_success(
            certificates: certs.map { |c| serialize(c) },
            count: certs.count,
            issuers: ::Acme::LegoClient::LE_DIRECTORY.keys
          )
        end

        def show
          return forbidden unless current_user&.has_permission?("system.acme.read")
          render_success(certificate: serialize(@certificate, full: true))
        end

        def create
          return forbidden unless current_user&.has_permission?("system.acme.issue")

          dns_cred = ::System::AcmeDnsCredential.where(account: current_account)
                                                  .find_by(id: params[:dns_credential_id])
          return render_error("dns_credential_id required + must reference your account",
                              status: :unprocessable_entity) unless dns_cred

          issuer = params[:issuer].presence || "letsencrypt-prod"
          unless ::Acme::LegoClient::LE_DIRECTORY.key?(issuer)
            return render_error("Unsupported issuer #{issuer.inspect}; supported: " \
                                "#{::Acme::LegoClient::LE_DIRECTORY.keys.inspect}",
                                status: :unprocessable_entity)
          end

          sans = sanitize_sans(params[:sans])
          meta = build_create_metadata(params[:metadata])

          cert = ::System::AcmeCertificate.new(
            account: current_account,
            common_name: params[:common_name].to_s.strip,
            dns_credential: dns_cred,
            issuer: issuer,
            challenge_type: "dns-01",
            status: "pending",
            sans: sans,
            traefik_resolver_name: params[:traefik_resolver_name].presence || "letsencrypt",
            metadata: meta
          )

          if cert.save
            render_success({ certificate: serialize(cert, full: true) }, status: :created)
          else
            render_error(cert.errors.full_messages.join("; "), status: :unprocessable_entity)
          end
        end

        def update
          return forbidden unless current_user&.has_permission?("system.acme.issue")

          unless @certificate.status == "pending" || @certificate.status == "failed"
            return render_error(
              "Cannot edit a #{@certificate.status} certificate. Revoke + create a new one instead.",
              status: :conflict
            )
          end

          if @certificate.update(update_params)
            render_success(certificate: serialize(@certificate.reload, full: true))
          else
            render_error(@certificate.errors.full_messages.join("; "),
                         status: :unprocessable_entity)
          end
        end

        def destroy
          return forbidden unless current_user&.has_permission?("system.acme.revoke")
          # Only allow hard delete from terminal states. Active certs must
          # be revoked first to ensure Vault cleanup + audit trail.
          unless @certificate.terminal? || @certificate.status == "pending" ||
                 @certificate.status == "failed"
            return render_error(
              "Cannot delete a #{@certificate.status} cert; revoke first.",
              status: :conflict
            )
          end
          @certificate.destroy!
          render_success(deleted: true, id: @certificate.id)
        end

        def request_issue
          return forbidden unless current_user&.has_permission?("system.acme.issue")

          unless %w[pending failed].include?(@certificate.status)
            return render_error(
              "Cannot request issuance from status=#{@certificate.status}. " \
              "Only pending + failed certs can be (re-)issued.",
              status: :conflict
            )
          end

          # Inline issuance — typical: 60-180s. The frontend should show
          # a busy state and not retry; the response is the source of truth.
          result = ::Acme::CertificateManager.issue!(certificate: @certificate)
          @certificate.reload

          if result.ok?
            render_success(
              ok: true,
              certificate: serialize(@certificate, full: true)
            )
          else
            render_error(
              "Issuance failed: #{result.error}",
              status: :unprocessable_entity,
              details: { certificate: serialize(@certificate, full: true) }
            )
          end
        rescue StandardError => e
          ::Rails.logger.error("[AcmeCertificatesController#request_issue] #{e.class}: #{e.message}")
          render_error("Issuance raised: #{e.message}", status: :internal_server_error)
        end

        def renew
          return forbidden unless current_user&.has_permission?("system.acme.renew")

          unless @certificate.status == "valid"
            return render_error(
              "Can only renew certs in status=valid (got #{@certificate.status}).",
              status: :conflict
            )
          end

          result = ::Acme::CertificateManager.renew!(certificate: @certificate)
          @certificate.reload

          if result.ok?
            render_success(
              ok: true,
              certificate: serialize(@certificate, full: true)
            )
          else
            render_error(
              "Renewal failed: #{result.error}",
              status: :unprocessable_entity,
              details: { certificate: serialize(@certificate, full: true) }
            )
          end
        rescue StandardError => e
          ::Rails.logger.error("[AcmeCertificatesController#renew] #{e.class}: #{e.message}")
          render_error("Renewal raised: #{e.message}", status: :internal_server_error)
        end

        def revoke
          return forbidden unless current_user&.has_permission?("system.acme.revoke")

          if @certificate.terminal?
            return render_error("Already #{@certificate.status}", status: :conflict)
          end

          result = ::Acme::CertificateManager.revoke!(
            certificate: @certificate,
            reason: params[:reason].to_s.presence
          )
          @certificate.reload

          if result.ok?
            render_success(ok: true, certificate: serialize(@certificate, full: true))
          else
            render_error("Revoke failed: #{result.error}", status: :unprocessable_entity)
          end
        rescue StandardError => e
          ::Rails.logger.error("[AcmeCertificatesController#revoke] #{e.class}: #{e.message}")
          render_error("Revoke raised: #{e.message}", status: :internal_server_error)
        end

        private

        def set_certificate
          @certificate = ::System::AcmeCertificate
                          .where(account: current_account)
                          .find_by(id: params[:id])
          render_error("Certificate not found", status: :not_found) unless @certificate
        end

        def forbidden
          render_error("Forbidden", status: :forbidden)
        end

        def update_params
          # Only edit fields that don't invalidate prior issuance state.
          params.permit(:traefik_resolver_name, metadata: {})
        end

        def sanitize_sans(raw)
          case raw
          when Array then raw.map(&:to_s).map(&:strip).reject(&:empty?)
          when String then raw.split(",").map(&:strip).reject(&:empty?)
          else []
          end
        end

        def build_create_metadata(supplied)
          base = case supplied
                 when ActionController::Parameters then supplied.to_unsafe_h
                 when Hash then supplied
                 else {}
                 end
          if (email = params[:acme_email].to_s.strip).present?
            base["acme_email"] = email
          end
          base
        end

        # The serializer is intentionally non-include-y on Vault paths.
        # Operators see a `vault_paths_present` boolean so they know if
        # the cert has been materialized, but never the actual paths or
        # PEMs in the response. PEM access goes through a separate
        # operator-confirmed endpoint (out of scope for v1).
        def serialize(cert, full: false)
          base = {
            id: cert.id,
            common_name: cert.common_name,
            sans: cert.sans || [],
            status: cert.status,
            issuer: cert.issuer,
            challenge_type: cert.challenge_type,
            dns_credential_id: cert.dns_credential_id,
            issued_at: cert.issued_at&.iso8601,
            expires_at: cert.expires_at&.iso8601,
            revoked_at: cert.revoked_at&.iso8601,
            days_until_expiry: days_until_expiry(cert),
            created_at: cert.created_at.iso8601,
            updated_at: cert.updated_at.iso8601,
            vault_paths_present: cert.vault_path_certificate.present?,
            terminal: cert.terminal?,
            last_renewal_error: cert.last_renewal_error
          }
          return base unless full
          base.merge(
            dns_credential_name: cert.dns_credential&.name,
            dns_credential_provider: cert.dns_credential&.provider,
            traefik_resolver_name: cert.traefik_resolver_name,
            metadata: cert.metadata || {}
          )
        end

        def days_until_expiry(cert)
          return nil unless cert.expires_at
          ((cert.expires_at - Time.current) / 1.day).round
        end
      end
    end
  end
end
