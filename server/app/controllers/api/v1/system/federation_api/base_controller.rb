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
        # NodeInstances.
        #
        # Auth chain (Federation mTLS Phase 2):
        #   mTLS subject CN (`fed:<peer.id>`, forwarded by Traefik after it
        #     cryptographically verifies the cert against our CA bundle)
        #     → System::FederationPeer via inbound_subject
        #     → scoped to platform_peers.reachable (enrolled|active|degraded),
        #       so sdwan-only / not-yet-enrolled / suspended peers are refused
        #       even if they present a structurally valid cert.
        #
        # Bootstrap path (Accept) bypasses mTLS — the peer doesn't have a cert
        # yet — and uses bootstrap-token auth instead.
        class BaseController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          before_action :authenticate_federation_peer!

          private

          def authenticate_federation_peer!
            subject_cn = ::Security::MtlsTrust.forwarded_subject_cn(request)
            return render_unauthorized("mTLS client certificate required") if subject_cn.blank?

            # The presented cert's CN is the identity WE assigned this peer at
            # accept (`fed:<peer.id>`), stamped on inbound_subject. Traefik has
            # already cryptographically verified the cert chains to our trusted
            # CA bundle (every federation cert is signed by our own CA in the
            # hierarchical model), so here we simply map the verified CN to its
            # peer row.
            #
            # Scoping to platform_peers.reachable means an sdwan-only peer, a
            # not-yet-enrolled peer, or a suspended/revoked one cannot
            # authenticate even if it still holds a valid cert — peer status is
            # the inbound revocation lever.
            peer = ::System::FederationPeer
                   .platform_peers.reachable
                   .find_by(inbound_subject: subject_cn)
            return render_unauthorized("No reachable FederationPeer for mTLS subject") unless peer

            # Federation mTLS Phase 2 (symmetric): bind the presented cert to
            # THIS peer's CA. When a full cert is forwarded it must verify
            # against the peer's own trust anchor (its CA for symmetric peers,
            # our CA for hierarchical children we issued) AND its CN must match
            # the resolved subject — so one trusted peer can't present a cert in
            # another peer's name. No PEM forwarded (pre-symmetric posture) →
            # Traefik's our-CA chain-check is authoritative.
            anchor = peer.trusted_ca_pem.presence || ::Security::MtlsTrust.own_ca_pem
            result = ::Security::MtlsTrust.verify_request_against_detailed(request, anchors: [ anchor ])
            if result != :no_pem && (!result.verified? || result.subject_cn != subject_cn)
              return render_unauthorized(peer_binding_refusal(peer, anchor, result, subject_cn))
            end

            @current_federation_peer = peer
          end

          # An ATTRIBUTABLE refusal.
          #
          # "Client certificate not issued by this peer's CA" was unactionable
          # on its own: it named the anchor only implicitly, and until
          # InternalCaService began stamping a hub-specific subject, EVERY
          # hub's local root presented the identical
          # "CN=Powernode Internal CA (local-dev)" over a different key — so
          # neither side could tell from the message (nor from the TLS
          # acceptable-CA list, which is BY DN) whether the mismatch was the
          # wrong CA, the wrong peer, or a legitimate cert their bundle had
          # simply lost the race to a same-named root.
          #
          # So the refusal quotes the SHA-256 fingerprint of the anchor we
          # actually checked against, plus the distinct failure mode. All of
          # this is public certificate material — no key material, no secrets
          # (result.error is one of four fixed MtlsClientVerifier strings).
          #
          # WHERE the anchor came from (a configured peer.trusted_ca_pem vs
          # our own CA) stays in the LOG only. This renders on a 401, to a
          # caller that has not authenticated and whose peer was resolved from
          # a forgeable header, so a prober guessing an inbound_subject must
          # not learn that peer's trust-configuration state. The fingerprint
          # is public and is the whole point; the config oracle buys the
          # remote nothing.
          def peer_binding_refusal(peer, anchor, result, subject_cn)
            expected = result.anchor_fingerprint ||
                       ::Security::MtlsClientVerifier.anchor_fingerprints([ anchor ]).first
            detail =
              if !result.verified?
                "presented certificate did not chain to it (#{result.error})"
              else
                "certificate verified against it but carries CN=#{result.subject_cn.inspect}, " \
                "not the #{subject_cn.inspect} this peer was assigned"
              end

            ::Rails.logger.warn(
              "[FederationApi] mTLS peer binding refused peer=#{peer.id} subject_cn=#{subject_cn.inspect} " \
              "anchor_source=#{peer.trusted_ca_pem.presence ? 'peer.trusted_ca_pem' : 'own_ca'} " \
              "expected_anchor=#{expected.inspect} matched_anchor=#{result.anchor_fingerprint.inspect}"
            )
            "Client certificate not issued by this peer's CA " \
              "(expected anchor #{expected || 'unavailable'}; #{detail})"
          end

          attr_reader :current_federation_peer

          def current_account
            @current_account ||= current_federation_peer&.account
          end

          # Resolves a Bearer `fgs.<id>.<sig>` HMAC-envelope token (or a legacy
          # `fg-<id>` token during the grace window) to a FederationGrant and
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

          # Both helpers must `; nil` so callers can write
          # `return render_unauthorized(...)` / `return render_forbidden(...)`
          # and have the returned value be nil — the create action then
          # short-circuits on `return unless grant`. Without the explicit nil,
          # `render` returns the response body String, which is truthy, and
          # the caller falls through into build_migration! with grant set to
          # the error JSON. That tripped DoubleRenderError + NoMethodError
          # on every migrations create attempt in CI run #580.
          def render_unauthorized(message)
            render json: { success: false, error: message, code: "UNAUTHORIZED" }, status: :unauthorized
            nil
          end

          def render_forbidden(message)
            render json: { error: message }, status: :forbidden
            nil
          end
        end
      end
    end
  end
end
