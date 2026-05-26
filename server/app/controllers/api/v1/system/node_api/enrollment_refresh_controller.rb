# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Cert rotation endpoint for already-enrolled instances. Inherits
        # from BaseController so authenticate_instance! (mTLS) gates access
        # — only an instance presenting its CURRENT valid cert can refresh.
        # Bootstrap tokens are single-use by design and cannot reach this
        # endpoint.
        #
        # Consumed by the agent's runtime.CertRotator goroutine, which posts
        # a fresh CSR before the current cert hits its refresh deadline
        # (75% of the cert's NotBefore→NotAfter window).
        class EnrollmentRefreshController < BaseController
          # POST /api/v1/system/node_api/enroll/refresh
          # Body: { csr_pem, agent_version? }
          # Returns: { cert_pem, ca_chain_pem, instance_id, mtls_subject,
          #            not_after, certificate_id }
          def refresh
            csr_pem = params.require(:csr_pem)

            result = ::System::NodeEnrollmentService.refresh!(
              node_instance: current_instance,
              csr_pem:       csr_pem,
              agent_version: params[:agent_version]
            )

            unless result.success?
              Rails.logger.warn("[EnrollmentRefreshController] refresh failed: #{result.error}")
              return render_error(result.error, :unprocessable_content)
            end

            render_success(
              cert_pem:       result.cert_pem,
              ca_chain_pem:   result.ca_chain_pem,
              instance_id:    result.node_instance.id,
              mtls_subject:   result.node_instance.mtls_subject,
              not_after:      result.node_certificate.not_after.iso8601,
              certificate_id: result.node_certificate.id
            )
          end
        end
      end
    end
  end
end
