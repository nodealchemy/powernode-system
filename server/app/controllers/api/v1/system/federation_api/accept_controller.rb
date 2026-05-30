# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Bootstrap-token-authenticated handshake. A newly-spawned child
        # platform (or an out-of-band-invited peer) presents its
        # acceptance_token to claim its FederationPeer row and complete
        # the initial capability + endpoint exchange.
        #
        # NOT mTLS-authenticated — the peer has no cert yet. The
        # acceptance_token is the bootstrap secret.
        #
        # POST /api/v1/system/federation_api/accept
        # Body:
        #   acceptance_token:    string (single-use, time-limited)
        #   contract_version:    integer (must be a supported version)
        #   extension_slugs:     array of strings (e.g., ["trading"])
        #   endpoints:           array of { url, scope, priority, cidr_hint? }
        #   capabilities:        object (forward-compat for P4)
        # Returns:
        #   { peer_id, status, contract_version_agreed, accepted_at,
        #     node_enrollment?, sdwan_attach?, governance? }
        #
        # All orchestration lives in
        # System::Federation::FederationAcceptanceService (Phase 3a). The
        # controller is a thin HTTP adapter: it marshals params, passes
        # request.base_url through as platform_url (for node_enrollment),
        # and maps the service Result back to render_success/render_error.
        class AcceptController < ApplicationController
          skip_before_action :authenticate_request, raise: false

          def create
            result = ::System::Federation::FederationAcceptanceService.call(
              token: params[:acceptance_token],
              contract_version: params[:contract_version],
              capabilities: capabilities_param,
              extension_slugs: extension_slugs_param,
              endpoints: endpoints_param,
              # platform_url is where the child agent POSTs /node_api/enroll
              # to redeem its bootstrap_token. That endpoint lives on the
              # PARENT (this platform). request.base_url derives the parent's
              # externally-visible URL from the URL the child reached us at —
              # robust to multi-tier proxies, no hardcoding.
              platform_url: request.base_url
            )

            return render_error(result.error, result.status) unless result.ok?

            render_success(data: result.payload)
          end

          private

          def capabilities_param
            value = params[:capabilities]
            value.is_a?(Hash) || value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : {}
          end

          def extension_slugs_param
            Array(params[:extension_slugs]).map(&:to_s).reject(&:blank?)
          end

          def endpoints_param
            Array(params[:endpoints]).map do |entry|
              if entry.is_a?(ActionController::Parameters)
                entry.to_unsafe_h
              else
                entry.to_h
              end
            end
          end
        end
      end
    end
  end
end
