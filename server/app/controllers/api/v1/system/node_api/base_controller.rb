# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Base controller for Node API endpoints.
        #
        # Auth model: mTLS only (enforced here). Requests arrive over a TLS
        # connection terminated by Traefik on the single websecure (:443)
        # entrypoint, whose `tls.options=mtls-optional@file`
        # (VerifyClientCertIfGiven) verifies the agent's client cert against the
        # platform's internal CA *when presented* — this controller then
        # requires the verified CN (401 otherwise). The CA is written to disk
        # by Acme::TraefikConfigWriter.write_internal_ca!.
        # Traefik's `passTLSClientCert` middleware forwards the cert's CN
        # in X-Forwarded-Tls-Client-Cert-Info; this controller looks up
        # the calling NodeInstance by that CN and confirms its certificate
        # row is still active (so revocation is one DB update away).
        class BaseController < ApplicationController
          skip_before_action :authenticate_request
          before_action :authenticate_instance!

          private

          def authenticate_instance!
            subject_cn = mtls_subject_cn
            if subject_cn.blank?
              render_unauthorized("mTLS client certificate required")
              return
            end

            # Resolve by exact id first (unique). The mtls_subject path is NOT
            # unique — the agent's cert CN is the Node hostname, which every
            # spawn from that Node shares, so many NodeInstances carry the same
            # mtls_subject. A plain find_by returns the OLDEST match, which can
            # be a TERMINATED instance that shadows the live one → spurious 401.
            # Exclude terminated/error (mirrors NodeInstance#active?) and prefer
            # the most-recent so a dead sibling never wins.
            instance = ::System::NodeInstance.find_by(id: subject_cn) ||
                       ::System::NodeInstance
                         .where(mtls_subject: subject_cn)
                         .where.not(status: %w[terminated error])
                         .order(created_at: :desc)
                         .first
            unless instance
              render_unauthorized("Instance not found for mTLS subject")
              return
            end

            unless instance.active?
              render_unauthorized("Instance is not active")
              return
            end

            unless instance.active_certificate
              render_unauthorized("No active certificate on file for instance")
              return
            end

            @current_instance = instance
          end

          # Reads the verified mTLS client subject CN from the request. The
          # reverse proxy (Traefik v3) terminates the mTLS handshake against
          # the internal CA chain (mtls-optional@file TLS option) and, when
          # the cert is valid, the passTLSClientCert middleware emits
          # `X-Forwarded-Tls-Client-Cert-Info: Subject="CN=<value>"`
          # (URL-encoded). This is the only header path supported — there
          # is no nginx-style env interop, no Traefik v2 legacy header.
          def mtls_subject_cn
            info = request.headers["X-Forwarded-Tls-Client-Cert-Info"].presence
            return nil unless info

            extract_cn_from_dn(CGI.unescape(info))
          end

          # extract_cn_from_dn parses Traefik v3's `Subject="CN=foo,O=Powernode"`
          # and returns the CN value. Tolerates spaces and the surrounding
          # `Subject="..."` wrapper Traefik adds (anchored by word boundary
          # rather than start-of-string so CN= after `Subject="` matches).
          def extract_cn_from_dn(dn)
            match = dn.match(/\bCN\s*=\s*"?([^,"]+)"?/i)
            match && match[1].strip
          end

          attr_reader :current_instance

          def current_node
            @current_node ||= current_instance.node
          end

          def current_account
            @current_account ||= current_node.account
          end

          def current_template
            @current_template ||= current_node.node_template
          end

          def render_record_not_found(resource_type)
            render_not_found(resource_type)
          end
        end
      end
    end
  end
end
