# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Bootstrap-token-authenticated enrollment endpoint. Public to nodes
        # presenting a valid bootstrap token; outputs an mTLS cert + CA chain
        # the on-node powernode-agent uses for all subsequent API calls.
        #
        # Skips the regular instance-token authentication (a freshly-booted
        # node has no cert yet — that's exactly what /enroll provides).
        class EnrollmentController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          before_action :require_bootstrap_token

          # POST /api/v1/system/node_api/enroll
          # Body: { bootstrap_token, csr_pem, agent_version?, dmi_uuid? }
          # Returns: { cert_pem, ca_chain_pem, instance_id, mtls_subject }
          def create
            csr_pem = params.require(:csr_pem)

            result = ::System::NodeEnrollmentService.enroll!(
              bootstrap_token_plaintext: @bootstrap_token,
              csr_pem: csr_pem,
              agent_version: params[:agent_version],
              dmi_uuid:      params[:dmi_uuid],
              source_ip:     request.remote_ip
            )

            unless result.success?
              Rails.logger.warn("[EnrollmentController] enroll failed: #{result.error}")
              return render_error(result.error, 422)
            end

            # Issue an instance JWT for the legacy auth path (until mTLS
            # termination lands at the reverse proxy). Agent persists this
            # alongside the cert and sends it as the Authorization Bearer
            # on every node_api request; base_controller's authenticate_via_jwt!
            # accepts it.
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

          private

          def require_bootstrap_token
            @bootstrap_token = params[:bootstrap_token].presence ||
                               request.headers["X-Bootstrap-Token"].presence
            return if @bootstrap_token

            render_error("Bootstrap token required (body :bootstrap_token or header X-Bootstrap-Token)",
                         status: :unauthorized)
          end
        end
      end
    end
  end
end
