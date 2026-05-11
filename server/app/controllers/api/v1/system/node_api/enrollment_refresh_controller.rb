# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Cert rotation endpoint for already-enrolled instances. Inherits
        # from BaseController so authenticate_instance! (mTLS preferred,
        # JWT fallback) gates access — only an instance presenting its
        # CURRENT valid cert can refresh. Bootstrap tokens are single-use
        # by design and cannot reach this endpoint.
        #
        # Phase 1 of the agent stub implementation plan; consumed by the
        # agent's runtime.CertRotator goroutine.
        class EnrollmentRefreshController < BaseController
          # POST /api/v1/system/node_api/enroll/refresh
          # Body: { csr_pem, agent_version? }
          # Returns: { cert_pem, ca_chain_pem, instance_id, mtls_subject,
          #            not_after, certificate_id, instance_token }
          def refresh
            csr_pem = params.require(:csr_pem)

            result = ::System::NodeEnrollmentService.refresh!(
              node_instance: current_instance,
              csr_pem:       csr_pem,
              agent_version: params[:agent_version]
            )

            unless result.success?
              Rails.logger.warn("[EnrollmentRefreshController] refresh failed: #{result.error}")
              return render_error(result.error, :unprocessable_entity)
            end

            # Re-issue the legacy-path JWT alongside the rotated cert. The
            # agent persists this with the cert so calls during the mTLS
            # transition window continue to authenticate.
            instance_token = ::Security::JwtService.encode(
              {
                type: "instance",
                sub:  result.node_instance.id
              }
            )

            render_success(
              cert_pem:       result.cert_pem,
              ca_chain_pem:   result.ca_chain_pem,
              instance_id:    result.node_instance.id,
              mtls_subject:   result.node_instance.mtls_subject,
              not_after:      result.node_certificate.not_after.iso8601,
              certificate_id: result.node_certificate.id,
              instance_token: instance_token
            )
          end
        end
      end
    end
  end
end
