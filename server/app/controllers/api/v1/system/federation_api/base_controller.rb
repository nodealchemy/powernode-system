# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Base controller for Federation API endpoints (Decentralized
        # Federation plan §C + P3.4).
        #
        # Subjects of these endpoints are REMOTE POWERNODE PLATFORMS
        # (System::FederationPeer rows with peer_kind="platform"), NOT
        # NodeInstances. The mTLS subject_kind on the verified client
        # cert distinguishes the two; we refuse certs where subject_kind
        # != "federation_peer" to prevent an on-node agent's cert from
        # being used to call federation_api endpoints.
        #
        # Auth chain:
        #   mTLS subject CN → System::NodeCertificate (subject_kind="federation_peer")
        #     → System::FederationPeer (via node_certificate_id)
        #     → peer must be in a reachable status (enrolled|active|degraded)
        #
        # Bootstrap path (Accept) bypasses mTLS — the peer doesn't have
        # a cert yet — and uses bootstrap-token auth instead.
        class BaseController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          before_action :authenticate_federation_peer!

          private

          def authenticate_federation_peer!
            subject_cn = mtls_subject_cn
            return render_unauthorized("mTLS client certificate required") if subject_cn.blank?

            cert = ::System::NodeCertificate.find_by(id: subject_cn) ||
                   ::System::NodeCertificate.find_by(subject: subject_cn)
            return render_unauthorized("Certificate not found for mTLS subject") unless cert

            unless cert.respond_to?(:subject_kind) && cert.subject_kind == "federation_peer"
              return render_unauthorized("Certificate is not a federation_peer cert")
            end

            if cert.respond_to?(:revoked_at) && cert.revoked_at.present?
              return render_unauthorized("Certificate is revoked")
            end

            peer = ::System::FederationPeer.find_by(node_certificate_id: cert.id)
            return render_unauthorized("No FederationPeer bound to this certificate") unless peer

            unless peer.reachable?
              return render_unauthorized("FederationPeer is not in a reachable status (#{peer.status})")
            end

            @current_federation_peer = peer
            @current_federation_cert = cert
          end

          # Reads the verified mTLS client subject CN from the request.
          # Identical to NodeApi::BaseController's helper — the reverse
          # proxy must terminate mTLS and forward one of:
          #   - SSL_CLIENT_S_DN_CN env
          #   - X-Client-S-DN-CN header
          #   - X-Forwarded-TLS-Client-Cert-Subject (Traefik default; extract CN=)
          def mtls_subject_cn
            cn = request.env["SSL_CLIENT_S_DN_CN"].presence ||
                 request.headers["X-Client-S-DN-CN"].presence
            return cn if cn

            traefik_dn = request.headers["X-Forwarded-TLS-Client-Cert-Subject"].presence
            return nil unless traefik_dn

            match = traefik_dn.match(/(?:\A|,)\s*CN\s*=\s*([^,]+)/i)
            match && match[1].strip
          end

          attr_reader :current_federation_peer, :current_federation_cert

          def current_account
            @current_account ||= current_federation_peer&.account
          end

          # Resolves a Bearer `fg-<id>` token to a FederationGrant and
          # enforces the multi-layer auth chain expected by federation_api
          # resource endpoints:
          #
          #   1. Bearer token present
          #   2. Grant resolves
          #   3. Grant belongs to current_federation_peer
          #   4. Grant is active (not expired / revoked / archived)
          #   5. Grant's resource_kind matches caller's requested kind
          #   6. Grant's resource_id is either nil (kind-wide) or == requested id
          #   7. Grant carries the requested scope
          #   8. (LD #12) Grant's node_instance_ids allowlist matches caller's
          #      X-Calling-Instance header (when populated)
          #   9. (LD #12) Grant's sdwan_network_ids allowlist matches caller's
          #      X-Sdwan-Network header (when populated; validated against
          #      active FederationNetworkBridge for this peer)
          #  10. (LD #12) Grant's source_cidrs allowlist matches caller's
          #      verified source IP (when populated)
          #
          # On success returns the FederationGrant. On failure renders 401
          # or 403 (caller-side render is short-circuited by render_unauthorized
          # / render_forbidden).
          #
          # Plan reference: Decentralized Federation §E + §K + P4.7 + P4.5.5.
          def authorize_grant!(resource_kind:, resource_id: nil, scope: :read)
            token = extract_bearer_token
            return render_unauthorized("Bearer grant token required") if token.blank?

            grant = ::System::FederationGrant.find_by_bearer_token(token)
            return render_unauthorized("Grant token does not resolve") unless grant

            unless grant.federation_peer_id == current_federation_peer.id
              return render_unauthorized("Grant belongs to a different federation peer")
            end

            return render_unauthorized("Grant has expired")  if grant.expired?
            return render_unauthorized("Grant has been revoked") if grant.revoked?
            return render_unauthorized("Grant has been archived") if grant.archived?

            unless grant.resource_kind == resource_kind.to_s
              return render_forbidden(
                "Grant scoped to resource_kind=#{grant.resource_kind.inspect}, " \
                "request was for #{resource_kind.inspect}"
              )
            end

            if grant.resource_id.present? && resource_id.present? &&
               grant.resource_id != resource_id.to_s
              return render_forbidden(
                "Grant scoped to a specific resource_id (#{grant.resource_id}); " \
                "request targeted #{resource_id}"
              )
            end

            unless grant.has_scope?(scope)
              return render_forbidden(
                "Grant lacks required scope (#{scope}); has #{grant.permission_scopes.inspect}"
              )
            end

            # === Pessimistic scope checks (LD #12) ===

            calling_instance = calling_instance_id
            unless grant.applies_to_instance?(calling_instance)
              return render_forbidden(
                "Calling NodeInstance not in grant allowlist (#{grant.node_instance_ids.inspect}); " \
                "supplied: #{calling_instance.inspect}"
              )
            end

            sdwan_network = calling_sdwan_network_id
            unless grant.applies_to_network?(sdwan_network)
              return render_forbidden(
                "Calling SDWAN network not in grant allowlist (#{grant.sdwan_network_ids.inspect}); " \
                "supplied: #{sdwan_network.inspect}"
              )
            end

            # Also verify the supplied SDWAN network corresponds to an
            # ACTIVE bridge for this peer. Without an active bridge, the
            # network ID has no real meaning — it could be forged.
            if sdwan_network.present?
              bridge = ::System::FederationNetworkBridge.find_by(
                federation_peer_id: current_federation_peer.id,
                sdwan_network_id: sdwan_network
              )
              unless bridge&.active?
                return render_forbidden(
                  "No active FederationNetworkBridge for peer+network (#{sdwan_network})"
                )
              end
            end

            unless grant.applies_to_source_ip?(request.remote_ip)
              return render_forbidden(
                "Source IP not in grant CIDR allowlist (#{grant.source_cidrs.inspect}); " \
                "supplied: #{request.remote_ip.inspect}"
              )
            end

            @current_federation_grant = grant
          end

          # Read the calling NodeInstance.id forwarded by the reverse proxy
          # (Traefik). The proxy → backend hop is mTLS-authenticated so
          # the header value is trusted (backend refuses unsigned hops via
          # the existing mTLS chain to NodeApi::BaseController).
          #
          # Returns nil when the header is absent — the grant's
          # `applies_to_instance?` returns true for empty allowlists,
          # so absence-of-header preserves back-compat for v1 grants.
          def calling_instance_id
            request.headers["X-Calling-Instance"].presence
          end

          # Read the SDWAN network ID forwarded by the reverse proxy
          # (Traefik). The proxy binds its listener to a specific
          # network's VIP interface at deploy time and forwards the
          # corresponding ID.
          def calling_sdwan_network_id
            request.headers["X-Sdwan-Network"].presence
          end

          attr_reader :current_federation_grant

          def extract_bearer_token
            auth_header = request.headers["Authorization"]
            return nil unless auth_header&.start_with?("Bearer ")
            auth_header.split(" ", 2).last
          end

          def render_forbidden(message)
            render json: { error: message }, status: :forbidden
          end
        end
      end
    end
  end
end
