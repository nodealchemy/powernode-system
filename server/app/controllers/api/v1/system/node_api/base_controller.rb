# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Base controller for Node API endpoints
        # Handles instance-token authentication for node instance self-service
        # Instances use JWT token via X-Instance-Token header or Authorization Bearer
        class BaseController < ApplicationController
          # Skip default authenticate_request and use instance-specific auth
          skip_before_action :authenticate_request
          before_action :authenticate_instance!

          private

          # Authenticate the calling instance. Tries mTLS (preferred, Golden
          # Eclipse M0.P) first, falls back to legacy JWT during the migration
          # window.
          #
          # mTLS path: the reverse proxy terminates TLS and passes the verified
          # client cert subject CN via SSL_CLIENT_S_DN_CN (or its Rack-mapped
          # header X-Client-S-DN-CN). The CN is the NodeInstance.id; we look up
          # the active certificate to confirm the cert hasn't been revoked.
          #
          # JWT path (legacy): X-Instance-Token / Authorization Bearer with a
          # JWT carrying { type: "instance", sub: <instance_id> }.
          def authenticate_instance!
            return if authenticate_via_mtls!
            return if authenticate_via_jwt!

            render_unauthorized("Instance token or mTLS client certificate required")
          end

          # Tries mTLS auth. Returns true if authentication succeeded (current_instance
          # is set and short-circuits the chain), false if no mTLS context is present
          # (so the JWT fallback can run). Halts the request via render_unauthorized
          # if mTLS subject is present but doesn't validate.
          def authenticate_via_mtls!
            subject_cn = mtls_subject_cn
            return false if subject_cn.blank?

            instance = ::System::NodeInstance.find_by(id: subject_cn) ||
                       ::System::NodeInstance.find_by(mtls_subject: subject_cn)
            unless instance
              render_unauthorized("Instance not found for mTLS subject")
              return true # short-circuit; render already happened
            end

            unless instance.active?
              render_unauthorized("Instance is not active")
              return true
            end

            cert = instance.active_certificate
            unless cert
              render_unauthorized("No active certificate on file for instance")
              return true
            end

            @current_instance = instance
            true
          end

          # Reads the verified mTLS client subject CN from the request. The
          # reverse proxy must:
          #   (1) terminate the mTLS handshake and verify the cert against
          #       Powernode's internal CA chain, then
          #   (2) forward the subject in one of:
          #         - SSL_CLIENT_S_DN_CN env (CGI/Nginx standard)
          #         - X-Client-S-DN-CN header (custom; only trusted on the protected listener)
          #         - X-Forwarded-TLS-Client-Cert-Subject (Traefik default, full DN — extract CN=)
          # The platform's production reverse proxy is Traefik v3.0
          # (per docker-compose.prod.yml); current state has no mTLS
          # termination configured — the mTLS path is forward-compat scaffold
          # awaiting proxy-side deployment work. JWT fallback is the only
          # operational auth path until that lands.
          def mtls_subject_cn
            cn = request.env["SSL_CLIENT_S_DN_CN"].presence ||
                 request.headers["X-Client-S-DN-CN"].presence
            return cn if cn

            # Traefik passes the full DN string; extract CN= portion.
            traefik_dn = request.headers["X-Forwarded-TLS-Client-Cert-Subject"].presence
            return nil unless traefik_dn

            extract_cn_from_dn(traefik_dn)
          end

          # extract_cn_from_dn parses "CN=foo,O=Powernode,..." style DN strings
          # and returns the CN value. Tolerates spaces, quoted values, and
          # different orderings.
          def extract_cn_from_dn(dn)
            match = dn.match(/(?:\A|,)\s*CN\s*=\s*([^,]+)/i)
            match && match[1].strip
          end

          # Legacy JWT auth path. Returns true if the token authenticates,
          # false if no token is present, and renders 401 + returns true if
          # the token is bad (so the caller knows the request is already done).
          def authenticate_via_jwt!
            token = extract_instance_token_from_request
            return false unless token

            begin
              # Explicit ::Security::JwtService — bare JwtService does not autoload
              # from this deeply-nested namespace (see Golden Eclipse M0.H learning).
              payload = ::Security::JwtService.decode(token)

              unless payload[:type] == "instance"
                render_unauthorized("Invalid token type")
                return true
              end

              @current_instance = ::System::NodeInstance.find(payload[:sub])

              unless @current_instance.active?
                render_unauthorized("Instance is not active")
                return true
              end

              true
            rescue ActiveRecord::RecordNotFound
              render_unauthorized("Instance not found")
              true
            rescue StandardError => e
              render_unauthorized("Invalid instance token: #{e.message}")
              true
            end
          end

          # Extract token from X-Instance-Token header or Authorization Bearer
          def extract_instance_token_from_request
            # Prefer X-Instance-Token header
            token = request.headers["X-Instance-Token"]
            return token if token.present?

            # Fallback to Authorization header
            auth_header = request.headers["Authorization"]
            return nil unless auth_header&.start_with?("Bearer ")

            auth_header.split(" ", 2).last
          end

          # Access current instance
          attr_reader :current_instance

          # Get node from current instance
          def current_node
            @current_node ||= current_instance.node
          end

          # Get account from current instance
          def current_account
            @current_account ||= current_node.account
          end

          # Get template from current node
          def current_template
            @current_template ||= current_node.node_template
          end

          # Standard error handler for record not found
          def render_record_not_found(resource_type)
            render_not_found(resource_type)
          end
        end
      end
    end
  end
end
